-- =====================================================================
--  السمو ERP — المرحلة 57: الإجازات وطلبات الغياب
--  أنواع الإجازات (سنوية، مرضية، بدون راتب…) برصيد سنوي، وطلبات من الموظف («راتبي») أو من المشرف،
--  والاعتماد للمشرف (payroll post). الأيام بدون الجمعة. الإجازة المعتمدة ما بتنحسب غياب بالحضور،
--  والإجازة «بدون راتب» بتنخصم لحالها بمسيّر الرواتب (الراتب ÷ 30 × الأيام) على «خصومات أخرى».
-- =====================================================================
create table if not exists public.leave_types (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  code        text not null,
  name        text not null,
  paid        boolean not null default true,
  annual_days numeric(6,1) not null default 0 check (annual_days between 0 and 366),   -- 0 = بدون حد
  is_active   boolean not null default true,
  unique (company_id, code)
);
create table if not exists public.leave_requests (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  req_no        int not null,
  employee_id   uuid not null references public.employees(id) on delete restrict,
  type_id       uuid not null references public.leave_types(id) on delete restrict,
  from_date     date not null,
  to_date       date not null,
  days          numeric(6,1) not null check (days > 0),
  half_day      boolean not null default false,
  reason        text,
  status        text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  decided_by    uuid,
  decided_at    timestamptz,
  decision_note text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  unique (company_id, req_no),
  check (to_date >= from_date)
);
create index if not exists leave_requests_emp on public.leave_requests (company_id, employee_id, from_date);

grant select, insert, update, delete on public.leave_types to authenticated;
grant select on public.leave_requests to authenticated;
alter table public.leave_types enable row level security;
alter table public.leave_requests enable row level security;
drop policy if exists lt_select on public.leave_types;
create policy lt_select on public.leave_types for select to authenticated
  using (public.can(company_id, 'payroll', 'view') or public.my_employee(company_id) is not null);
drop policy if exists lt_write on public.leave_types;
create policy lt_write on public.leave_types for all to authenticated
  using (public.can(company_id, 'payroll', 'edit') and public.tenant_writable())
  with check (public.can(company_id, 'payroll', 'edit') and public.tenant_writable());
drop policy if exists lr_select on public.leave_requests;
create policy lr_select on public.leave_requests for select to authenticated
  using (public.can(company_id, 'payroll', 'view') or employee_id = public.my_employee(company_id));

