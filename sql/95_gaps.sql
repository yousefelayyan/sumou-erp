-- =====================================================================
--  المرحلة 95: نواقص الأقسام
--  1) القيود المتكررة بتنسخ الموظف والدائرة ونوع السند
--  2) «اسأل السمو» حسب مندوب كل سطر (السطر ← الفاتورة ← الأصل)
--  3) البصمة والمناوبة الليلية: att_shift_day بيحسب يوم المناوبة (البصمة بعد نص الليل على اليوم اللي قبله)
--  4) كلمة السر: can() بترجع false لمين لازم يغيّر كلمة السر أو انتهت (بيضل بس change_my_password)
--  5) نقطة البيع: بونص من العروض، رقم دفعة، وسيريالات (serial_sync صار يفحص الكاشير كمان)
--  6) الجرد بيعدّ السيريالات (اختياري لكل سطر)
--  7) بونص طلبات المبيعات: order_lines.bonus_qty (بيدخل بالحجز وبيتحوّل سطر بونص بالفاتورة)
--  8) ملاحظات مراجعة 92–94: حذف طلب عليه دفعة مقدمة مرحّلة، حذف مرفق سند مرحّل نوعه بدّه مرفق، وسيلة الدفع للمبيعات/الكاشير
-- =====================================================================

-- 1) القيود المتكررة
create or replace function public.run_recurring(p_company uuid, p_until date default current_date) returns int
language plpgsql security definer set search_path = public as $$
declare r record; s public.journal_entries; fy uuid; nid uuid; n int := 0; guard int; dt uuid; dp uuid;
begin
  if not public.can(p_company, 'journal_entries', 'add') then return 0; end if;
  for r in select * from public.recurring_entries where company_id = p_company and is_active and next_date <= p_until for update loop
    select * into s from public.journal_entries where id = r.source_entry_id;
    -- نوع السند والدائرة بس إذا بينفعوا (النوع فعّال ومش «تاريخ اليوم»، والدائرة من فرع المستخدم)
    dt := (select t.id from public.doc_types t where t.id = s.doc_type_id and t.is_active and not t.date_today and not t.lock_dept);
    dp := case when public.dept_ok(p_company, s.department_id) then s.department_id end;
    begin
    guard := 0;
    while r.next_date <= p_until and (r.end_date is null or r.next_date <= r.end_date) and guard < 24 loop
      guard := guard + 1;
      select id into fy from public.fiscal_years where company_id = p_company and r.next_date between start_date and end_date and not is_closed order by start_date desc limit 1;
      exit when fy is null;
      insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, party_name, cash_account_id, status, department_id, doc_type_id)
      values (p_company, fy, s.entry_type, r.next_date, coalesce(s.description, r.title) || ' (متكرر ' || to_char(r.next_date, 'MM/YYYY') || ')', s.reference, s.party_name, s.cash_account_id, 'draft', dp, dt)
      returning id into nid;
      insert into public.journal_lines (entry_id, line_no, account_id, party_id, employee_id, asset_id, description, debit, credit, cost_center_id, currency, fx_rate, fx_amount)
      select nid, line_no, account_id, party_id, employee_id, asset_id, description, debit, credit, cost_center_id, currency, fx_rate, fx_amount from public.journal_lines where entry_id = s.id;
      n := n + 1;
      r.next_date := (date_trunc('month', r.next_date) + make_interval(months => r.every_months))::date + (r.day_of_month - 1);
    end loop;
    update public.recurring_entries set next_date = r.next_date, last_run = current_date,
           is_active = (r.end_date is null or r.next_date <= r.end_date) where id = r.id;
    exception when others then null;   -- قالب فيه مشكلة ما بيوقّف الباقي
    end;
  end loop;
  return n;
end $$;


