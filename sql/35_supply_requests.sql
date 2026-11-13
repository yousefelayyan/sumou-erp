-- =====================================================================
--  السمو ERP — المرحلة 35: طلبات التزويد بين المستودعات
--  حد أدنى/أعلى لكل صنف بكل مستودع، طلب (في الانتظار ← مثبت)، إصدار سند إخراج من المستودع المصدر،
--  وبعد ترحيله إصدار سند إدخال للمستودع الوجهة بنفس الكلفة. الشاشة supply_requests (قسم المخزون).
-- =====================================================================
create or replace function public.screen_module(s text) returns text
language sql immutable as $$
  select case
    when s in ('customers','sales_invoices','sales_orders','pos')   then 'sales'
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

-- حدود الصنف بالمستودع
create table if not exists public.item_wh_limits (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  item_id      uuid not null references public.items(id) on delete cascade,
  warehouse_id uuid not null references public.warehouses(id) on delete cascade,
  min_qty      numeric(18,3) not null default 0 check (min_qty >= 0),
  max_qty      numeric(18,3) check (max_qty is null or max_qty >= 0),
  unique (item_id, warehouse_id),
  check (max_qty is null or max_qty >= min_qty)
);
alter table public.item_wh_limits enable row level security;
grant select, insert, update, delete on public.item_wh_limits to authenticated;
drop policy if exists iwl_select on public.item_wh_limits;
create policy iwl_select on public.item_wh_limits for select to authenticated
  using (public.can(company_id, 'inventory', 'view') or public.can(company_id, 'supply_requests', 'view'));
drop policy if exists iwl_write on public.item_wh_limits;
create policy iwl_write on public.item_wh_limits for all to authenticated
  using (public.can(company_id, 'inventory', 'edit')) with check (public.can(company_id, 'inventory', 'edit'));
create or replace function public.ad_iwl_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.items where id = new.item_id and company_id = new.company_id)
     or not exists (select 1 from public.warehouses where id = new.warehouse_id and company_id = new.company_id) then
    raise exception 'الصنف أو المستودع مش من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists ad_iwl_check on public.item_wh_limits;
create trigger ad_iwl_check before insert or update on public.item_wh_limits for each row execute function public.ad_iwl_check();

create table if not exists public.supply_requests (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  req_no        int not null,
  req_date      date not null,
  from_warehouse_id uuid not null references public.warehouses(id),
  to_warehouse_id   uuid not null references public.warehouses(id),
  status        text not null default 'pending' check (status in ('pending','confirmed','rejected','cancelled')),
  reference     text,
  notes         text,
  out_doc_id    uuid references public.stock_docs(id) on delete set null,
  in_doc_id     uuid references public.stock_docs(id) on delete set null,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  unique (company_id, req_no),
  check (from_warehouse_id <> to_warehouse_id)
);
create table if not exists public.supply_request_lines (
  id          uuid primary key default gen_random_uuid(),
  request_id  uuid not null references public.supply_requests(id) on delete cascade,
  line_no     int not null,
  item_id     uuid not null references public.items(id),
  qty         numeric(18,3) not null check (qty > 0),
  note        text,
  unique (request_id, item_id)
);
alter table public.supply_requests enable row level security;
alter table public.supply_request_lines enable row level security;
drop policy if exists sr_select on public.supply_requests;
create policy sr_select on public.supply_requests for select to authenticated
  using (public.can(company_id, 'supply_requests', 'view') or public.can(company_id, 'inventory', 'view'));
drop policy if exists srl_select on public.supply_request_lines;
create policy srl_select on public.supply_request_lines for select to authenticated
  using (exists (select 1 from public.supply_requests r where r.id = request_id
                 and (public.can(r.company_id, 'supply_requests', 'view') or public.can(r.company_id, 'inventory', 'view'))));
revoke insert, update, delete on public.supply_requests, public.supply_request_lines from authenticated;
grant select on public.supply_requests, public.supply_request_lines to authenticated;

alter table public.stock_docs add column if not exists supply_request_id uuid references public.supply_requests(id) on delete set null;

-- سند الإدخال الناتج من طلب تزويد: أصنافه وكلفته من سند الإخراج، ما بتتعدّل
create or replace function public.ab_supply_in_lines_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare did uuid := coalesce(new.doc_id, old.doc_id);
begin
  if public.is_internal() then return coalesce(new, old); end if;
  if exists (select 1 from public.stock_docs where id = did and supply_request_id is not null and doc_type = 'in') then
    raise exception 'سطور سند الإدخال لطلب التزويد ما بتتعدّل (بتيجي من سند الإخراج)';
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists ab_supply_in_lines_guard on public.stock_doc_lines;
create trigger ab_supply_in_lines_guard before insert or update on public.stock_doc_lines
  for each row execute function public.ab_supply_in_lines_guard();