-- أنواع افتراضية لكل شركة (مرة وحدة)
create or replace function public.ensure_leave_types(p_company uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_company(p_company) then raise exception 'ما عندك صلاحية'; end if;
  if exists (select 1 from public.leave_types where company_id = p_company) then return; end if;
  insert into public.leave_types (company_id, code, name, paid, annual_days) values
    (p_company, '01', 'إجازة سنوية', true, 14),
    (p_company, '02', 'إجازة مرضية', true, 14),
    (p_company, '03', 'إجازة بدون راتب', false, 0),
    (p_company, '04', 'إجازة طارئة', true, 3);
end $$;

-- أيام العمل بين تاريخين (بدون الجمعة)
create or replace function public.leave_workdays(p_from date, p_to date) returns int
language sql immutable as $$
  select count(*)::int from generate_series(p_from, p_to, interval '1 day') g where extract(dow from g) <> 5;
$$;

-- رصيد الإجازات لموظف بسنة: لكل نوع الحد، المعتمد، بالانتظار، المتبقي
create or replace function public.leave_balance(p_company uuid, p_employee uuid, p_year int)
returns table (type_id uuid, code text, name text, paid boolean, entitled numeric, used numeric, pending numeric, remaining numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (public.can(p_company, 'payroll', 'view') or p_employee = public.my_employee(p_company)) then raise exception 'ما عندك صلاحية'; end if;
  return query
  select t.id, t.code, t.name, t.paid, t.annual_days,
         coalesce(sum(r.days) filter (where r.status = 'approved'), 0),
         coalesce(sum(r.days) filter (where r.status = 'pending'), 0),
         case when t.annual_days > 0 then t.annual_days - coalesce(sum(r.days) filter (where r.status = 'approved'), 0) end
    from public.leave_types t
    left join public.leave_requests r on r.type_id = t.id and r.employee_id = p_employee and extract(year from r.from_date) = p_year
   where t.company_id = p_company and (t.is_active or r.id is not null)
   group by t.id, t.code, t.name, t.paid, t.annual_days order by t.code;
end $$;

-- طلب إجازة: الموظف لحاله، أو المشرف (payroll add) لأي موظف
-- {company_id, employee_id?, type_id, from_date, to_date, half_day?, reason?}
create or replace function public.leave_request(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid := (p ->> 'company_id')::uuid; emp uuid; me uuid; t public.leave_types; f date; tt date; d numeric; rid uuid; no int; half boolean;
begin
  if cid is null or not public.has_company(cid) or not public.tenant_writable() then raise exception 'ما عندك صلاحية'; end if;
  if not exists (select 1 from public.tenants tn join public.companies c on c.tenant_id = tn.id where c.id = cid
                   and (tn.modules is null or 'payroll' = any (tn.modules))) then raise exception 'قسم الرواتب مش ضمن اشتراكك'; end if;
  me := public.my_employee(cid);
  emp := nullif(p ->> 'employee_id', '')::uuid;
  if emp is null or emp = me then
    if me is null then raise exception 'حسابك مش مربوط بموظف'; end if;
    emp := me;
  elsif not public.can(cid, 'payroll', 'add') then raise exception 'ما عندك صلاحية تسجيل إجازات لموظفين';
  end if;
  if not exists (select 1 from public.employees where id = emp and company_id = cid and is_active) then raise exception 'الموظف مش موجود'; end if;
  select * into t from public.leave_types where id = nullif(p ->> 'type_id', '')::uuid and company_id = cid and is_active;
  if t.id is null then raise exception 'اختار نوع الإجازة'; end if;
  f := (p ->> 'from_date')::date; tt := coalesce(nullif(p ->> 'to_date', '')::date, f);
  if f is null then raise exception 'تاريخ البداية مطلوب'; end if;
  if tt < f then raise exception 'تاريخ النهاية قبل البداية'; end if;
  if tt - f > 365 then raise exception 'الإجازة أطول من سنة'; end if;
  if extract(year from f) <> extract(year from tt) then raise exception 'قسّم الإجازة على سنتين (طلب لكل سنة)'; end if;
  half := coalesce((p ->> 'half_day')::boolean, false);
  if half and tt <> f then raise exception 'نص اليوم بيكون ليوم واحد'; end if;
  d := public.leave_workdays(f, tt);
  if d = 0 then raise exception 'الفترة كلها أيام جمعة'; end if;
  if half then d := 0.5; end if;
  if exists (select 1 from public.leave_requests r where r.employee_id = emp and r.status in ('pending','approved')
              and r.from_date <= tt and r.to_date >= f) then
    raise exception 'في إجازة ثانية لهالموظف بنفس الفترة';
  end if;
  perform pg_advisory_xact_lock(hashtext('leave:' || cid));
  select coalesce(max(req_no), 0) + 1 into no from public.leave_requests where company_id = cid;
  insert into public.leave_requests (company_id, req_no, employee_id, type_id, from_date, to_date, days, half_day, reason)
  values (cid, no, emp, t.id, f, tt, d, half, left(nullif(trim(p ->> 'reason'), ''), 500)) returning id into rid;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), cid, 'إضافة', 'leaves', rid::text, jsonb_build_object('no', no, 'days', d));
  return rid;
end $$;

-- اعتماد/رفض (المشرف = payroll post، ومش طلبه إلا المدير). الاعتماد بيفحص الرصيد.
create or replace function public.leave_decide(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.leave_requests; t public.leave_types; used numeric;
begin
  select * into r from public.leave_requests where id = p_id for update;
  if r.id is null then raise exception 'الطلب مش موجود'; end if;
  if not public.can(r.company_id, 'payroll', 'post') or not public.tenant_writable() then raise exception 'الاعتماد للمشرف (ترحيل الرواتب)'; end if;
  if r.status <> 'pending' then raise exception 'الطلب مش بالانتظار'; end if;
  if r.employee_id = public.my_employee(r.company_id) and not public.is_admin() then raise exception 'ما بتقدر تعتمد طلبك'; end if;
  if p_approve then
    select * into t from public.leave_types where id = r.type_id;
    if t.annual_days > 0 then
      select coalesce(sum(days), 0) into used from public.leave_requests
       where employee_id = r.employee_id and type_id = r.type_id and status = 'approved' and extract(year from from_date) = extract(year from r.from_date);
      if used + r.days > t.annual_days and not public.is_admin() then
        raise exception 'الرصيد ما بيكفي: الحد % يوم، المستعمل %، المطلوب %', t.annual_days, used, r.days;
      end if;
    end if;
    -- إجازة بدون راتب ما بتنعتمد لشهر مسيّره مرحّل
    if not t.paid and exists (select 1 from public.payroll_runs pr where pr.company_id = r.company_id and pr.status = 'posted'
                               and pr.period between to_char(r.from_date, 'YYYY-MM') and to_char(r.to_date, 'YYYY-MM')) then
      raise exception 'مسيّر رواتب شهر الإجازة مرحّل، الخصم ما رح ينطبق. ألغي المسيّر أو اخصمها يدوي';
    end if;
  end if;
  update public.leave_requests set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = auth.uid(), decided_at = now(), decision_note = left(nullif(trim(p_note), ''), 500)
   where id = p_id;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), r.company_id, case when p_approve then 'اعتماد' else 'رفض' end, 'leaves', p_id::text, jsonb_build_object('no', r.req_no));
