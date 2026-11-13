-- =====================================================================
--  السمو ERP — المرحلة 34: عهد الأصول الثابتة
--  أصحاب العهد + مستندات تسليم/نقل/إرجاع بحالات (في الانتظار ← مثبت ← انتهاء العمل ← مغلق).
--  «انتهاء العمل» بيطبّق على الأصول (صاحب العهدة والموقع). ما في قيد محاسبي.
--  الصلاحية: شاشة asset_custody (قسم الأصول).
-- =====================================================================
create or replace function public.screen_module(s text) returns text
language sql immutable as $$
  select case
    when s in ('customers','sales_invoices','sales_orders','pos')   then 'sales'
    when s in ('suppliers','purchase_invoices','purchase_orders')   then 'purchases'
    when s = 'inventory'                                            then 'inventory'
    when s in ('cheques','bank_recon')                              then 'banking'
    when s = 'payroll'                                              then 'payroll'
    when s in ('fixed_assets','asset_custody')                      then 'assets'
    when s = 'marketing'                                            then 'marketing'
    when s = 'manufacturing'                                        then 'manufacturing'
    when s = 'maintenance'                                          then 'maintenance'
    when s = 'obligations'                                          then 'office'
    else 'core' end;
$$;

create table if not exists public.asset_custodians (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  code        text not null,
  name        text not null,
  employee_id uuid references public.employees(id) on delete set null,
  phone       text,
  notes       text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (company_id, code)
);
alter table public.asset_custodians enable row level security;
grant select, insert, update, delete on public.asset_custodians to authenticated;
drop policy if exists acu_select on public.asset_custodians;
create policy acu_select on public.asset_custodians for select to authenticated
  using (public.can(company_id, 'asset_custody', 'view') or public.can(company_id, 'fixed_assets', 'view'));
drop policy if exists acu_insert on public.asset_custodians;
create policy acu_insert on public.asset_custodians for insert to authenticated with check (public.can(company_id, 'asset_custody', 'add'));
drop policy if exists acu_update on public.asset_custodians;
create policy acu_update on public.asset_custodians for update to authenticated using (public.can(company_id, 'asset_custody', 'edit')) with check (public.can(company_id, 'asset_custody', 'edit'));
drop policy if exists acu_delete on public.asset_custodians;
create policy acu_delete on public.asset_custodians for delete to authenticated using (public.can(company_id, 'asset_custody', 'delete'));

create or replace function public.ad_custodian_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.company_id <> old.company_id then raise exception 'ما بتقدر تغيّر شركة صاحب العهدة'; end if;
  if nullif(trim(new.code), '') is null or nullif(trim(new.name), '') is null then raise exception 'رمز صاحب العهدة واسمه مطلوبين'; end if;
  if new.employee_id is not null and not exists (select 1 from public.employees where id = new.employee_id and company_id = new.company_id) then
    raise exception 'الموظف مش من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists ad_custodian_check on public.asset_custodians;
create trigger ad_custodian_check before insert or update on public.asset_custodians for each row execute function public.ad_custodian_check();

alter table public.fixed_assets add column if not exists custodian_id uuid references public.asset_custodians(id) on delete set null;
alter table public.fixed_assets add column if not exists custody_since date;

create table if not exists public.custody_docs (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  doc_no        int not null,
  kind          text not null check (kind in ('handover','transfer','return')),
  doc_date      date not null,
  status        text not null default 'pending' check (status in ('pending','confirmed','done','closed','cancelled')),
  from_custodian_id uuid references public.asset_custodians(id),
  to_custodian_id   uuid references public.asset_custodians(id),
  location      text,
  department_id uuid references public.departments(id) on delete set null,
  reference     text,
  notes         text,
  done_at       timestamptz,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  unique (company_id, doc_no)
);
create table if not exists public.custody_doc_lines (
  id            uuid primary key default gen_random_uuid(),
  doc_id        uuid not null references public.custody_docs(id) on delete cascade,
  line_no       int not null,
  asset_id      uuid not null references public.fixed_assets(id),
  condition     text,
  accessories   text,
  notes         text,
  prev_custodian_id uuid,
  prev_location text,
  prev_since    date,
  unique (doc_id, asset_id)
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'custody_doc_lines_prev_custodian_fk') then
    alter table public.custody_doc_lines add constraint custody_doc_lines_prev_custodian_fk foreign key (prev_custodian_id) references public.asset_custodians(id) on delete set null;
  end if;