create or replace function public.ab_supply_doc_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then return new; end if;
  if tg_op = 'INSERT' then new.supply_request_id := null; return new; end if;
  new.supply_request_id := old.supply_request_id;
  if old.supply_request_id is not null and (new.warehouse_id <> old.warehouse_id or new.doc_type <> old.doc_type) then
    raise exception 'مستودع سند طلب التزويد ما بيتغيّر';
  end if;
  return new;
end $$;
drop trigger if exists ab_supply_doc_guard on public.stock_docs;
create trigger ab_supply_doc_guard before insert or update on public.stock_docs for each row execute function public.ab_supply_doc_guard();

-- حفظ الطلب (جديد أو «في الانتظار»): p = {id?, company_id, req_date, from_warehouse_id, to_warehouse_id, reference, notes, lines:[{item_id, qty, note}]}
create or replace function public.supply_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid := (p ->> 'company_id')::uuid; rid uuid := nullif(p ->> 'id', '')::uuid; r public.supply_requests;
  fw uuid := nullif(p ->> 'from_warehouse_id', '')::uuid; tw uuid := nullif(p ->> 'to_warehouse_id', '')::uuid; l jsonb; it public.items; n int := 0; q numeric;
begin
  if rid is not null then
    select * into r from public.supply_requests where id = rid for update;
    if r.id is null then raise exception 'الطلب مش موجود'; end if;
    cid := r.company_id;
    if not public.can(cid, 'supply_requests', 'edit') then raise exception 'ما عندك صلاحية تعديل طلبات التزويد'; end if;
    if r.status <> 'pending' or r.out_doc_id is not null then raise exception 'الطلب مثبت أو انصدر إله سند، ما بيتعدّل'; end if;
  elsif not public.can(cid, 'supply_requests', 'add') then raise exception 'ما عندك صلاحية إضافة طلبات التزويد';
  end if;
  if nullif(p ->> 'req_date', '') is null then raise exception 'اكتب التاريخ'; end if;
  if fw is null or tw is null or fw = tw then raise exception 'اختار مستودع المصدر والوجهة (مختلفين)'; end if;
  if not exists (select 1 from public.warehouses where id = fw and company_id = cid and is_active)
     or not exists (select 1 from public.warehouses where id = tw and company_id = cid and is_active) then
    raise exception 'المستودع مش من نفس الشركة أو موقوف';
  end if;
  if coalesce(jsonb_typeof(p -> 'lines'), '') <> 'array' or jsonb_array_length(p -> 'lines') = 0 then raise exception 'أضف صنف واحد على الأقل'; end if;
  if jsonb_array_length(p -> 'lines') > 500 then raise exception 'الطلب كبير كثير'; end if;
  if rid is null then
    insert into public.supply_requests (company_id, req_no, req_date, from_warehouse_id, to_warehouse_id, reference, notes)
    values (cid, coalesce((select max(req_no) from public.supply_requests where company_id = cid), 0) + 1, (p ->> 'req_date')::date, fw, tw,
            nullif(trim(p ->> 'reference'), ''), nullif(trim(p ->> 'notes'), '')) returning id into rid;
  else
    update public.supply_requests set req_date = (p ->> 'req_date')::date, from_warehouse_id = fw, to_warehouse_id = tw,
           reference = nullif(trim(p ->> 'reference'), ''), notes = nullif(trim(p ->> 'notes'), '') where id = rid;
    delete from public.supply_request_lines where request_id = rid;
  end if;
  for l in select * from jsonb_array_elements(p -> 'lines') loop
    n := n + 1;
    select * into it from public.items where id = (l ->> 'item_id')::uuid;
    if it.id is null or it.company_id <> cid then raise exception 'صنف مش موجود (سطر %)', n; end if;
    if it.item_type <> 'goods' or not it.track_stock then raise exception 'الصنف «%» ما إله مخزون', it.name; end if;
    q := round(coalesce(nullif(l ->> 'qty', '')::numeric, 0), 3);
    if q <= 0 then raise exception 'الكمية للصنف «%» لازم أكبر من صفر', it.name; end if;
    if exists (select 1 from public.supply_request_lines where request_id = rid and item_id = it.id) then raise exception 'الصنف «%» مكرر', it.name; end if;
    insert into public.supply_request_lines (request_id, line_no, item_id, qty, note) values (rid, n, it.id, q, nullif(trim(l ->> 'note'), ''));
  end loop;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), cid, case when nullif(p ->> 'id', '') is not null then 'تعديل' else 'إضافة' end, 'supply_requests', rid::text, jsonb_build_object('lines', n));
  return rid;
end $$;

