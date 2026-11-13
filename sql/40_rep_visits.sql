-- =====================================================================
--  السمو ERP — المرحلة 40: تطبيق المندوب (الزيارات ودفعات العملاء من الجوال)
--  زيارة: بداية/نهاية بالوقت والموقع، ملاحظات ومصاريف مواصلات، وصور إثبات (المرفقات entity = 'visit').
--  دفعة عميل: نقد/تحويل = سند قبض (مسودة، أو مرحّل لمين إله ترحيل)، شيكات = register_cheque.
--  الصلاحية: شاشة rep_visits (قسم المبيعات). المندوب بيشوف زياراته؛ المشرف (edit) بيشوف الكل.
-- =====================================================================
create or replace function public.screen_module(s text) returns text
language sql immutable as $$
  select case
    when s in ('customers','sales_invoices','sales_orders','pos','rep_visits')  then 'sales'
    when s in ('suppliers','purchase_invoices','purchase_orders')   then 'purchases'
    when s in ('inventory','supply_requests')                       then 'inventory'
    when s in ('cheques','bank_recon')                              then 'banking'
    when s = 'payroll'                                              then 'payroll'
    when s in ('fixed_assets','asset_custody')                      then 'assets'
    when s = 'marketing'                                            then 'marketing'
    when s = 'manufacturing'                                        then 'manufacturing'
    when s = 'maintenance'                                          then 'maintenance'
    when s = 'obligations'                                          then 'office'
    else 'core' end;
$$;

create table if not exists public.sales_visits (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  user_id      uuid not null default auth.uid(),
  rep_id       uuid references public.lookups(id) on delete set null,
  party_id     uuid not null references public.parties(id),
  started_at   timestamptz not null default now(),
  ended_at     timestamptz,
  start_lat    numeric(10,6), start_lng numeric(10,6),
  end_lat      numeric(10,6), end_lng numeric(10,6),
  purpose      text,
  notes        text,
  outcome      text,
  taxi_fee     numeric(18,3) not null default 0 check (taxi_fee >= 0),
  parking_fee  numeric(18,3) not null default 0 check (parking_fee >= 0),
  status       text not null default 'open' check (status in ('open','closed','cancelled'))
);
create index if not exists sales_visits_user on public.sales_visits (company_id, user_id, started_at desc);
create unique index if not exists sales_visits_one_open on public.sales_visits (company_id, user_id) where status = 'open';
alter table public.sales_visits enable row level security;
revoke insert, update, delete on public.sales_visits from authenticated;
grant select on public.sales_visits to authenticated;
drop policy if exists sv_select on public.sales_visits;
create policy sv_select on public.sales_visits for select to authenticated
  using ((user_id = auth.uid() and public.can(company_id, 'rep_visits', 'view')) or public.can(company_id, 'rep_visits', 'edit'));

alter table public.journal_entries add column if not exists visit_id uuid references public.sales_visits(id) on delete set null;
alter table public.cheques add column if not exists visit_id uuid references public.sales_visits(id) on delete set null;