end $$;

-- إلغاء: صاحب الطلب وهو بالانتظار، أو المشرف (حتى المعتمد إذا ما بلّش ومسيّره مش مرحّل)
create or replace function public.leave_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.leave_requests; sup boolean;
begin
  select * into r from public.leave_requests where id = p_id for update;
  if r.id is null then raise exception 'الطلب مش موجود'; end if;
  if not public.tenant_writable() then raise exception 'الاشتراك منتهي'; end if;
  sup := public.can(r.company_id, 'payroll', 'post');
  if r.status = 'pending' then
    if not (sup or r.employee_id = public.my_employee(r.company_id)) then raise exception 'ما عندك صلاحية'; end if;
  elsif r.status = 'approved' then
    if not sup then raise exception 'الإجازة المعتمدة بيلغيها المشرف'; end if;
    if exists (select 1 from public.payroll_runs pr where pr.company_id = r.company_id and pr.status = 'posted'
                and pr.period between to_char(r.from_date, 'YYYY-MM') and to_char(r.to_date, 'YYYY-MM')) then
      raise exception 'مسيّر رواتب شهر الإجازة مرحّل';
    end if;
  else raise exception 'الطلب منتهي'; end if;
  update public.leave_requests set status = 'cancelled', decided_by = auth.uid(), decided_at = now() where id = p_id;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), r.company_id, 'إلغاء', 'leaves', p_id::text, jsonb_build_object('no', r.req_no));
end $$;

-- أيام إجازة معتمدة لموظف بفترة (بدون الجمعة)، و«بدون راتب» لحالها
create or replace function public.leave_days_in(p_employee uuid, p_from date, p_to date, p_unpaid_only boolean)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(case when r.half_day then 0.5 else public.leave_workdays(greatest(r.from_date, p_from), least(r.to_date, p_to)) end), 0)
    from public.leave_requests r join public.leave_types t on t.id = r.type_id
   where r.employee_id = p_employee and r.status = 'approved' and r.from_date <= p_to and r.to_date >= p_from
     and (not p_unpaid_only or not t.paid);
$$;
revoke all on function public.leave_days_in(uuid, date, date, boolean) from public, anon, authenticated;