-- 2) اسأل السمو
create or replace function public.ask_sales(p_company uuid, p_from date, p_to date, p_group text, p_filters jsonb default '{}'::jsonb, p_top int default null, p_group2 text default null)
returns table (k1 text, k2 text, label1 text, label2 text, qty numeric, net numeric, tax numeric, invoices bigint)
language plpgsql stable security definer set search_path = public as $$
declare f jsonb := coalesce(p_filters, '{}'::jsonb);
begin
  if not (public.can(p_company, 'sales_invoices', 'view') or public.can(p_company, 'reports', 'view')) then raise exception 'ما عندك صلاحية تقارير المبيعات'; end if;
  if coalesce(p_group, 'none') not in ('customer','item','item_category','customer_category','rep','department','warehouse','month','day','none')
     or coalesce(p_group2, 'none') not in ('customer','item','item_category','customer_category','rep','department','warehouse','month','day','none') then
    raise exception 'نوع التجميع مش معروف';
  end if;
  return query
  with l as (
    select v.id inv_id, v.inv_date, v.party_id, v.party_name, coalesce(il.sales_rep_id, v.sales_rep_id, (select o.sales_rep_id from public.invoices o where o.id = v.original_invoice_id)) sales_rep_id, v.department_id, coalesce(v.warehouse_id, (select w.id from public.warehouses w where w.company_id = v.company_id and w.is_active order by w.code limit 1)) wh,
           il.item_id, il.description,
           case when v.inv_type = 'sale_return' then -1 else 1 end sgn, il.qty, il.subtotal, il.tax_amount
      from public.invoices v join public.invoice_lines il on il.invoice_id = v.id
     where v.company_id = p_company and v.inv_type in ('sale','sale_return') and v.status = 'posted'
       and (public.dept_allowed(p_company) is null or v.department_id = any (public.dept_allowed(p_company)))
       and v.inv_date between p_from and p_to
       and (f ->> 'rep_id' is null or coalesce(il.sales_rep_id, v.sales_rep_id, (select o.sales_rep_id from public.invoices o where o.id = v.original_invoice_id)) = (f ->> 'rep_id')::uuid)
       and (f ->> 'party_id' is null or v.party_id = (f ->> 'party_id')::uuid)
       and (f ->> 'department_id' is null or v.department_id = (f ->> 'department_id')::uuid)
       and (f ->> 'item_id' is null or il.item_id = (f ->> 'item_id')::uuid)
       and (f ->> 'item_category_id' is null or exists (select 1 from public.items i where i.id = il.item_id and i.category_id = (f ->> 'item_category_id')::uuid))
       and (f ->> 'party_category_id' is null or exists (select 1 from public.parties p where p.id = v.party_id and p.category_id = (f ->> 'party_category_id')::uuid))
  ), d as (
    select l.*, p.name pname, p.code pcode, p.category_id pcat, i.name iname, i.code icode, i.category_id icat
      from l left join public.parties p on p.id = l.party_id left join public.items i on i.id = l.item_id
  ), g as (
    select
      case p_group when 'customer' then coalesce(d.party_id::text, 'cash:' || coalesce(d.party_name, '')) when 'item' then coalesce(d.item_id::text, 'd:' || coalesce(d.description, ''))
        when 'item_category' then coalesce(d.icat::text, '-') when 'customer_category' then coalesce(d.pcat::text, '-') when 'rep' then coalesce(d.sales_rep_id::text, '-')
        when 'department' then coalesce(d.department_id::text, '-') when 'warehouse' then d.wh::text when 'month' then to_char(d.inv_date, 'YYYY-MM') when 'day' then d.inv_date::text else 'all' end a1,
      case p_group2 when 'customer' then coalesce(d.party_id::text, 'cash:' || coalesce(d.party_name, '')) when 'item' then coalesce(d.item_id::text, 'd:' || coalesce(d.description, ''))
        when 'item_category' then coalesce(d.icat::text, '-') when 'customer_category' then coalesce(d.pcat::text, '-') when 'rep' then coalesce(d.sales_rep_id::text, '-')
        when 'department' then coalesce(d.department_id::text, '-') when 'warehouse' then d.wh::text when 'month' then to_char(d.inv_date, 'YYYY-MM') when 'day' then d.inv_date::text else '' end a2,
      d.*
      from d
  ), s as (
    select a1, a2, sum(sgn * g.qty) q, sum(sgn * g.subtotal) n, sum(sgn * g.tax_amount) t, count(distinct inv_id) c from g group by a1, a2
  ), lab as (
    select s.*,
      (select case p_group
          when 'customer' then coalesce((select x.name from public.parties x where x.id::text = s.a1 and x.company_id = p_company), nullif(replace(s.a1, 'cash:', ''), ''), 'زبون نقدي')
          when 'item' then coalesce((select x.code || ' — ' || x.name from public.items x where x.id::text = s.a1 and x.company_id = p_company), nullif(replace(s.a1, 'd:', ''), ''), 'بدون صنف')
          when 'item_category' then coalesce((select x.name from public.item_categories x where x.id::text = s.a1 and x.company_id = p_company), 'بدون فئة')
          when 'customer_category' then coalesce((select x.name from public.party_categories x where x.id::text = s.a1 and x.company_id = p_company), 'بدون فئة')
          when 'rep' then coalesce((select x.name from public.lookups x where x.id::text = s.a1 and x.company_id = p_company), 'بدون مندوب')
          when 'department' then coalesce((select x.name from public.departments x where x.id::text = s.a1 and x.company_id = p_company), 'بدون دائرة')
          when 'warehouse' then coalesce((select x.name from public.warehouses x where x.id::text = s.a1 and x.company_id = p_company), '')
          when 'none' then 'الإجمالي' else s.a1 end) l1,
      (select case p_group2
          when 'customer' then coalesce((select x.name from public.parties x where x.id::text = s.a2 and x.company_id = p_company), nullif(replace(s.a2, 'cash:', ''), ''), 'زبون نقدي')
          when 'item' then coalesce((select x.code || ' — ' || x.name from public.items x where x.id::text = s.a2 and x.company_id = p_company), nullif(replace(s.a2, 'd:', ''), ''), 'بدون صنف')
          when 'item_category' then coalesce((select x.name from public.item_categories x where x.id::text = s.a2 and x.company_id = p_company), 'بدون فئة')
          when 'customer_category' then coalesce((select x.name from public.party_categories x where x.id::text = s.a2 and x.company_id = p_company), 'بدون فئة')
          when 'rep' then coalesce((select x.name from public.lookups x where x.id::text = s.a2 and x.company_id = p_company), 'بدون مندوب')
          when 'department' then coalesce((select x.name from public.departments x where x.id::text = s.a2 and x.company_id = p_company), 'بدون دائرة')
          when 'warehouse' then coalesce((select x.name from public.warehouses x where x.id::text = s.a2 and x.company_id = p_company), '')
          else s.a2 end) l2
      from s
  )
  select a1, a2, l1, l2, round(q, 3), round(n, 3), round(t, 3), c from lab
   order by case when p_group in ('month', 'day') then a1 end, n desc nulls last
   limit coalesce(p_top, 5000);
