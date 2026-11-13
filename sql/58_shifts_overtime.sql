-- =====================================================================
--  السمو ERP — المرحلة 58: المناوبات وجزاءات التأخير والعمل الإضافي
--  work_shifts: دوام لكل مناوبة (بداية/نهاية، سماح، أيام العطلة). employees.shift_id (الفاضي = دوام الشركة).
--  company_settings.attendance: start, end, grace, allow_outside + hours_per_day (8)، ot_rate (1.25)،
--    ot_offday_rate (1.5)، ot_min (30 دقيقة أقل إضافي بينحسب)، late_mult (1)، absent_mult (1)، apply_payroll (false).
--  الأجر: الشهري = الأساسي + العلاوات، اليومي = الشهري ÷ 30، الساعة = اليومي ÷ ساعات اليوم.
--  apply_payroll: مسيّر الرواتب بيعبّي «العمل الإضافي» وبيزيد «خصومات أخرى» بالتأخير والخروج المبكر والغياب لحاله.
-- =====================================================================
create table if not exists public.work_shifts (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  code        text not null,
  name        text not null,
  start_time  time not null default '08:00',
  end_time    time not null default '16:00',      -- أقل من البداية = بتخلص تاني يوم (مناوبة ليلية)
  grace_min   int not null default 10 check (grace_min between 0 and 240),
  days_off    int[] not null default '{5}',       -- 0 أحد … 6 سبت
  is_active   boolean not null default true,
  unique (company_id, code)
);
grant select, insert, update, delete on public.work_shifts to authenticated;
alter table public.work_shifts enable row level security;
drop policy if exists ws_select on public.work_shifts;
create policy ws_select on public.work_shifts for select to authenticated
  using (public.can(company_id, 'payroll', 'view') or public.my_employee(company_id) is not null);
drop policy if exists ws_write on public.work_shifts;
create policy ws_write on public.work_shifts for all to authenticated
  using (public.can(company_id, 'payroll', 'edit') and public.tenant_writable())
  with check (public.can(company_id, 'payroll', 'edit') and public.tenant_writable());

create or replace function public.ad_work_shift_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.start_time = new.end_time then raise exception 'بداية ونهاية المناوبة نفس الوقت'; end if;
  if exists (select 1 from unnest(new.days_off) d where d not between 0 and 6) then raise exception 'أيام العطلة من 0 (أحد) لـ 6 (سبت)'; end if;
  if cardinality(new.days_off) > 6 then raise exception 'لازم يوم عمل واحد على الأقل'; end if;
  return new;
end $$;
drop trigger if exists ad_work_shift_check on public.work_shifts;
create trigger ad_work_shift_check before insert or update on public.work_shifts for each row execute function public.ad_work_shift_check();

alter table public.employees add column if not exists shift_id uuid references public.work_shifts(id) on delete set null;
create or replace function public.ad_employee_shift_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.shift_id is not null and (tg_op = 'INSERT' or new.shift_id is distinct from old.shift_id)
     and not exists (select 1 from public.work_shifts where id = new.shift_id and company_id = new.company_id) then
    raise exception 'المناوبة مش من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists ad_employee_shift_check on public.employees;
create trigger ad_employee_shift_check before insert or update of shift_id on public.employees for each row execute function public.ad_employee_shift_check();