create or replace function public.visit_start(p_company uuid, p_party uuid, p_lat numeric default null, p_lng numeric default null, p_purpose text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare vid uuid; rep uuid;
begin
  if not public.can(p_company, 'rep_visits', 'add') then raise exception 'ما عندك صلاحية تسجيل زيارات'; end if;
  if not exists (select 1 from public.parties where id = p_party and company_id = p_company and party_type = 'customer' and is_active) then raise exception 'العميل مش موجود'; end if;
  if exists (select 1 from public.sales_visits where company_id = p_company and user_id = auth.uid() and status = 'open') then
    raise exception 'عندك زيارة مفتوحة، أنهيها أول';
  end if;
  if p_lat is not null and (p_lat not between -90 and 90 or p_lng not between -180 and 180) then raise exception 'الموقع مش صحيح'; end if;
  select sales_rep_id into rep from public.parties where id = p_party;
  insert into public.sales_visits (company_id, party_id, rep_id, start_lat, start_lng, purpose)
  values (p_company, p_party, rep, p_lat, p_lng, nullif(trim(p_purpose), '')) returning id into vid;
  return vid;
end $$;

create or replace function public.visit_end(p_id uuid, p_lat numeric default null, p_lng numeric default null, p_notes text default null,
  p_outcome text default null, p_taxi numeric default 0, p_parking numeric default 0) returns void
language plpgsql security definer set search_path = public as $$
declare v public.sales_visits;
begin
  select * into v from public.sales_visits where id = p_id for update;
  if v.id is null then raise exception 'الزيارة مش موجودة'; end if;
  if not ((v.user_id = auth.uid() and public.can(v.company_id, 'rep_visits', 'add')) or public.can(v.company_id, 'rep_visits', 'edit')) then raise exception 'ما عندك صلاحية'; end if;
  if v.status <> 'open' then raise exception 'الزيارة منتهية'; end if;
  if coalesce(p_taxi, 0) < 0 or coalesce(p_parking, 0) < 0 or coalesce(p_taxi, 0) > 1000 or coalesce(p_parking, 0) > 1000 then raise exception 'المصاريف مش منطقية'; end if;
  if p_lat is not null and (p_lat not between -90 and 90 or p_lng not between -180 and 180) then raise exception 'الموقع مش صحيح'; end if;
  update public.sales_visits set ended_at = now(), end_lat = p_lat, end_lng = p_lng, notes = nullif(trim(p_notes), ''), outcome = nullif(trim(p_outcome), ''),
         taxi_fee = round(coalesce(p_taxi, 0), 3), parking_fee = round(coalesce(p_parking, 0), 3), status = 'closed' where id = p_id;
end $$;

create or replace function public.visit_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v public.sales_visits;
begin
  select * into v from public.sales_visits where id = p_id for update;
  if v.id is null then raise exception 'الزيارة مش موجودة'; end if;
  if not ((v.user_id = auth.uid() and public.can(v.company_id, 'rep_visits', 'add') and v.status = 'open') or public.can(v.company_id, 'rep_visits', 'edit')) then raise exception 'ما عندك صلاحية'; end if;
  update public.sales_visits set status = 'cancelled', ended_at = coalesce(ended_at, now()) where id = p_id;
end $$;

-- دفعة عميل من الجوال. p = {company_id, party_id, kind: cash|transfer|cheques, amount, account_id (للنقد/التحويل أو وسيلة الدفع), pay_date, reference, notes, visit_id,
--   cheques:[{cheque_no, amount, due_date, bank_name, drawer_name}]}
create or replace function public.mobile_payment(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := (p ->> 'company_id')::uuid; pa public.parties; k text := p ->> 'kind'; d date := coalesce(nullif(p ->> 'pay_date', '')::date, public.local_today());
  vid uuid := nullif(p ->> 'visit_id', '')::uuid; acc uuid := nullif(p ->> 'account_id', '')::uuid; amt numeric; fy uuid; eid uuid; c jsonb; chs uuid[] := '{}'; ch uuid; tot numeric := 0; posted boolean := false;
  prev text := current_setting('sumou.internal', true);
begin
  select * into pa from public.parties where id = nullif(p ->> 'party_id', '')::uuid and company_id = cid and party_type = 'customer';
  if pa.id is null then raise exception 'اختار العميل'; end if;
  if vid is not null and not exists (select 1 from public.sales_visits where id = vid and company_id = cid and party_id = pa.id and user_id = auth.uid()) then
    raise exception 'الزيارة مش لهالعميل';
  end if;
  if coalesce((select (pos ->> 'require_visit')::boolean from public.company_settings where company_id = cid), false)
     and not exists (select 1 from public.sales_visits where id = vid and status = 'open') and not public.can(cid, 'rep_visits', 'edit') then
    raise exception 'لازم تكون بزيارة مفتوحة لنفس العميل عشان تسجّل دفعة';
  end if;
  if k in ('cash', 'transfer') then
    if not public.can(cid, 'receipt_vouchers', 'add') then raise exception 'ما عندك صلاحية سندات القبض'; end if;
    amt := round(coalesce(nullif(p ->> 'amount', '')::numeric, 0), 3);
    if amt <= 0 then raise exception 'المبلغ لازم أكبر من صفر'; end if;
    if acc is null or not exists (select 1 from public.accounts where id = acc and company_id = cid and not is_group and account_type in ('cash', 'bank')) then
      raise exception 'اختار الصندوق أو البنك';
    end if;
    if pa.account_id is null then raise exception 'العميل ما إله حساب'; end if;
    select id into fy from public.fiscal_years where company_id = cid and d between start_date and end_date and not is_closed order by start_date desc limit 1;
    if fy is null then raise exception 'ما في سنة مالية مفتوحة بالتاريخ'; end if;
    insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, party_name, cash_account_id, status, visit_id)
    values (cid, fy, 'receipt', d, coalesce(nullif(trim(p ->> 'notes'), ''), 'دفعة من ' || pa.name) || case when k = 'transfer' then ' (تحويل)' else '' end,
            nullif(trim(p ->> 'reference'), ''), pa.name, acc, 'draft', vid) returning id into eid;
    insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, 1, acc, 'دفعة ' || pa.name, amt, 0);
    insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, party_id) values (eid, 2, pa.account_id, 'دفعة', 0, amt, pa.id);
    if public.can(cid, 'receipt_vouchers', 'post') then perform public.post_entry(eid); posted := true; end if;
    tot := amt;
  elsif k = 'cheques' then
    if coalesce(jsonb_typeof(p -> 'cheques'), '') <> 'array' or jsonb_array_length(p -> 'cheques') = 0 then raise exception 'أضف شيك واحد على الأقل'; end if;
    if jsonb_array_length(p -> 'cheques') > 50 then raise exception 'شيكات كثير'; end if;
    for c in select * from jsonb_array_elements(p -> 'cheques') loop
      if nullif(trim(c ->> 'cheque_no'), '') is null or nullif(c ->> 'due_date', '') is null then raise exception 'رقم الشيك وتاريخ الاستحقاق مطلوبين'; end if;
      ch := public.register_cheque(jsonb_build_object('company_id', cid, 'direction', 'in', 'party_id', pa.id, 'cheque_no', trim(c ->> 'cheque_no'), 'amount', c ->> 'amount',
              'due_date', c ->> 'due_date', 'issue_date', d, 'bank_name', c ->> 'bank_name', 'drawer_name', coalesce(nullif(c ->> 'drawer_name', ''), pa.name), 'notes', p ->> 'notes'));
      perform set_config('sumou.internal', public.internal_token(), true);
      update public.cheques set visit_id = vid where id = ch;
      perform set_config('sumou.internal', coalesce(prev, ''), true);
      chs := chs || ch; tot := tot + (c ->> 'amount')::numeric;
    end loop;
    posted := true;
  else raise exception 'نوع الدفعة مش صحيح'; end if;
  return jsonb_build_object('entry_id', eid, 'cheques', to_jsonb(chs), 'total', tot, 'posted', posted, 'party', pa.name, 'mobile', coalesce(pa.mobile, pa.phone));