end $$;
create index if not exists custody_lines_asset on public.custody_doc_lines (asset_id);
alter table public.custody_docs enable row level security;
alter table public.custody_doc_lines enable row level security;
drop policy if exists cd_select on public.custody_docs;
create policy cd_select on public.custody_docs for select to authenticated using (public.can(company_id, 'asset_custody', 'view'));
drop policy if exists cdl_select on public.custody_doc_lines;
create policy cdl_select on public.custody_doc_lines for select to authenticated
  using (exists (select 1 from public.custody_docs d where d.id = doc_id and public.can(d.company_id, 'asset_custody', 'view')));
revoke insert, update, delete on public.custody_docs, public.custody_doc_lines from authenticated;
grant select on public.custody_docs, public.custody_doc_lines to authenticated;

-- صاحب العهدة على بطاقة الأصل ما بينكتب يدوي: من المستندات بس
create or replace function public.ab_asset_custody_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then return new; end if;
  if tg_op = 'INSERT' then
    if new.custodian_id is not null then raise exception 'صاحب العهدة بيتسجّل بمستند «تسليم عهدة»'; end if;
    new.custody_since := null;
  elsif new.custodian_id is distinct from old.custodian_id or new.custody_since is distinct from old.custody_since then
    raise exception 'صاحب العهدة بيتغيّر بمستندات عهد الأصول بس';
  end if;
  return new;
end $$;
drop trigger if exists ab_asset_custody_guard on public.fixed_assets;
create trigger ab_asset_custody_guard before insert or update on public.fixed_assets for each row execute function public.ab_asset_custody_guard();

-- حفظ (جديد أو تعديل وهو «في الانتظار»)
-- p = {id?, company_id, kind, doc_date, from_custodian_id, to_custodian_id, location, department_id, reference, notes, lines:[{asset_id, condition, accessories, notes}]}
create or replace function public.custody_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid := (p ->> 'company_id')::uuid; did uuid := nullif(p ->> 'id', '')::uuid; d public.custody_docs; k text := p ->> 'kind';
  fc uuid := nullif(p ->> 'from_custodian_id', '')::uuid; tc uuid := nullif(p ->> 'to_custodian_id', '')::uuid; dep uuid := nullif(p ->> 'department_id', '')::uuid;
  l jsonb; a public.fixed_assets; n int := 0;