-- الحالة: pending / confirmed / rejected / cancelled
create or replace function public.supply_set_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.supply_requests;
begin
  select * into r from public.supply_requests where id = p_id for update;
  if r.id is null then raise exception 'الطلب مش موجود'; end if;
  if p_status not in ('pending', 'confirmed', 'rejected', 'cancelled') then raise exception 'حالة مش صحيحة'; end if;
  if not public.can(r.company_id, 'supply_requests', case when p_status in ('confirmed', 'rejected') or r.status = 'confirmed' then 'post' else 'edit' end) then
    raise exception 'ما عندك صلاحية تغيير حالة الطلب';
  end if;
  if r.out_doc_id is not null then raise exception 'انصدر للطلب سند إخراج؛ احذف السند (إذا مش مرحّل) أول'; end if;
  if r.status in ('rejected', 'cancelled') and p_status <> 'pending' then raise exception 'الطلب مرفوض أو ملغى'; end if;
  update public.supply_requests set status = p_status where id = p_id;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), r.company_id, case when p_status = 'confirmed' then 'ترحيل' else 'تعديل' end, 'supply_requests', p_id::text, jsonb_build_object('no', r.req_no, 'from', r.status, 'to', p_status));
end $$;

-- إصدار سند الإخراج (مسودة) من مستودع المصدر
create or replace function public.supply_issue_out(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare r public.supply_requests; did uuid; prev text := current_setting('sumou.internal', true);
begin
  select * into r from public.supply_requests where id = p_id for update;
  if r.id is null then raise exception 'الطلب مش موجود'; end if;
  if not (public.can(r.company_id, 'inventory', 'add') and (public.can(r.company_id, 'supply_requests', 'view') or public.can(r.company_id, 'inventory', 'view'))) then
    raise exception 'ما عندك صلاحية إصدار سندات المخزون';
  end if;
  if r.status <> 'confirmed' then raise exception 'ثبّت الطلب أول'; end if;
  if r.out_doc_id is not null then raise exception 'انصدر سند الإخراج من قبل'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.stock_docs (company_id, doc_type, doc_date, warehouse_id, notes, supply_request_id)
  values (r.company_id, 'out', greatest(r.req_date, public.local_today()), r.from_warehouse_id, 'طلب تزويد ' || r.req_no || coalesce(' — ' || r.reference, ''), r.id)
  returning id into did;
  insert into public.stock_doc_lines (doc_id, line_no, item_id, qty, note)
  select did, line_no, item_id, qty, note from public.supply_request_lines where request_id = p_id order by line_no;
  update public.supply_requests set out_doc_id = did where id = p_id;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), r.company_id, 'إضافة', 'supply_requests', p_id::text, jsonb_build_object('no', r.req_no, 'out_doc', did));
  return did;
end $$;

-- إصدار سند الإدخال (مسودة) للمستودع الوجهة: بعد ترحيل الإخراج، بالكميات والكلفة الفعلية
create or replace function public.supply_issue_in(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare r public.supply_requests; o public.stock_docs; did uuid; prev text := current_setting('sumou.internal', true);
begin
  select * into r from public.supply_requests where id = p_id for update;
  if r.id is null then raise exception 'الطلب مش موجود'; end if;
  if not (public.can(r.company_id, 'inventory', 'add') and (public.can(r.company_id, 'supply_requests', 'view') or public.can(r.company_id, 'inventory', 'view'))) then
    raise exception 'ما عندك صلاحية إصدار سندات المخزون';
  end if;
  if r.in_doc_id is not null then raise exception 'انصدر سند الإدخال من قبل'; end if;
  select * into o from public.stock_docs where id = r.out_doc_id;
  if o.id is null then raise exception 'اصدر سند الإخراج أول'; end if;
  if o.status <> 'posted' then raise exception 'سند الإخراج لسا ما ترحّل للمخزون'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.stock_docs (company_id, doc_type, doc_date, warehouse_id, notes, supply_request_id)
  values (r.company_id, 'in', greatest(o.doc_date, public.local_today()), r.to_warehouse_id, 'استلام طلب تزويد ' || r.req_no, r.id) returning id into did;
  insert into public.stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost, note)
  select did, row_number() over (order by min(m.created_at)), m.item_id, -sum(m.qty), round(sum(m.qty * m.unit_cost) / nullif(sum(m.qty), 0), 3), null
    from public.stock_moves m where m.source_type = 'stock_doc' and m.source_id = o.id group by m.item_id having sum(m.qty) < 0;
  update public.supply_requests set in_doc_id = did where id = p_id;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), r.company_id, 'إضافة', 'supply_requests', p_id::text, jsonb_build_object('no', r.req_no, 'in_doc', did));
  return did;
end $$;