end $$;

-- ملخص المشرف: زيارات الفترة لكل مستخدم
create or replace function public.visits_report(p_company uuid, p_from date, p_to date)
returns table (user_id uuid, visits bigint, open_visits bigint, minutes numeric, customers bigint, taxi numeric, parking numeric, payments numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'rep_visits', 'edit') then raise exception 'هالتقرير للمشرف'; end if;
  return query
  select v.user_id, count(*) filter (where v.status <> 'cancelled'), count(*) filter (where v.status = 'open'),
         round(coalesce(sum(extract(epoch from (coalesce(v.ended_at, now()) - v.started_at)) / 60) filter (where v.status = 'closed'), 0), 0),
         count(distinct v.party_id), sum(v.taxi_fee), sum(v.parking_fee),
         coalesce((select sum(e.total) from public.journal_entries e where e.visit_id = any(array_agg(v.id)) and e.status = 'posted'), 0)
         + coalesce((select sum(ch.amount) from public.cheques ch where ch.visit_id = any(array_agg(v.id)) and ch.status <> 'cancelled'), 0)
    from public.sales_visits v
   where v.company_id = p_company and v.started_at::date between p_from and p_to
   group by v.user_id;
end $$;

revoke execute on function public.visit_start(uuid, uuid, numeric, numeric, text), public.visit_end(uuid, numeric, numeric, text, text, numeric, numeric),
  public.visit_cancel(uuid), public.mobile_payment(jsonb), public.visits_report(uuid, date, date) from public, anon;