end $$;


-- 3) المناوبة الليلية
create or replace function public.att_shift_day(p_emp uuid, p_ts timestamp) returns date
language sql stable security definer set search_path = public as $$
  select coalesce((select case when s.end_time <= s.start_time
                               then (p_ts - greatest(s.start_time - time '04:00', interval '0'))::date end
                     from public.employees e join public.work_shifts s on s.id = e.shift_id where e.id = p_emp), p_ts::date)
$$;
revoke execute on function public.att_shift_day(uuid, timestamp) from public, anon, authenticated;

create or replace function public.attendance_punch(p_company uuid, p_kind text, p_lat numeric, p_lng numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare emp public.employees; cfg jsonb; loc record; d date; a public.attendance; dist int; v_out boolean := false;
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
  d := public.att_shift_day(emp.id, (now() at time zone 'Asia/Amman')::timestamp);
  -- المناوبة الليلية: الانصراف بعد نص الليل بيسكّر حضور اليوم اللي قبله
  if p_kind = 'out' and not exists (select 1 from public.attendance where employee_id = emp.id and day = d and check_in is not null)
     and exists (select 1 from public.attendance where employee_id = emp.id and day = d - 1 and check_in is not null and check_out is null and check_in > now() - interval '16 hours') then
    d := d - 1;
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


create or replace function public.attendance_import(p_company uuid, p_rows jsonb, p_overwrite boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  n int; r record; ins int := 0; upd int := 0; skip_sup int := 0; fut int := 0; bad int := 0; matched int := 0;
  unm text[]; ex public.attendance; ci timestamptz; co timestamptz; lo timestamptz; hi timestamptz;
begin
  if not public.can(p_company, 'payroll', 'edit') or not public.tenant_writable() then raise exception 'استيراد البصمة للمشرف (تعديل الرواتب)'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'البيانات مش صحيحة'; end if;
  n := jsonb_array_length(p_rows);
  if n > 50000 then raise exception 'الملف كبير: أقصى 50000 بصمة بالمرة'; end if;

  create temp table if not exists _fp (code text, ts timestamp) on commit drop;
  truncate _fp;
  insert into _fp (code, ts)
  select nullif(trim(x ->> 'code'), ''),
         case when (x ->> 'ts') ~ '^\d{4}-\d{2}-\d{2}[ T]\d{1,2}:\d{2}(:\d{2})?$' then (x ->> 'ts')::timestamp end
  from jsonb_array_elements(p_rows) x;
  select count(*) into bad from _fp where code is null or ts is null;
  delete from _fp where code is null or ts is null;
  select count(*) into fut from _fp where ts::date > public.local_today();
  delete from _fp where ts::date > public.local_today();

  -- المطابقة: رقم البصمة، وإذا الموظف ما إله رقم بصمة على رمزه
  create temp table if not exists _fpm (employee_id uuid, day date, lo timestamp, hi timestamp, cnt int) on commit drop;
  truncate _fpm;
  insert into _fpm
  select e.id, public.att_shift_day(e.id, f.ts), min(f.ts), max(f.ts), count(*)::int
  from _fp f
  join public.employees e on e.company_id = p_company
   and (e.device_code = f.code or (e.device_code is null and e.code = f.code
        and not exists (select 1 from public.employees e2 where e2.company_id = p_company and e2.device_code = f.code)))
  group by e.id, public.att_shift_day(e.id, f.ts);
  select coalesce(sum(cnt), 0) into matched from _fpm;
  select coalesce(array_agg(distinct f.code order by f.code), '{}') into unm from _fp f
   where not exists (select 1 from public.employees e where e.company_id = p_company and (e.device_code = f.code or (e.device_code is null and e.code = f.code)));

  for r in select * from _fpm order by employee_id, day loop
    lo := r.lo at time zone 'Asia/Amman'; hi := r.hi at time zone 'Asia/Amman';
    select * into ex from public.attendance where employee_id = r.employee_id and day = r.day;
    if not found then
      insert into public.attendance (company_id, employee_id, day, check_in, check_out, source, updated_by)
      values (p_company, r.employee_id, r.day, lo, case when hi > lo + interval '1 minute' then hi end, 'device', auth.uid());
      ins := ins + 1;
    elsif ex.source = 'supervisor' and not p_overwrite then
      skip_sup := skip_sup + 1;
    else
      if p_overwrite and ex.source = 'supervisor' then
        ci := lo; co := case when hi > lo + interval '1 minute' then hi end;
      else
        ci := least(lo, ex.check_in);
        co := greatest(hi, ex.check_out, ex.check_in);
        if co <= ci + interval '1 minute' then co := null; end if;
      end if;
      update public.attendance set check_in = ci, check_out = co, source = 'device', updated_by = auth.uid(), updated_at = now()
       where id = ex.id and (check_in is distinct from ci or check_out is distinct from co or source <> 'device');
      if found then upd := upd + 1; end if;
    end if;
  end loop;

  return jsonb_build_object('rows', n, 'matched', matched, 'days', (select count(*) from _fpm), 'inserted', ins, 'updated', upd,
    'skipped_supervisor', skip_sup, 'future', fut, 'invalid', bad, 'unmatched', to_jsonb(unm));
end $$;


-- 4) كلمة السر
create or replace function public.can(cid uuid, screen text, act text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    join public.tenants t on t.id = p.tenant_id and t.status = 'active'
    join public.companies c on c.id = cid and c.tenant_id = p.tenant_id
    where p.id = auth.uid() and p.is_active
      and not p.must_change_password
      and not (coalesce((t.settings -> 'password_policy' ->> 'expiry_days')::int, 0) > 0
               and coalesce(p.password_changed_at, '-infinity') < now() - make_interval(days => (t.settings -> 'password_policy' ->> 'expiry_days')::int))
      and (t.modules is null or public.screen_module(screen) = 'core' or public.screen_module(screen) = any (t.modules))
      and (act in ('view', 'print') or t.expires_at is null or t.expires_at >= current_date)
      and (p.is_admin or exists (
        select 1 from public.user_companies uc
        left join public.user_groups g on g.id = uc.group_id
        where uc.user_id = p.id and uc.company_id = cid
          and not (uc.branch_only and screen = 'reports')
          and ((case jsonb_typeof(p.permissions -> screen)
                  when 'boolean' then (p.permissions ->> screen)::boolean
                  when 'object'  then coalesce((p.permissions -> screen ->> act)::boolean, false)
                  else false end)
               or coalesce((g.permissions -> screen ->> act)::boolean, false))))
  );
$$;

-- 5) نقطة البيع
create or replace function public.pos_checkout(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cid uuid; fy uuid; d date := public.local_today();
  st public.company_settings; cfg jsonb; iid uuid; l jsonb; it public.items; n int := 0;
  qty numeric; price numeric; disc numeric; rate numeric; gross numeric; sub numeric; tax numeric; paid numeric;
  s_sub numeric := 0; s_tax numeric := 0; s_disc numeric := 0; incl boolean; meth text; acc uuid; wh uuid; inv public.invoices;
  can_edit boolean; can_disc boolean; inv_disc numeric := 0; tot_g numeric; share numeric; left_d numeric; xl record; k int;
  pty public.parties; bno text; sers text[]; bsers text[]; fq numeric; nb int; pay_type text := 'cash'; rep_id uuid; pm public.lookups; is_cash boolean; mname text; prev text := current_setting('sumou.pos', true); lines jsonb;
begin
  begin
    cid := (p ->> 'company_id')::uuid; fy := (p ->> 'fiscal_year_id')::uuid; paid := nullif(p ->> 'paid', '')::numeric;
  exception when others then raise exception 'بيانات البيع مش صحيحة';
  end;
  if cid is null or not public.can(cid, 'pos', 'add') then raise exception 'ما عندك صلاحية البيع من نقطة البيع'; end if;
  if coalesce(jsonb_typeof(p -> 'lines'), '') <> 'array' or jsonb_array_length(p -> 'lines') = 0 then raise exception 'السلة فاضية'; end if;
  if jsonb_array_length(p -> 'lines') > 300 then raise exception 'السلة كبيرة كثير'; end if;
  if not exists (select 1 from public.fiscal_years where id = fy and company_id = cid and not is_closed and d between start_date and end_date) then
    raise exception 'لازم تكون على السنة المالية المفتوحة اللي فيها تاريخ اليوم';
  end if;
  can_edit := public.can(cid, 'sales_invoices', 'edit');
  can_disc := can_edit or public.can(cid, 'pos', 'edit');   -- الخصم: صلاحية «تعديل» على نقطة البيع
  begin inv_disc := round(greatest(coalesce(nullif(p ->> 'discount', '')::numeric, 0), 0), 3);
  exception when others then raise exception 'الخصم مش صحيح'; end;
  if inv_disc > 0 and not can_disc then raise exception 'ما عندك صلاحية تعمل خصم'; end if;
  -- مندوب المبيعات (اختياري)
  if nullif(p ->> 'sales_rep_id', '') is not null then
    begin rep_id := (p ->> 'sales_rep_id')::uuid; exception when invalid_text_representation then raise exception 'المندوب مش صحيح'; end;
    if not exists (select 1 from public.lookups r where r.id = rep_id and r.company_id = cid and r.kind = 'sales_rep' and r.is_active) then raise exception 'المندوب مش موجود'; end if;
  end if;
  -- الزبون (بطاقة عميل) اختياري للنقدي، ولازم للآجل
  if nullif(p ->> 'party_id', '') is not null then
    begin select * into pty from public.parties where id = (p ->> 'party_id')::uuid;
    exception when invalid_text_representation then raise exception 'الزبون مش صحيح'; end;
    if pty.id is null or pty.company_id <> cid or pty.party_type <> 'customer' or not pty.is_active then raise exception 'الزبون مش موجود'; end if;
  end if;
  perform public.ensure_company_settings(cid);
  select * into st from public.company_settings where company_id = cid;
  cfg := coalesce(st.pos, '{}'::jsonb);
  -- إعدادات كاشير الفرع (دائرة المستخدم الافتراضية) بتغطي على إعدادات الشركة
  cfg := cfg || coalesce((select d.pos || case when d.pos ? 'warehouse_id' or d.warehouse_id is null then '{}'::jsonb else jsonb_build_object('warehouse_id', d.warehouse_id) end
                           from public.user_companies uc join public.departments d on d.id = uc.department_id and d.company_id = uc.company_id and d.is_active
                           where uc.user_id = auth.uid() and uc.company_id = cid), '{}'::jsonb);
  incl := coalesce((cfg ->> 'prices_include_tax')::boolean, true);
  if p ->> 'method' = 'credit' then
    -- آجل: على حساب الزبون
    if pty.id is null then raise exception 'البيع الآجل لازم تختار الزبون'; end if;
    if coalesce((cfg ->> 'allow_credit')::boolean, true) is false then raise exception 'البيع الآجل مسكّر بإعدادات نقطة البيع'; end if;
    meth := 'credit'; pay_type := 'credit'; acc := null; mname := 'آجل';
  elsif nullif(p ->> 'method_id', '') is not null then
    -- وسيلة دفع من «إعداد ← وسائل الدفع» (مأشّر عليها «نقطة البيع»)، وحسابها هو الطرف المدين
    begin select * into pm from public.lookups where id = (p ->> 'method_id')::uuid;
    exception when invalid_text_representation then raise exception 'وسيلة الدفع مش صحيحة'; end;
    if pm.id is null or pm.company_id <> cid or pm.kind <> 'payment_method' or not pm.is_active or not pm.use_pos or pm.account_id is null then
      raise exception 'وسيلة الدفع مش متاحة بنقطة البيع';
    end if;
    acc := pm.account_id; mname := coalesce(nullif(pm.pos_label, ''), pm.name); meth := 'method';
    if not exists (select 1 from public.accounts a where a.id = acc and a.company_id = cid and not a.is_group and a.is_active) then
      raise exception 'حساب وسيلة الدفع «%» لازم يكون حساب فرعي فعّال من نفس الشركة', mname;
    end if;
  else
    meth := coalesce(nullif(p ->> 'method', ''), 'cash');
    if meth not in ('cash', 'card') then raise exception 'طريقة الدفع مش صحيحة'; end if;
    acc := case when meth = 'card' then coalesce(nullif(cfg ->> 'card_account_id', '')::uuid, nullif(cfg ->> 'cash_account_id', '')::uuid, st.cash_account_id)
                else coalesce(nullif(cfg ->> 'cash_account_id', '')::uuid, st.cash_account_id) end;
    mname := case meth when 'card' then 'بطاقة' else 'نقدي' end;
    if acc is null then raise exception 'حدد صندوق نقطة البيع من «إعدادات نقطة البيع»'; end if;
    if not exists (select 1 from public.accounts a where a.id = acc and a.company_id = cid and not a.is_group and a.is_active and a.account_type in ('cash', 'bank')) then
      raise exception 'حساب الصندوق/البطاقات بإعدادات نقطة البيع لازم يكون حساب صندوق أو بنك فرعي من نفس الشركة';
    end if;
  end if;
  -- الباقي بس للوسائل اللي حسابها صندوق نقدي
  is_cash := meth <> 'credit' and (exists (select 1 from public.accounts a where a.id = acc and a.account_type = 'cash') or meth = 'cash');
  wh := nullif(cfg ->> 'warehouse_id', '')::uuid;
  if wh is not null and not exists (select 1 from public.warehouses w where w.id = wh and w.company_id = cid) then
    raise exception 'مستودع نقطة البيع مش من نفس الشركة';
  end if;

  perform set_config('sumou.pos', public.internal_token() || ':' || cid::text, true);
  insert into public.invoices (company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id, party_name, cash_account_id,
                               prices_include_tax, warehouse_id, notes, reference, pos, pos_method, sales_rep_id)
  values (cid, fy, 'sale', d, pay_type, pty.id, case when pay_type = 'cash' then coalesce(left(nullif(trim(p ->> 'party_name'), ''), 120), pty.name) end, acc,
          incl, wh, left(nullif(trim(p ->> 'notes'), ''), 500), 'نقطة بيع', true, mname, rep_id)
  returning id into iid;

  for l in select * from jsonb_array_elements(p -> 'lines') loop
    n := n + 1;
    begin
      select * into it from public.items where id = (l ->> 'item_id')::uuid and company_id = cid and is_active;
      qty := round(coalesce((l ->> 'qty')::numeric, 0), 3);
      price := round(coalesce((l ->> 'price')::numeric, it.sale_price), 3);
      disc := round(greatest(coalesce((l ->> 'discount')::numeric, 0), 0), 3);
      bno := left(nullif(trim(l ->> 'batch_no'), ''), 60);
      sers := case when jsonb_typeof(l -> 'serials') = 'array' then (select array_agg(left(trim(x), 60)) from jsonb_array_elements_text(l -> 'serials') x where trim(x) <> '') end;
      bsers := case when jsonb_typeof(l -> 'bonus_serials') = 'array' then (select array_agg(left(trim(x), 60)) from jsonb_array_elements_text(l -> 'bonus_serials') x where trim(x) <> '') end;
    exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'سطر % مش صحيح', n;
    end;
    if it.id is null then raise exception 'صنف مش موجود أو موقوف (سطر %)', n; end if;
    if qty <= 0 or qty > 100000 then raise exception 'الكمية مش منطقية (%)', it.name; end if;
    -- السعر والخصم من الصنف إلا إذا معه صلاحية تعديل الفواتير
    if not can_edit then price := it.sale_price; end if;
    if not can_disc then disc := 0; end if;
    if price < 0 then raise exception 'السعر سالب (%)', it.name; end if;
    rate := it.tax_rate;
    gross := round(qty * price - disc, 3);
    if gross < 0 then raise exception 'الخصم أكبر من قيمة السطر (%)', it.name; end if;
    if incl then sub := round(gross / (1 + rate / 100), 3); tax := gross - sub; else sub := gross; tax := round(sub * rate / 100, 3); end if;
    insert into public.invoice_lines (invoice_id, line_no, item_id, description, qty, unit_price, discount, tax_rate, account_id, subtotal, tax_amount, line_total, batch_no, serials)
    values (iid, n, it.id, it.name, qty, price, disc, rate, it.sales_account_id, sub, tax, sub + tax, bno, sers);
    s_sub := s_sub + sub; s_tax := s_tax + tax; s_disc := s_disc + disc;
    -- البونص (المرحلة 95): من العروض الفعّالة بتاريخ اليوم (اشترِ N خذ M)، بيحسبه النظام مش الكاشير
    select max(case when pr.free_repeat then floor(qty / pr.buy_qty) * pr.free_qty else pr.free_qty end) into fq
      from public.promotions pr
     where pr.company_id = cid and pr.is_active and d between pr.date_from and pr.date_to and coalesce(pr.buy_qty, 0) > 0 and coalesce(pr.free_qty, 0) > 0
       and qty >= greatest(pr.buy_qty, coalesce(pr.min_qty, 0))
       and (pr.item_id = it.id or (pr.item_id is null and pr.category_id = it.category_id) or (pr.item_id is null and pr.category_id is null));
    if coalesce(fq, 0) > 0 then
      if it.serial_tracked and coalesce(array_length(bsers, 1), 0) <> fq then raise exception '«%» عليه بونص % حبة؛ اكتب سيريالات البونص', it.name, fq; end if;
      n := n + 1;
      insert into public.invoice_lines (invoice_id, line_no, item_id, description, qty, unit_price, discount, tax_rate, account_id, subtotal, tax_amount, line_total, batch_no, serials, is_bonus)
      values (iid, n, it.id, it.name || ' (بونص)', fq, 0, 0, 0, it.sales_account_id, 0, 0, 0, bno, bsers, true);
    end if;
  end loop;
  -- خصم على الفاتورة كلها: بيتوزّع على السطور حسب قيمتها
  if inv_disc > 0 then
    select sum(round(x.qty * x.unit_price - x.discount, 3)) into tot_g from public.invoice_lines x where x.invoice_id = iid and not x.is_bonus;
    if inv_disc > tot_g then raise exception 'الخصم (%) أكبر من مجموع الفاتورة (%)', inv_disc, tot_g; end if;
    left_d := inv_disc; k := 0; s_sub := 0; s_tax := 0; s_disc := 0;
    select count(*) into nb from public.invoice_lines x where x.invoice_id = iid and not x.is_bonus;
    for xl in select * from public.invoice_lines x where x.invoice_id = iid and not x.is_bonus order by x.line_no loop
      k := k + 1;
      gross := round(xl.qty * xl.unit_price - xl.discount, 3);
      share := case when k = nb then left_d else least(left_d, round(inv_disc * gross / nullif(tot_g, 0), 3)) end;
      share := least(share, gross); left_d := left_d - share;
      gross := gross - share;
      if incl then sub := round(gross / (1 + xl.tax_rate / 100), 3); tax := gross - sub; else sub := gross; tax := round(sub * xl.tax_rate / 100, 3); end if;
      update public.invoice_lines set discount = xl.discount + share, subtotal = sub, tax_amount = tax, line_total = sub + tax where id = xl.id;
      s_sub := s_sub + sub; s_tax := s_tax + tax; s_disc := s_disc + xl.discount + share;
    end loop;
  end if;
  if inv_disc > 0 and left_d > 0.0005 then raise exception 'الخصم ما انوزّع كله على السطور؛ قلّل الخصم'; end if;
  update public.invoices set pos_method_id = pm.id where id = iid and pm.id is not null;
  if is_cash then
    paid := coalesce(paid, s_sub + s_tax);
    if paid + 0.0005 < s_sub + s_tax then raise exception 'المدفوع (%) أقل من المطلوب (%)', paid, s_sub + s_tax; end if;
  elsif meth = 'credit' then paid := 0;
  else paid := s_sub + s_tax; end if;
  update public.invoices set subtotal = s_sub, tax_total = s_tax, discount_total = s_disc, total = s_sub + s_tax, pos_paid = paid where id = iid;

  perform public.post_invoice(iid);
  if public.posting_flag(cid, 'sale', 'stock') then perform public.post_invoice_stock(iid); end if;
  perform set_config('sumou.pos', coalesce(prev, ''), true);
  select * into inv from public.invoices where id = iid;
  select jsonb_agg(jsonb_build_object('name', x.description, 'qty', x.qty, 'price', x.unit_price, 'discount', x.discount, 'total', round(x.qty * x.unit_price - x.discount, 3), 'bonus', x.is_bonus) order by x.line_no)
    into lines from public.invoice_lines x where x.invoice_id = iid;
  return jsonb_build_object('id', inv.id, 'no', inv.inv_no, 'doc_code', inv.doc_code, 'total', inv.total, 'subtotal', inv.subtotal,
    'tax', inv.tax_total, 'discount', inv.discount_total, 'paid', inv.pos_paid, 'change', inv.pos_paid - inv.total,
    'stock_posted', inv.stock_posted, 'method', inv.pos_method, 'customer', pty.name, 'customer_phone', coalesce(pty.mobile, pty.phone), 'created_at', inv.created_at, 'lines', lines);
end $$;


-- 6) السيريالات (الكاشير + الجرد)
create or replace function public.serial_sync(p_kind text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invoices; d public.stock_docs; r record; w uuid; sgn int; n int;
begin
  if p_kind = 'invoice' then
    select * into i from public.invoices where id = p_id;
    w := coalesce(i.warehouse_id, (select id from public.warehouses where company_id = i.company_id and is_active order by code limit 1));
    sgn := case when i.inv_type in ('purchase','sale_return') then 1 else -1 end;
    for r in select l.* from public.invoice_lines l join public.items it on it.id = l.item_id
              where l.invoice_id = p_id and it.item_type = 'goods' and it.track_stock and it.serial_tracked order by l.line_no loop
      n := coalesce(array_length(r.serials, 1), 0);
      if r.qty <> n then raise exception 'السطر %: عدد السيريالات (%) لازم يساوي الكمية (%)', r.line_no, n, r.qty; end if;
      if i.inv_type = 'sale_return' and exists (select 1 from unnest(r.serials) x where not exists (
           select 1 from public.serial_moves m where m.company_id = i.company_id and m.item_id = r.item_id and m.serial = x and m.qty = -1 and m.move_date <= i.inv_date)) then
        raise exception 'السطر %: مرتجع البيع لازم يكون بسيريال انباع من قبل', r.line_no;
      end if;
      insert into public.serial_moves (company_id, item_id, serial, warehouse_id, move_date, qty, source_type, source_id, line_id)
      select i.company_id, r.item_id, x, w, i.inv_date, sgn, 'invoice', p_id, r.id from unnest(r.serials) x;
      perform public.serial_validate(i.company_id, r.item_id, r.serials);
    end loop;
  else
    select * into d from public.stock_docs where id = p_id;
    if d.production_id is not null then return; end if;
    if d.doc_type = 'count' then
      if exists (select 1 from public.stock_doc_lines l where l.doc_id = p_id and coalesce(array_length(l.serials, 1), 0) > 0 group by l.item_id having count(*) > 1) then
        raise exception 'بجرد السيريالات كل صنف بسطر واحد (جمّع سيريالاته بنفس السطر)';
      end if;
      -- جرد السيريالات (اختياري لكل سطر): الموجود بالمستودع ومش بالقائمة = −1، وبالقائمة ومش موجود = +1
      for r in select l.* from public.stock_doc_lines l join public.items it on it.id = l.item_id
                where l.doc_id = p_id and it.item_type = 'goods' and it.track_stock and it.serial_tracked and coalesce(array_length(l.serials, 1), 0) > 0 order by l.line_no loop
        n := array_length(r.serials, 1);
        if coalesce(r.counted_qty, 0) <> n then raise exception 'السطر %: عدد السيريالات المعدودة (%) لازم يساوي الكمية الفعلية (%)', r.line_no, n, r.counted_qty; end if;
        insert into public.serial_moves (company_id, item_id, serial, warehouse_id, move_date, qty, source_type, source_id, line_id)
        select d.company_id, r.item_id, x.serial, d.warehouse_id, d.doc_date, -1, 'stock_doc', p_id, r.id
          from (select m.serial from public.serial_moves m where m.company_id = d.company_id and m.item_id = r.item_id and m.warehouse_id = d.warehouse_id and m.move_date <= d.doc_date
                 group by m.serial having sum(m.qty) > 0) x
         where x.serial <> all (r.serials);
        insert into public.serial_moves (company_id, item_id, serial, warehouse_id, move_date, qty, source_type, source_id, line_id)
        select d.company_id, r.item_id, x, d.warehouse_id, d.doc_date, 1, 'stock_doc', p_id, r.id from unnest(r.serials) x
         where not exists (select 1 from public.serial_moves m where m.company_id = d.company_id and m.item_id = r.item_id and m.warehouse_id = d.warehouse_id
                             and m.serial = x and m.move_date <= d.doc_date and m.source_id <> p_id group by m.serial having sum(m.qty) > 0);
        perform public.serial_validate(d.company_id, r.item_id, r.serials || coalesce((select array_agg(serial) from public.serial_moves where source_id = p_id and line_id = r.id), '{}'));
      end loop;
      return;
    end if;
    if d.doc_type = 'in' and d.supply_request_id is not null then   -- إدخال طلب التزويد: نفس سيريالات الإخراج
      insert into public.serial_moves (company_id, item_id, serial, warehouse_id, move_date, qty, source_type, source_id, line_id)
      select d.company_id, m.item_id, m.serial, d.warehouse_id, d.doc_date, 1, 'stock_doc', p_id, null
        from public.serial_moves m join public.supply_requests q on q.id = d.supply_request_id
       where m.source_type = 'stock_doc' and m.source_id = q.out_doc_id and m.qty = -1;
      for r in select item_id, array_agg(serial) s from public.serial_moves where source_id = p_id group by item_id loop
        perform public.serial_validate(d.company_id, r.item_id, r.s);
      end loop;
      return;
    end if;
    for r in select l.* from public.stock_doc_lines l join public.items it on it.id = l.item_id
              where l.doc_id = p_id and it.item_type = 'goods' and it.track_stock and it.serial_tracked order by l.line_no loop
      n := coalesce(array_length(r.serials, 1), 0);
      if abs(r.qty) <> n then raise exception 'السطر %: عدد السيريالات (%) لازم يساوي الكمية (%)', r.line_no, n, abs(r.qty); end if;
      insert into public.serial_moves (company_id, item_id, serial, warehouse_id, move_date, qty, source_type, source_id, line_id)
      select d.company_id, r.item_id, x, d.warehouse_id, d.doc_date, case when d.doc_type = 'in' then 1 else -1 end, 'stock_doc', p_id, r.id from unnest(r.serials) x;
      if d.doc_type = 'transfer' then
        insert into public.serial_moves (company_id, item_id, serial, warehouse_id, move_date, qty, source_type, source_id, line_id)
        select d.company_id, r.item_id, x, d.to_warehouse_id, d.doc_date, 1, 'stock_doc', p_id, r.id from unnest(r.serials) x;
      end if;
      perform public.serial_validate(d.company_id, r.item_id, r.serials);
    end loop;
  end if;
end $$;


-- طلبات المبيعات: بونص لكل سطر
alter table public.order_lines add column if not exists bonus_qty numeric(18,3) not null default 0;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'order_lines_bonus_chk') then
    alter table public.order_lines add constraint order_lines_bonus_chk check (bonus_qty >= 0 and bonus_qty <= 1000000);
  end if;