create or replace function public.supply_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.supply_requests;
begin
  select * into r from public.supply_requests where id = p_id;
  if r.id is null then return; end if;
  if not public.can(r.company_id, 'supply_requests', 'delete') then raise exception 'ما عندك صلاحية'; end if;
  if r.out_doc_id is not null or r.in_doc_id is not null then raise exception 'الطلب إله سندات مخزون، ما بينحذف'; end if;
  if r.status = 'confirmed' then raise exception 'الطلب مثبت، رجّعه للانتظار أو ألغيه'; end if;
  delete from public.supply_requests where id = p_id;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), r.company_id, 'حذف', 'supply_requests', p_id::text, jsonb_build_object('no', r.req_no));
end $$;

-- اقتراح التعبئة للحد الأدنى: أصناف الوجهة اللي رصيدها أقل من الحد الأدنى
create or replace function public.supply_min_suggest(p_company uuid, p_from uuid, p_to uuid, p_date date default null)
returns table (item_id uuid, code text, name text, unit text, dest_qty numeric, min_qty numeric, max_qty numeric, src_qty numeric, need numeric, suggest numeric, state text)
language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_date, public.local_today());
begin
  if not (public.can(p_company, 'supply_requests', 'view') or public.can(p_company, 'inventory', 'view')) then raise exception 'ما عندك صلاحية'; end if;
  return query
  with x as (
    select i.id, i.code, i.name, i.unit, l.min_qty mn, l.max_qty mx,
           public.stock_qty(i.id, p_to, d) dq, public.stock_qty(i.id, p_from, d) sq
      from public.item_wh_limits l join public.items i on i.id = l.item_id
     where l.company_id = p_company and l.warehouse_id = p_to and l.min_qty > 0 and i.is_active and i.item_type = 'goods' and i.track_stock)
  select x.id, x.code, x.name, x.unit, x.dq, x.mn, x.mx, x.sq, greatest(x.mn - x.dq, 0),
         least(greatest(x.mn - x.dq, 0), greatest(x.sq, 0)),
         case when x.dq >= x.mn then 'covered' when x.sq <= 0 then 'unavailable' when x.sq < x.mn - x.dq then 'partial' else 'ok' end
    from x order by x.code;
end $$;

revoke execute on function public.supply_save(jsonb), public.supply_set_status(uuid, text), public.supply_issue_out(uuid), public.supply_issue_in(uuid),
  public.supply_delete(uuid), public.supply_min_suggest(uuid, uuid, uuid, date) from public, anon;
grant execute on function public.supply_save(jsonb), public.supply_set_status(uuid, text), public.supply_issue_out(uuid), public.supply_issue_in(uuid),
  public.supply_delete(uuid), public.supply_min_suggest(uuid, uuid, uuid, date) to authenticated;

-- النسخ الاحتياطي: الحدود بعد المستودعات، والطلبات قبل سندات المخزون (روابط السندات بترجع بعدين)
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
   (11, 'item_categories', 'company_id = $1', 'code'),
   (12, 'items', 'company_id = $1', 'code'),
   (13, 'promotions', 'company_id = $1', 'date_from'),
   (14, 'warehouses', 'company_id = $1', 'code'),
   (15, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (16, 'departments', 'company_id = $1', 'level, code'),
   (17, 'boms', 'company_id = $1', 'code'),
   (18, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (19, 'journal_entries', 'company_id = $1', 'created_at'),
   (20, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (21, 'invoices', 'company_id = $1', 'created_at'),
   (22, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (23, 'orders', 'company_id = $1', 'created_at'),
   (24, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (25, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (26, 'cheques', 'company_id = $1', 'created_at'),
   (27, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (28, 'supply_requests', 'company_id = $1', 'req_no'),
   (29, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (30, 'stock_docs', 'company_id = $1', 'created_at'),
   (31, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (32, 'stock_moves', 'company_id = $1', 'created_at'),
   (33, 'productions', 'company_id = $1', 'prod_no'),
   (34, 'obligations', 'company_id = $1', 'due_date'),
   (35, 'recurring_entries', 'company_id = $1', 'created_at'),
   (36, 'employees', 'company_id = $1', 'code'),
   (37, 'payroll_runs', 'company_id = $1', 'period'),
   (38, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (39, 'asset_custodians', 'company_id = $1', 'code'),
   (40, 'fixed_assets', 'company_id = $1', 'code'),
   (41, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (42, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (43, 'asset_movements', 'company_id = $1', 'mov_no'),
   (44, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (45, 'custody_docs', 'company_id = $1', 'doc_no'),
   (46, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (47, 'bank_recons', 'company_id = $1', 'created_at'),
   (48, 'bank_cleared', 'company_id = $1', 'line_id'),
   (49, 'attachments', 'company_id = $1', 'created_at'),
   (50, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
