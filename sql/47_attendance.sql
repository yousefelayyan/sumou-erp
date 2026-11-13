-- =====================================================================
--  السمو ERP — المرحلة 47: الحضور والانصراف (موظف ومشرف، موقع العمل)
--  work_locations: مواقع العمل بإحداثيات ونصف قطر. employees.work_location_id: موقع الموظف (فاضي = أي موقع فعّال).
--  attendance: سطر لكل موظف بكل يوم (دخول/خروج بالوقت والموقع والمسافة).
--  attendance_punch: الموظف بيسجّل من جواله وهو جوّا نطاق الموقع. المشرف (payroll edit) بيعدّل/بيضيف يدوي.
--  company_settings.attendance = {start:'08:00', end:'16:00', grace:10, allow_outside:false}
-- =====================================================================
alter table public.company_settings add column if not exists attendance jsonb not null default '{}'::jsonb;

create table if not exists public.work_locations (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name       text not null,
  lat        numeric(10,6) not null check (lat between -90 and 90),
  lng        numeric(10,6) not null check (lng between -180 and 180),
  radius_m   int not null default 150 check (radius_m between 20 and 5000),
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.work_locations enable row level security;
grant select, insert, update, delete on public.work_locations to authenticated;
drop policy if exists wl_select on public.work_locations;
create policy wl_select on public.work_locations for select to authenticated using (public.has_company(company_id));
drop policy if exists wl_write on public.work_locations;
create policy wl_write on public.work_locations for all to authenticated
  using (public.can(company_id, 'payroll', 'edit') and public.tenant_writable()) with check (public.can(company_id, 'payroll', 'edit') and public.tenant_writable());

alter table public.employees add column if not exists work_location_id uuid references public.work_locations(id) on delete set null;

create table if not exists public.attendance (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  day         date not null,
  check_in    timestamptz,
  in_lat      numeric(10,6), in_lng numeric(10,6), in_dist int,
  check_out   timestamptz,
  out_lat     numeric(10,6), out_lng numeric(10,6), out_dist int,
  location_id uuid references public.work_locations(id) on delete set null,
  source      text not null default 'self' check (source in ('self','supervisor')),
  outside     boolean not null default false,
  notes       text,
  updated_by  uuid,
  updated_at  timestamptz not null default now(),
  unique (employee_id, day)
);
create index if not exists attendance_co_day on public.attendance (company_id, day);
alter table public.attendance enable row level security;
revoke insert, update, delete on public.attendance from authenticated;
grant select on public.attendance to authenticated;
drop policy if exists att_select on public.attendance;
create policy att_select on public.attendance for select to authenticated
  using (public.can(company_id, 'payroll', 'view') or employee_id = public.my_employee(company_id));

-- المسافة بالمتر (هافرساين)
create or replace function public.geo_dist_m(a_lat numeric, a_lng numeric, b_lat numeric, b_lng numeric) returns int
language sql immutable as $$
  select round(2 * 6371000 * asin(sqrt(power(sin(radians((b_lat - a_lat) / 2)), 2)
         + cos(radians(a_lat)) * cos(radians(b_lat)) * power(sin(radians((b_lng - a_lng) / 2)), 2))))::int;
$$;

-- تسجيل حضور/انصراف من الموظف نفسه
create or replace function public.attendance_punch(p_company uuid, p_kind text, p_lat numeric, p_lng numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare emp public.employees; cfg jsonb; loc record; d date := public.local_today(); a public.attendance; dist int; v_out boolean := false;
begin
  if not public.tenant_writable() then raise exception 'الاشتراك منتهي'; end if;
  select * into emp from public.employees where id = public.my_employee(p_company);
  if emp.id is null then raise exception 'حسابك مش مربوط بموظف'; end if;
  if not emp.is_active then raise exception 'الموظف مش على رأس عمله'; end if;
  if p_kind not in ('in','out') then raise exception 'نوع التسجيل غلط'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'لازم تسمح للبرنامج يعرف موقعك عشان تسجّل';
  end if;
  select coalesce(attendance, '{}'::jsonb) into cfg from public.company_settings where company_id = p_company;
  select w.id, w.name, w.radius_m, public.geo_dist_m(p_lat, p_lng, w.lat, w.lng) d into loc
    from public.work_locations w
   where w.company_id = p_company and w.is_active and (emp.work_location_id is null or w.id = emp.work_location_id)
   order by public.geo_dist_m(p_lat, p_lng, w.lat, w.lng) limit 1;
  if loc.id is not null then
    dist := loc.d;
    if dist > loc.radius_m then
      if not coalesce((cfg ->> 'allow_outside')::boolean, false) then
        raise exception 'إنت برّا موقع العمل «%» (بعيد % متر، المسموح %)', loc.name, dist, loc.radius_m;
      end if;
      v_out := true;
    end if;
  end if;
  select * into a from public.attendance where employee_id = emp.id and day = d for update;
  if p_kind = 'in' then
    if a.check_in is not null then raise exception 'سجّلت حضور اليوم الساعة %', to_char(a.check_in at time zone 'Asia/Amman', 'HH24:MI'); end if;
    insert into public.attendance (company_id, employee_id, day, check_in, in_lat, in_lng, in_dist, location_id, outside, updated_by)
    values (p_company, emp.id, d, now(), p_lat, p_lng, dist, loc.id, v_out, auth.uid())
    on conflict (employee_id, day) do update set check_in = excluded.check_in, in_lat = excluded.in_lat, in_lng = excluded.in_lng, in_dist = excluded.in_dist,
      location_id = excluded.location_id, outside = public.attendance.outside or excluded.outside, updated_at = now(), updated_by = auth.uid();
  else
    if a.id is null or a.check_in is null then raise exception 'سجّل حضور أول'; end if;
    if a.check_out is not null then raise exception 'سجّلت انصراف اليوم الساعة %', to_char(a.check_out at time zone 'Asia/Amman', 'HH24:MI'); end if;
    update public.attendance set check_out = now(), out_lat = p_lat, out_lng = p_lng, out_dist = dist, outside = public.attendance.outside or v_out,
           updated_at = now(), updated_by = auth.uid() where id = a.id;
  end if;
  return jsonb_build_object('kind', p_kind, 'at', now(), 'location', loc.name, 'distance', dist, 'outside', v_out);
end $$;

-- المشرف: إضافة/تعديل يومية حضور. p = {company_id, employee_id, day, check_in:'HH:MI', check_out:'HH:MI', notes}
create or replace function public.attendance_set(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid := (p ->> 'company_id')::uuid; emp uuid := (p ->> 'employee_id')::uuid; d date := (p ->> 'day')::date; ci timestamptz; co timestamptz; aid uuid;
begin
  if not public.can(cid, 'payroll', 'edit') or not public.tenant_writable() then raise exception 'تعديل الحضور للمشرف'; end if;
  if not exists (select 1 from public.employees where id = emp and company_id = cid) then raise exception 'الموظف مش من الشركة'; end if;
  if d is null or d > public.local_today() then raise exception 'التاريخ مش صحيح'; end if;
  ci := case when nullif(p ->> 'check_in', '') is null then null else ((d::text || ' ' || (p ->> 'check_in'))::timestamp at time zone 'Asia/Amman') end;
  co := case when nullif(p ->> 'check_out', '') is null then null else ((d::text || ' ' || (p ->> 'check_out'))::timestamp at time zone 'Asia/Amman') end;
  if ci is not null and co is not null and co <= ci then raise exception 'وقت الانصراف لازم بعد الحضور'; end if;
  if ci is null and co is null then
    delete from public.attendance where employee_id = emp and day = d;
    return null;
  end if;
  insert into public.attendance (company_id, employee_id, day, check_in, check_out, source, notes, updated_by)
  values (cid, emp, d, ci, co, 'supervisor', left(nullif(trim(p ->> 'notes'), ''), 300), auth.uid())
  on conflict (employee_id, day) do update set check_in = excluded.check_in, check_out = excluded.check_out, source = 'supervisor',
    notes = excluded.notes, updated_by = auth.uid(), updated_at = now()
  returning id into aid;
  return aid;
end $$;

-- ملخص الفترة لكل موظف: أيام الحضور، الساعات، التأخير، الغياب (أيام العمل = كل الأيام ما عدا الجمعة)
create or replace function public.attendance_summary(p_company uuid, p_from date, p_to date)
returns table (employee_id uuid, code text, name text, days int, hours numeric, late_days int, late_minutes int, absent_days int, outside_days int, open_days int)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare cfg jsonb; st time; gr int;
begin
  if not public.can(p_company, 'payroll', 'view') then raise exception 'ما عندك صلاحية'; end if;
  select coalesce(attendance, '{}'::jsonb) into cfg from public.company_settings where company_id = p_company;
  st := coalesce(nullif(cfg ->> 'start', ''), '08:00')::time; gr := coalesce((cfg ->> 'grace')::int, 10);
  return query
  with a as (
    select x.*, ((x.check_in at time zone 'Asia/Amman')::time) tin from public.attendance x where x.company_id = p_company and x.day between p_from and p_to
  ), wd as (select count(*)::int n from generate_series(p_from, least(p_to, public.local_today()), interval '1 day') g where extract(dow from g) <> 5)
  select e.id, e.code, e.name,
         count(a.id) filter (where a.check_in is not null)::int,
         round(coalesce(sum(extract(epoch from (a.check_out - a.check_in)) / 3600) filter (where a.check_out is not null), 0), 2),
         count(a.id) filter (where a.tin > st + make_interval(mins => gr))::int,
         coalesce(sum(greatest(0, extract(epoch from (a.tin - st)) / 60)) filter (where a.tin > st + make_interval(mins => gr)), 0)::int,
         greatest(0, (select n from wd) - count(a.id) filter (where a.check_in is not null and extract(dow from a.day) <> 5))::int,
         count(a.id) filter (where a.outside)::int,
         count(a.id) filter (where a.check_in is not null and a.check_out is null and a.day < public.local_today())::int
    from public.employees e left join a on a.employee_id = e.id
   where e.company_id = p_company and e.is_active
   group by e.id, e.code, e.name order by e.code;
end $$;

revoke execute on function public.attendance_punch(uuid, text, numeric, numeric), public.attendance_set(jsonb), public.attendance_summary(uuid, date, date) from public, anon;
grant execute on function public.attendance_punch(uuid, text, numeric, numeric), public.attendance_set(jsonb), public.attendance_summary(uuid, date, date) to authenticated;

-- النسخة الاحتياطية: مواقع العمل قبل الموظفين، والحضور بعدهم
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1, 'companies', 'id = $1', 'code'),
   (2, 'fiscal_years', 'company_id = $1', 'start_date'),
   (3, 'accounts', 'company_id = $1', 'level, code'),
   (4, 'cost_centers', 'company_id = $1', 'code'),
   (5, 'currencies', 'company_id = $1', 'code'),
   (6, 'company_settings', 'company_id = $1', 'company_id'),
   (7, 'lookups', 'company_id = $1', 'parent_id nulls first, kind, code'),
   (8, 'custom_fields', 'company_id = $1', 'entity, sort'),
   (9, 'party_categories', 'company_id = $1', 'party_type, code'),
   (10, 'parties', 'company_id = $1', 'code'),
   (11, 'sales_visits', 'company_id = $1', 'started_at'),
   (12, 'item_categories', 'company_id = $1', 'code'),
   (13, 'items', 'company_id = $1', 'code'),
   (14, 'promotions', 'company_id = $1', 'date_from'),
   (15, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (16, 'warehouses', 'company_id = $1', 'code'),
   (17, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (18, 'departments', 'company_id = $1', 'level, code'),
   (19, 'boms', 'company_id = $1', 'code'),
   (20, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (21, 'journal_entries', 'company_id = $1', 'created_at'),
   (22, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (23, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (24, 'invoices', 'company_id = $1', 'created_at'),
   (25, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (26, 'orders', 'company_id = $1', 'created_at'),
   (27, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (28, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (29, 'cheques', 'company_id = $1', 'created_at'),
   (30, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (31, 'supply_requests', 'company_id = $1', 'req_no'),
   (32, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (33, 'stock_docs', 'company_id = $1', 'created_at'),
   (34, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (35, 'stock_moves', 'company_id = $1', 'created_at'),
   (36, 'productions', 'company_id = $1', 'prod_no'),
   (37, 'obligations', 'company_id = $1', 'due_date'),
   (38, 'recurring_entries', 'company_id = $1', 'created_at'),
   (39, 'work_locations', 'company_id = $1', 'name'),
   (40, 'employees', 'company_id = $1', 'code'),
   (41, 'attendance', 'company_id = $1', 'day, employee_id'),
   (42, 'payroll_runs', 'company_id = $1', 'period'),
   (43, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (44, 'employee_loans', 'company_id = $1', 'loan_no'),
   (45, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (46, 'asset_custodians', 'company_id = $1', 'code'),
   (47, 'fixed_assets', 'company_id = $1', 'code'),
   (48, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (49, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (50, 'asset_movements', 'company_id = $1', 'mov_no'),
   (51, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (52, 'custody_docs', 'company_id = $1', 'doc_no'),
   (53, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (54, 'bank_recons', 'company_id = $1', 'created_at'),
   (55, 'bank_cleared', 'company_id = $1', 'line_id'),
   (56, 'attachments', 'company_id = $1', 'created_at'),
   (57, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