end $$;
create or replace function public.reserved_rows(p_company uuid) returns table (item_id uuid, warehouse_id uuid, reserved numeric, orders bigint)
language sql stable security definer set search_path = public as $$
  select l.item_id, coalesce(o.warehouse_id, public.reserve_default_wh(p_company)), sum(l.qty + l.bonus_qty), count(distinct o.id)
  from public.orders o join public.order_lines l on l.order_id = o.id
  where o.company_id = p_company and o.order_type = 'sales_order' and o.status = 'open' and not o.closed and o.reserve
    and (o.valid_until is null or o.valid_until >= public.local_today()) and l.item_id is not null and l.qty + l.bonus_qty > 0
  group by 1, 2
$$;

-- ملاحظات المراجعة: حذف طلب عليه دفعة مقدمة مرحّلة برسالة واضحة
create or replace function public.ab_order_advance_delete() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.journal_entries e where e.order_id = old.id and e.status = 'posted' and e.reversed_by is null) then
    raise exception 'الطلب عليه دفعة مقدمة مرحّلة؛ ألغِ الطلب بدل الحذف (أو اعكس سند الدفعة أول)';
  end if;
  return old;
end $$;
drop trigger if exists ab_order_advance_delete on public.orders;
create trigger ab_order_advance_delete before delete on public.orders for each row execute function public.ab_order_advance_delete();