-- الحساب الداخلي (بدون فحص صلاحية): لكل موظف بالفترة (لحد اليوم)
create or replace function public.att_calc(p_company uuid, p_from date, p_to date, p_employee uuid default null)
returns table (employee_id uuid, code text, name text, days int, hours numeric, late_days int, late_minutes int, early_minutes int,
               ot_minutes int, offday_minutes int, absent_days int, leave_days numeric, outside_days int, open_days int,
               late_amount numeric, absent_amount numeric, ot_amount numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare cfg jsonb; c_st time; c_en time; c_gr int; hpd numeric; otr numeric; otr2 numeric; otmin int; lmul numeric; amul numeric; lt date;
begin
  select coalesce(attendance, '{}'::jsonb) into cfg from public.company_settings where company_id = p_company;
  cfg := coalesce(cfg, '{}'::jsonb);
  c_st := coalesce(nullif(cfg ->> 'start', ''), '08:00')::time; c_en := coalesce(nullif(cfg ->> 'end', ''), '16:00')::time;
  c_gr := coalesce((cfg ->> 'grace')::int, 10);
  hpd := greatest(coalesce((cfg ->> 'hours_per_day')::numeric, 8), 1);
  otr := coalesce((cfg ->> 'ot_rate')::numeric, 1.25); otr2 := coalesce((cfg ->> 'ot_offday_rate')::numeric, 1.5);
  otmin := coalesce((cfg ->> 'ot_min')::int, 30);
  lmul := coalesce((cfg ->> 'late_mult')::numeric, 1); amul := coalesce((cfg ->> 'absent_mult')::numeric, 1);
  lt := least(p_to, public.local_today());
  return query
  with e as (
    select x.id, x.code, x.name, x.basic_salary + x.allowances monthly, x.hire_date, x.end_date,
           coalesce(s.start_time, c_st) st, coalesce(s.end_time, c_en) en, coalesce(s.grace_min, c_gr) gr, coalesce(s.days_off, '{5}'::int[]) off
      from public.employees x left join public.work_shifts s on s.id = x.shift_id
     where x.company_id = p_company and x.is_active and (p_employee is null or x.id = p_employee)),
  a as (
    select at.employee_id, at.day, at.check_in, at.check_out, at.outside,
           (at.check_in at time zone 'Asia/Amman')::time tin, (at.check_out at time zone 'Asia/Amman')::time tout
      from public.attendance at where at.company_id = p_company and at.day between p_from and p_to),
  d as (   -- لكل يوم حضور: الدقائق
    select e.id, a.day, a.check_in, a.check_out, a.outside,
           extract(dow from a.day)::int = any (e.off) offday,
           case when a.check_out is not null then extract(epoch from (a.check_out - a.check_in)) / 60 end worked,
           -- دقائق من بداية المناوبة لوقت الحضور
           case when a.tin is not null then extract(epoch from (a.tin - e.st)) / 60 end in_diff,
           -- دقائق من نهاية المناوبة لوقت الانصراف (المناوبة الليلية: النهاية تاني يوم)
           case when a.check_out is not null then
             extract(epoch from (a.check_out - ((a.day + e.st) at time zone 'Asia/Amman'
               + make_interval(mins => (extract(epoch from (e.en - e.st)) / 60)::int + case when e.en <= e.st then 1440 else 0 end)))) / 60 end out_diff,
           e.gr
      from e join a on a.employee_id = e.id),
  s as (
    select e.id, e.code, e.name, e.monthly, e.off,
           count(d.check_in)::int dd,
           round(coalesce(sum(d.worked) / 60, 0), 2) hh,
           count(*) filter (where not d.offday and d.in_diff > d.gr)::int ld,
           coalesce(sum(greatest(d.in_diff, 0)) filter (where not d.offday and d.in_diff > d.gr), 0)::int lm,
           coalesce(sum(greatest(-d.out_diff, 0)) filter (where not d.offday and d.out_diff < 0), 0)::int em,
           coalesce(sum(d.out_diff) filter (where not d.offday and d.out_diff >= otmin), 0)::int om,
           coalesce(sum(d.worked) filter (where d.offday and d.worked >= otmin), 0)::int ofm,
           count(*) filter (where d.check_in is not null and not d.offday)::int pd,
           count(*) filter (where d.outside)::int od,
           count(*) filter (where d.check_in is not null and d.check_out is null and d.day < public.local_today())::int opd,
           (select count(*)::int from generate_series(greatest(p_from, coalesce(e.hire_date, p_from)), least(lt, coalesce(e.end_date, lt)), interval '1 day') g
             where not (extract(dow from g)::int = any (e.off))) wd,
           case when lt >= p_from then public.leave_days_in(e.id, p_from, lt, false) else 0 end lv
      from e left join d on d.id = e.id
     group by e.id, e.code, e.name, e.monthly, e.off, e.hire_date, e.end_date)
  select s.id, s.code, s.name, s.dd, s.hh, s.ld, s.lm, s.em, s.om, s.ofm,
         greatest(0, s.wd - s.pd - ceil(s.lv)::int)::int,
         case when p_to > lt then public.leave_days_in(s.id, p_from, p_to, false) else s.lv end,
         s.od, s.opd,
         round((s.lm + s.em) / 60.0 * s.monthly / 30 / hpd * lmul, 3),
         round(greatest(0, s.wd - s.pd - ceil(s.lv)::int) * s.monthly / 30 * amul, 3),
         round(s.om / 60.0 * s.monthly / 30 / hpd * otr + s.ofm / 60.0 * s.monthly / 30 / hpd * otr2, 3)
    from s order by s.code;
end $$;
revoke all on function public.att_calc(uuid, date, date, uuid) from public, anon, authenticated;

drop function if exists public.attendance_summary(uuid, date, date);
create or replace function public.attendance_summary(p_company uuid, p_from date, p_to date)
returns table (employee_id uuid, code text, name text, days int, hours numeric, late_days int, late_minutes int, early_minutes int,
               ot_minutes int, offday_minutes int, absent_days int, leave_days numeric, outside_days int, open_days int,
               late_amount numeric, absent_amount numeric, ot_amount numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'payroll', 'view') then raise exception 'ما عندك صلاحية'; end if;
  return query select * from public.att_calc(p_company, p_from, p_to, null);
end $$;

-- مسيّر الرواتب: الإضافي والجزاءات من الحضور (إذا apply_payroll). الاسم بعد pa_payroll_leave وقبل payroll_lines_guard.
create or replace function public.pa_payroll_zatt() returns trigger
language plpgsql security definer set search_path = public as $$
declare r public.payroll_runs; cfg jsonb; f date; x record; ded numeric;
begin
  select * into r from public.payroll_runs where id = new.run_id;
  if r.id is null or r.status <> 'draft' then return new; end if;
  select attendance into cfg from public.company_settings where company_id = r.company_id;
  if not coalesce((cfg ->> 'apply_payroll')::boolean, false) then return new; end if;
  if not exists (select 1 from public.attendance where company_id = r.company_id and employee_id = new.employee_id) then return new; end if;
  f := (r.period || '-01')::date;
  select * into x from public.att_calc(r.company_id, f, (f + interval '1 month' - interval '1 day')::date, new.employee_id);
  if x.employee_id is null then return new; end if;
  if new.overtime = 0 and x.ot_amount > 0 then
    new.overtime := x.ot_amount;
    new.notes := coalesce(new.notes || ' — ', '') || 'إضافي: ' || round((x.ot_minutes + x.offday_minutes) / 60.0, 1) || ' ساعة';
  end if;
  ded := least(x.late_amount + x.absent_amount, greatest(new.basic + new.allowances - new.other_ded, 0));
  if ded > 0 then
    new.other_ded := new.other_ded + ded;
    new.notes := coalesce(new.notes || ' — ', '') || 'جزاءات: '
      || case when x.late_minutes + x.early_minutes > 0 then 'تأخير/خروج مبكر ' || (x.late_minutes + x.early_minutes) || ' د' else '' end
      || case when x.absent_days > 0 then case when x.late_minutes + x.early_minutes > 0 then '، ' else '' end || 'غياب ' || x.absent_days || ' يوم' else '' end;
  end if;
  return new;
end $$;
drop trigger if exists pa_payroll_zatt on public.payroll_lines;
create trigger pa_payroll_zatt before insert on public.payroll_lines for each row execute function public.pa_payroll_zatt();

revoke all on function public.attendance_summary(uuid, date, date) from public, anon;
grant execute on function public.attendance_summary(uuid, date, date) to authenticated;

-- النسخة الاحتياطية: المناوبات قبل الموظفين
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
   (49, 'work_shifts', 'company_id = $1', 'code'),
   (50, 'employees', 'company_id = $1', 'code'),
   (51, 'attendance', 'company_id = $1', 'day, employee_id'),
   (52, 'leave_types', 'company_id = $1', 'code'),
   (53, 'leave_requests', 'company_id = $1', 'req_no'),
   (54, 'payroll_runs', 'company_id = $1', 'period'),
   (55, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (56, 'employee_loans', 'company_id = $1', 'loan_no'),
   (57, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (58, 'asset_custodians', 'company_id = $1', 'code'),
   (59, 'fixed_assets', 'company_id = $1', 'code'),
   (60, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (61, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (62, 'asset_movements', 'company_id = $1', 'mov_no'),
   (63, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (64, 'custody_docs', 'company_id = $1', 'doc_no'),
   (65, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (66, 'bank_recons', 'company_id = $1', 'created_at'),
   (67, 'bank_cleared', 'company_id = $1', 'line_id'),
   (68, 'message_log', 'company_id = $1', 'sent_at'),
   (69, 'attachments', 'company_id = $1', 'created_at'),
   (70, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