-- مسيّر الرواتب: خصم الإجازة بدون راتب لما ينضاف السطر (قبل حساب الصافي)
create or replace function public.pa_payroll_leave() returns trigger
language plpgsql security definer set search_path = public as $$
declare r public.payroll_runs; d numeric; f date; amt numeric;
begin
  if new.other_ded <> 0 then return new; end if;
  select * into r from public.payroll_runs where id = new.run_id;
  if r.id is null or r.status <> 'draft' then return new; end if;
  f := (r.period || '-01')::date;
  d := public.leave_days_in(new.employee_id, f, (f + interval '1 month' - interval '1 day')::date, true);
  if d > 0 then
    amt := least(round((new.basic + new.allowances) / 30 * d, 3), new.basic + new.allowances);
    new.other_ded := amt;
    new.notes := coalesce(new.notes || ' — ', '') || 'إجازة بدون راتب: ' || d || ' يوم';
  end if;
  return new;
end $$;
drop trigger if exists pa_payroll_leave on public.payroll_lines;
create trigger pa_payroll_leave before insert on public.payroll_lines for each row execute function public.pa_payroll_leave();

-- ملخص الحضور: الإجازة المعتمدة ما بتنحسب غياب
drop function if exists public.attendance_summary(uuid, date, date);
create or replace function public.attendance_summary(p_company uuid, p_from date, p_to date)
returns table (employee_id uuid, code text, name text, days int, hours numeric, late_days int, late_minutes int, absent_days int, outside_days int, open_days int, leave_days numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare cfg jsonb; st time; gr int; lt date := least(p_to, public.local_today());
begin
  if not public.can(p_company, 'payroll', 'view') then raise exception 'ما عندك صلاحية'; end if;
  select coalesce(attendance, '{}'::jsonb) into cfg from public.company_settings where company_id = p_company;
  st := coalesce(nullif(cfg ->> 'start', ''), '08:00')::time; gr := coalesce((cfg ->> 'grace')::int, 10);
  return query
  with a as (
    select x.*, ((x.check_in at time zone 'Asia/Amman')::time) tin from public.attendance x where x.company_id = p_company and x.day between p_from and p_to
  ), wd as (select count(*)::int n from generate_series(p_from, lt, interval '1 day') g where extract(dow from g) <> 5),
  s as (
    select e.id, e.code, e.name,
           count(a.id) filter (where a.check_in is not null)::int dd,
           round(coalesce(sum(extract(epoch from (a.check_out - a.check_in)) / 3600) filter (where a.check_out is not null), 0), 2) hh,
           count(a.id) filter (where a.tin > st + make_interval(mins => gr))::int ld,
           coalesce(sum(greatest(0, extract(epoch from (a.tin - st)) / 60)) filter (where a.tin > st + make_interval(mins => gr)), 0)::int lm,
           count(a.id) filter (where a.check_in is not null and extract(dow from a.day) <> 5)::int pd,
           count(a.id) filter (where a.outside)::int od,
           count(a.id) filter (where a.check_in is not null and a.check_out is null and a.day < public.local_today())::int opd,
           case when lt >= p_from then public.leave_days_in(e.id, p_from, lt, false) else 0 end lv
      from public.employees e left join a on a.employee_id = e.id
     where e.company_id = p_company and e.is_active
     group by e.id, e.code, e.name)
  select s.id, s.code, s.name, s.dd, s.hh, s.ld, s.lm,
         greatest(0, (select n from wd) - s.pd - ceil(s.lv)::int)::int, s.od, s.opd,
         case when p_to > lt then public.leave_days_in(s.id, p_from, p_to, false) else s.lv end
    from s order by s.code;
end $$;

revoke all on function public.ensure_leave_types(uuid), public.leave_balance(uuid, uuid, int), public.leave_request(jsonb),
  public.leave_decide(uuid, boolean, text), public.leave_cancel(uuid), public.attendance_summary(uuid, date, date) from public, anon;
grant execute on function public.ensure_leave_types(uuid), public.leave_balance(uuid, uuid, int), public.leave_request(jsonb),
  public.leave_decide(uuid, boolean, text), public.leave_cancel(uuid), public.attendance_summary(uuid, date, date), public.leave_workdays(date, date) to authenticated;

-- النسخة الاحتياطية: الإجازات بعد الحضور
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1, 'companies', 'id = $1', 'code'),
   (2, 'fiscal_years', 'company_id = $1', 'start_date'),
   (3, 'accounts', 'company_id = $1', 'level, code'),
   (4, 'discount_types', 'company_id = $1', 'code'),
   (5, 'cost_centers', 'company_id = $1', 'code'),
   (6, 'currencies', 'company_id = $1', 'code'),
   (7, 'company_settings', 'company_id = $1', 'company_id'),
   (8, 'lookups', 'company_id = $1', 'parent_id nulls first, kind, code'),
   (9, 'custom_fields', 'company_id = $1', 'entity, sort'),
   (10, 'party_categories', 'company_id = $1', 'party_type, code'),
   (11, 'price_lists', 'company_id = $1', 'code'),
   (12, 'parties', 'company_id = $1', 'code'),
   (13, 'sales_visits', 'company_id = $1', 'started_at'),
   (14, 'item_categories', 'company_id = $1', 'code'),
   (15, 'items', 'company_id = $1', 'code'),
   (16, 'price_list_items', 'list_id in (select id from public.price_lists where company_id = $1)', 'list_id'),
   (17, 'promotions', 'company_id = $1', 'date_from'),
   (18, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (19, 'warehouses', 'company_id = $1', 'code'),
   (20, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (21, 'departments', 'company_id = $1', 'level, code'),
   (22, 'doc_types', 'company_id = $1', 'kind, code'),
   (23, 'boms', 'company_id = $1', 'code'),
   (24, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (25, 'journal_entries', 'company_id = $1', 'created_at'),
   (26, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (27, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (28, 'invoices', 'company_id = $1', 'created_at'),
   (29, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (30, 'invoice_allocations', 'company_id = $1', 'created_at'),
   (31, 'orders', 'company_id = $1', 'created_at'),
   (32, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (33, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (34, 'cheques', 'company_id = $1', 'created_at'),
   (35, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (36, 'supply_requests', 'company_id = $1', 'req_no'),
   (37, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (38, 'stock_docs', 'company_id = $1', 'created_at'),
   (39, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (40, 'stock_moves', 'company_id = $1', 'created_at'),
   (41, 'landed_costs', 'company_id = $1', 'doc_no'),
   (42, 'landed_cost_invoices', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (43, 'landed_cost_charges', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id, line_no'),
   (44, 'landed_cost_allocs', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (45, 'productions', 'company_id = $1', 'prod_no'),
   (46, 'obligations', 'company_id = $1', 'due_date'),
   (47, 'recurring_entries', 'company_id = $1', 'created_at'),
   (48, 'work_locations', 'company_id = $1', 'name'),
   (49, 'employees', 'company_id = $1', 'code'),
   (50, 'attendance', 'company_id = $1', 'day, employee_id'),
   (51, 'leave_types', 'company_id = $1', 'code'),
   (52, 'leave_requests', 'company_id = $1', 'req_no'),
   (53, 'payroll_runs', 'company_id = $1', 'period'),
   (54, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (55, 'employee_loans', 'company_id = $1', 'loan_no'),
   (56, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (57, 'asset_custodians', 'company_id = $1', 'code'),
   (58, 'fixed_assets', 'company_id = $1', 'code'),
   (59, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (60, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (61, 'asset_movements', 'company_id = $1', 'mov_no'),
   (62, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (63, 'custody_docs', 'company_id = $1', 'doc_no'),
   (64, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (65, 'bank_recons', 'company_id = $1', 'created_at'),
   (66, 'bank_cleared', 'company_id = $1', 'line_id'),
   (67, 'message_log', 'company_id = $1', 'sent_at'),
   (68, 'attachments', 'company_id = $1', 'created_at'),
   (69, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