begin
  if did is not null then
    select * into d from public.custody_docs where id = did for update;
    if d.id is null then raise exception 'المستند مش موجود'; end if;
    cid := d.company_id; k := d.kind;
    if not public.can(cid, 'asset_custody', 'edit') then raise exception 'ما عندك صلاحية تعديل مستندات العهد'; end if;
    if d.status <> 'pending' then raise exception 'المستند مش «في الانتظار»، رجّعه للانتظار أول عشان تعدّله'; end if;
  elsif not public.can(cid, 'asset_custody', 'add') then raise exception 'ما عندك صلاحية إضافة مستندات العهد';
  end if;
  if k not in ('handover', 'transfer', 'return') then raise exception 'نوع الحركة مش صحيح'; end if;
  if nullif(p ->> 'doc_date', '') is null then raise exception 'اكتب التاريخ'; end if;
  if k = 'handover' then fc := null; end if;
  if k = 'return' then tc := null; end if;
  if k in ('transfer', 'return') and fc is null then raise exception 'حدّد صاحب العهدة المسلِّم'; end if;
  if k in ('handover', 'transfer') and tc is null then raise exception 'حدّد صاحب العهدة المستلِم'; end if;
  if fc is not null and fc is not distinct from tc then raise exception 'المسلِّم والمستلِم لازم يختلفوا'; end if;
  if (fc is not null and not exists (select 1 from public.asset_custodians where id = fc and company_id = cid))
     or (tc is not null and not exists (select 1 from public.asset_custodians where id = tc and company_id = cid and is_active)) then
    raise exception 'صاحب العهدة مش من نفس الشركة أو موقوف';
  end if;
  if dep is not null and not exists (select 1 from public.departments where id = dep and company_id = cid) then raise exception 'الدائرة مش من نفس الشركة'; end if;
  if coalesce(jsonb_typeof(p -> 'lines'), '') <> 'array' or jsonb_array_length(p -> 'lines') = 0 then raise exception 'أضف أصل واحد على الأقل'; end if;

  if did is null then
    insert into public.custody_docs (company_id, doc_no, kind, doc_date, from_custodian_id, to_custodian_id, location, department_id, reference, notes)
    values (cid, coalesce((select max(doc_no) from public.custody_docs where company_id = cid), 0) + 1, k, (p ->> 'doc_date')::date, fc, tc,
            nullif(trim(p ->> 'location'), ''), dep, nullif(trim(p ->> 'reference'), ''), nullif(trim(p ->> 'notes'), ''))
    returning id into did;
  else
    update public.custody_docs set doc_date = (p ->> 'doc_date')::date, from_custodian_id = fc, to_custodian_id = tc, location = nullif(trim(p ->> 'location'), ''),
           department_id = dep, reference = nullif(trim(p ->> 'reference'), ''), notes = nullif(trim(p ->> 'notes'), '') where id = did;
    delete from public.custody_doc_lines where doc_id = did;
  end if;
  for l in select * from jsonb_array_elements(p -> 'lines') loop
    n := n + 1;
    select * into a from public.fixed_assets where id = (l ->> 'asset_id')::uuid;
    if a.id is null or a.company_id <> cid then raise exception 'أصل مش موجود (سطر %)', n; end if;
    if a.status <> 'active' then raise exception 'الأصل «%» مستبعد', a.name; end if;
    if k = 'handover' and a.custodian_id is not null then raise exception 'الأصل «%» بعهدة حدا، استعمل «نقل»', a.name; end if;
    if k in ('transfer', 'return') and a.custodian_id is distinct from fc then raise exception 'الأصل «%» مش بعهدة المسلِّم', a.name; end if;
    if exists (select 1 from public.custody_doc_lines x join public.custody_docs y on y.id = x.doc_id
               where x.asset_id = a.id and y.id <> did and y.status in ('pending', 'confirmed')) then
      raise exception 'الأصل «%» بمستند عهدة ثاني لسا ما انتهى', a.name;
    end if;
    insert into public.custody_doc_lines (doc_id, line_no, asset_id, condition, accessories, notes)
    values (did, n, a.id, nullif(trim(l ->> 'condition'), ''), nullif(trim(l ->> 'accessories'), ''), nullif(trim(l ->> 'notes'), ''));
  end loop;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), cid, case when p ? 'id' and nullif(p ->> 'id', '') is not null then 'تعديل' else 'إضافة' end, 'custody_docs', did::text, jsonb_build_object('kind', k, 'lines', n));
  return did;
end $$;