grant execute on function public.visit_start(uuid, uuid, numeric, numeric, text), public.visit_end(uuid, numeric, numeric, text, text, numeric, numeric),
  public.visit_cancel(uuid), public.mobile_payment(jsonb), public.visits_report(uuid, date, date) to authenticated;

-- النسخ الاحتياطي: الزيارات بعد العملاء وقبل القيود والشيكات
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
   (39, 'employees', 'company_id = $1', 'code'),
   (40, 'payroll_runs', 'company_id = $1', 'period'),
   (41, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (42, 'asset_custodians', 'company_id = $1', 'code'),
   (43, 'fixed_assets', 'company_id = $1', 'code'),
   (44, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (45, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (46, 'asset_movements', 'company_id = $1', 'mov_no'),
   (47, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (48, 'custody_docs', 'company_id = $1', 'doc_no'),
   (49, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (50, 'bank_recons', 'company_id = $1', 'created_at'),
   (51, 'bank_cleared', 'company_id = $1', 'line_id'),
   (52, 'attachments', 'company_id = $1', 'created_at'),
   (53, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;

-- ---------------------------------------------------------------------
--  ترقيم الشركات (لكل مشترك): تلقائي 01، 02… أو يدوي، بدون تكرار
-- ---------------------------------------------------------------------
alter table public.tenants add column if not exists settings jsonb not null default '{}'::jsonb;

create or replace function public.company_numbering() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('mode', coalesce(t.settings #>> '{company_code,mode}', 'auto'), 'digits', coalesce((t.settings #>> '{company_code,digits}')::int, 2))
    from public.tenants t where t.id = public.my_tenant();
$$;

create or replace function public.set_company_numbering(p_mode text, p_digits int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'ترقيم الشركات لمدير النظام بس'; end if;
  if p_mode not in ('auto', 'manual') or coalesce(p_digits, 0) not between 1 and 6 then raise exception 'إعداد مش صحيح'; end if;
  update public.tenants set settings = jsonb_set(coalesce(settings, '{}'::jsonb), '{company_code}', jsonb_build_object('mode', p_mode, 'digits', p_digits))
   where id = public.my_tenant();
end $$;

create or replace function public.ab_company_code() returns trigger
language plpgsql security definer set search_path = public as $$
declare cfg jsonb; mx bigint;
begin
  if public.is_internal() then return new; end if;
  select coalesce(settings -> 'company_code', '{}'::jsonb) into cfg from public.tenants where id = new.tenant_id;
  if coalesce(cfg ->> 'mode', 'auto') = 'auto' then
    if tg_op = 'UPDATE' then
      if new.code is distinct from old.code then raise exception 'رمز الشركة تلقائي، ما بيتعدّل (غيّر طريقة الترقيم ليدوي أول)'; end if;
      return new;
    end if;
    perform pg_advisory_xact_lock(hashtext('cocode:' || coalesce(new.tenant_id::text, '')));
    select coalesce(max(code::bigint), 0) into mx from public.companies where tenant_id is not distinct from new.tenant_id and code ~ '^\d{1,15}$';
    new.code := lpad((mx + 1)::text, greatest(coalesce((cfg ->> 'digits')::int, 2), 1), '0');
  else
    new.code := nullif(trim(new.code), '');
    if new.code is null then raise exception 'رمز الشركة مطلوب (الترقيم يدوي)'; end if;
    if exists (select 1 from public.companies where tenant_id is not distinct from new.tenant_id and code = new.code and id <> new.id) then
      raise exception 'رمز الشركة «%» مستخدم', new.code;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists ab_company_code on public.companies;
create trigger ab_company_code before insert or update of code on public.companies for each row execute function public.ab_company_code();

revoke execute on function public.set_company_numbering(text, int) from public, anon;
grant execute on function public.company_numbering(), public.set_company_numbering(text, int) to authenticated;