-- مرفق سند مرحّل نوعه «ما بيترحّل بدون مرفق» ما بينحذف إذا هو آخر مرفق
create or replace function public.ab_attach_required_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.entity = 'entry' and exists (select 1 from public.journal_entries e join public.doc_types t on t.id = e.doc_type_id
       where e.id = old.entity_id and e.status = 'posted' and t.require_attach)
     and not exists (select 1 from public.attachments a where a.entity = 'entry' and a.entity_id = old.entity_id and a.id <> old.id) then
    raise exception 'السند مرحّل ونوعه بدّه مرفق؛ ما بينحذف آخر مرفق';
  end if;
  return old;
end $$;
drop trigger if exists ab_attach_required_guard on public.attachments;
create trigger ab_attach_required_guard before delete on public.attachments for each row execute function public.ab_attach_required_guard();

-- وسيلة الدفع بالفاتورة لازم مفعّلة للمبيعات (أو للمشتريات بفواتير الشراء)
create or replace function public.ad_invoice_pm_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.payment_method_id is not null and (tg_op = 'INSERT' or new.payment_method_id is distinct from old.payment_method_id)
     and not exists (select 1 from public.lookups where id = new.payment_method_id and company_id = new.company_id and kind = 'payment_method' and is_active
                       and (case when new.inv_type in ('purchase','purchase_return') then coalesce(use_purchases, true) else coalesce(use_sales, true) or coalesce(use_pos, false) end)) then
    raise exception 'وسيلة الدفع مش من هالشركة أو مش مفعّلة لهالنوع';
  end if;
  if new.payment_type <> 'cash' then new.payment_method_id := null; end if;
  if not public.is_internal() then new.pm_commission := coalesce(case when tg_op = 'UPDATE' then old.pm_commission end, 0); end if;
  return new;
end $$;

-- 4ب) قفل كلمة السر كمان على الإدارة وأي كتابة (is_admin و tenant_writable)
create or replace function public.pwd_ok() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select not p.must_change_password
                      and not (coalesce((t.settings -> 'password_policy' ->> 'expiry_days')::int, 0) > 0
                               and coalesce(p.password_changed_at, '-infinity') < now() - make_interval(days => (t.settings -> 'password_policy' ->> 'expiry_days')::int))
                   from public.profiles p join public.tenants t on t.id = p.tenant_id where p.id = auth.uid()), true);
$$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.is_admin and p.is_active and t.status = 'active'
                   from public.profiles p join public.tenants t on t.id = p.tenant_id
                   where p.id = auth.uid()), false) and public.pwd_ok();
$$;
create or replace function public.tenant_writable() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select t.status = 'active' and (t.expires_at is null or t.expires_at >= current_date)
                   from public.profiles p join public.tenants t on t.id = p.tenant_id
                   where p.id = auth.uid()), false) and public.pwd_ok();
$$;