-- تغيير الحالة. done = تطبيق على الأصول، والرجوع منها بيرجّع الأصول (إذا ما في مستند أحدث)
create or replace function public.custody_set_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare d public.custody_docs; r record; prev text := current_setting('sumou.internal', true);
begin
  select * into d from public.custody_docs where id = p_id for update;
  if d.id is null then raise exception 'المستند مش موجود'; end if;
  if p_status not in ('pending', 'confirmed', 'done', 'closed', 'cancelled') then raise exception 'حالة مش صحيحة'; end if;
  if p_status = d.status then return; end if;
  if not public.can(d.company_id, 'asset_custody', case when p_status in ('done', 'closed') or d.status in ('done', 'closed') then 'post' else 'edit' end) then
    raise exception 'ما عندك صلاحية تغيير حالة المستند';
  end if;
  if d.status = 'cancelled' then raise exception 'المستند ملغى'; end if;
  if d.status = 'closed' then raise exception 'المستند مغلق (أرشيف)'; end if;
  if p_status = 'closed' and d.status <> 'done' then raise exception 'بس المستند المنتهي بيتسكّر'; end if;
  if p_status = 'cancelled' and d.status = 'done' then raise exception 'رجّع المستند للانتظار أول'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);

  if p_status = 'done' then
    if not exists (select 1 from public.custody_doc_lines where doc_id = p_id) then raise exception 'ما في أصول بالمستند'; end if;
    for r in select l.id lid, a.* from public.custody_doc_lines l join public.fixed_assets a on a.id = l.asset_id where l.doc_id = p_id order by l.line_no for update of a loop
      if r.status <> 'active' then raise exception 'الأصل «%» مستبعد', r.name; end if;
      if d.kind = 'handover' and r.custodian_id is not null then raise exception 'الأصل «%» بعهدة حدا، استعمل «نقل»', r.name; end if;
      if d.kind in ('transfer', 'return') and r.custodian_id is distinct from d.from_custodian_id then raise exception 'الأصل «%» مش بعهدة المسلِّم', r.name; end if;
      if exists (select 1 from public.custody_doc_lines x join public.custody_docs y on y.id = x.doc_id
                 where x.asset_id = r.id and y.id <> p_id and y.status in ('done', 'closed') and y.doc_date > d.doc_date) then
        raise exception 'الأصل «%» عليه مستند عهدة بتاريخ أحدث', r.name;
      end if;
      update public.custody_doc_lines set prev_custodian_id = r.custodian_id, prev_location = r.location, prev_since = r.custody_since where id = r.lid;
      update public.fixed_assets set custodian_id = d.to_custodian_id,
             custody_since = case when d.to_custodian_id is null then null else d.doc_date end,
             location = coalesce(d.location, location)
       where id = r.id;
    end loop;
    update public.custody_docs set status = 'done', done_at = now() where id = p_id;
  elsif d.status = 'done' and p_status <> 'closed' then   -- رجوع من «انتهاء العمل»
    for r in select l.*, a.name, a.custodian_id cur, a.status astatus, a.location aloc from public.custody_doc_lines l join public.fixed_assets a on a.id = l.asset_id where l.doc_id = p_id for update of a loop
      if r.astatus <> 'active' then raise exception 'الأصل «%» مستبعد، ما بينرجع عن عهدته', r.name; end if;
      if exists (select 1 from public.custody_doc_lines x join public.custody_docs y on y.id = x.doc_id
                 where x.asset_id = r.asset_id and y.id <> p_id and y.status in ('done', 'closed') and y.done_at > d.done_at) then
        raise exception 'على الأصل «%» حركة عهدة لاحقة، ارجع عنها أول', r.name;
      end if;
      update public.fixed_assets set custodian_id = r.prev_custodian_id, custody_since = r.prev_since,
             location = case when d.location is not null and r.aloc is not distinct from d.location then r.prev_location else r.aloc end
       where id = r.asset_id;
    end loop;
    update public.custody_docs set status = p_status, done_at = null where id = p_id;
    update public.custody_doc_lines set prev_custodian_id = null, prev_location = null, prev_since = null where doc_id = p_id;
  else
    update public.custody_docs set status = p_status where id = p_id;
  end if;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), d.company_id, case when p_status in ('done', 'closed') then 'ترحيل' else 'تعديل' end, 'custody_docs', p_id::text,
          jsonb_build_object('no', d.doc_no, 'from', d.status, 'to', p_status));
end $$;

create or replace function public.custody_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d public.custody_docs;
begin
  select * into d from public.custody_docs where id = p_id;
  if d.id is null then return; end if;
  if not public.can(d.company_id, 'asset_custody', 'delete') then raise exception 'ما عندك صلاحية'; end if;
  if d.status not in ('pending', 'cancelled') then raise exception 'بس المستند «في الانتظار» أو الملغى بينحذف'; end if;
  delete from public.custody_docs where id = p_id;
end $$;

-- سجل عهدة أصل (المستندات المنتهية والمغلقة)
create or replace function public.custody_history(p_asset uuid)
returns table (doc_id uuid, doc_no int, kind text, doc_date date, status text, from_name text, to_name text, location text, condition text, accessories text, ended date)
language sql stable security definer set search_path = public as $$
  with h as (
    select d.id, d.doc_no, d.kind, d.doc_date, d.status, f.name fn, t.name tn, d.location, l.condition, l.accessories, d.done_at
      from public.custody_doc_lines l join public.custody_docs d on d.id = l.doc_id
      left join public.asset_custodians f on f.id = d.from_custodian_id left join public.asset_custodians t on t.id = d.to_custodian_id
     where l.asset_id = p_asset and d.status in ('done', 'closed')
       and (public.can(d.company_id, 'asset_custody', 'view') or public.can(d.company_id, 'fixed_assets', 'view')))
  select id, doc_no, kind, doc_date, status, fn, tn, location, condition, accessories, lead(doc_date) over (order by doc_date, done_at) from h order by doc_date desc, done_at desc;
$$;

revoke execute on function public.custody_save(jsonb), public.custody_set_status(uuid, text), public.custody_delete(uuid), public.custody_history(uuid) from public, anon;
grant execute on function public.custody_save(jsonb), public.custody_set_status(uuid, text), public.custody_delete(uuid), public.custody_history(uuid) to authenticated;

-- النسخ الاحتياطي: أصحاب العهد قبل الأصول، والمستندات بعدها
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1,  'companies',          'id = $1', 'code'),
   (2,  'fiscal_years',       'company_id = $1', 'start_date'),
   (3,  'accounts',           'company_id = $1', 'level, code'),
   (4,  'cost_centers',       'company_id = $1', 'code'),
   (5,  'currencies',         'company_id = $1', 'code'),
   (6,  'company_settings',   'company_id = $1', 'company_id'),
   (7,  'lookups',            'company_id = $1', 'parent_id nulls first, kind, code'),
   (8,  'custom_fields',      'company_id = $1', 'entity, sort'),
   (9,  'party_categories',   'company_id = $1', 'party_type, code'),
   (10, 'parties',            'company_id = $1', 'code'),
   (11, 'item_categories',    'company_id = $1', 'code'),
   (12, 'items',              'company_id = $1', 'code'),
   (13, 'promotions',         'company_id = $1', 'date_from'),
   (14, 'warehouses',         'company_id = $1', 'code'),
   (15, 'departments',        'company_id = $1', 'level, code'),
   (16, 'boms',               'company_id = $1', 'code'),
   (17, 'bom_lines',          'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (18, 'journal_entries',    'company_id = $1', 'created_at'),
   (19, 'journal_lines',      'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (20, 'invoices',           'company_id = $1', 'created_at'),
   (21, 'invoice_lines',      'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (22, 'orders',             'company_id = $1', 'created_at'),
   (23, 'order_lines',        'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (24, 'service_tickets',    'company_id = $1', 'ticket_no'),
   (25, 'cheques',            'company_id = $1', 'created_at'),
   (26, 'cheque_events',      'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (27, 'stock_docs',         'company_id = $1', 'created_at'),
   (28, 'stock_doc_lines',    'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (29, 'stock_moves',        'company_id = $1', 'created_at'),
   (30, 'productions',        'company_id = $1', 'prod_no'),
   (31, 'obligations',        'company_id = $1', 'due_date'),
   (32, 'recurring_entries',  'company_id = $1', 'created_at'),
   (33, 'employees',          'company_id = $1', 'code'),
   (34, 'payroll_runs',       'company_id = $1', 'period'),
   (35, 'payroll_lines',      'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (36, 'asset_custodians',   'company_id = $1', 'code'),
   (37, 'fixed_assets',       'company_id = $1', 'code'),
   (38, 'depreciation_runs',  'company_id = $1', 'created_at'),
   (39, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (40, 'asset_movements',    'company_id = $1', 'mov_no'),
   (41, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (42, 'custody_docs',       'company_id = $1', 'doc_no'),
   (43, 'custody_doc_lines',  'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (44, 'bank_recons',        'company_id = $1', 'created_at'),
   (45, 'bank_cleared',       'company_id = $1', 'line_id'),
   (46, 'attachments',        'company_id = $1', 'created_at'),
   (47, 'fiscal_periods',     'company_id = $1', 'start_date');
$$;
