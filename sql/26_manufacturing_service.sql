-- =====================================================================
--  السمو ERP — المرحلة 26: التصنيع (قوائم المواد وأوامر الإنتاج)، الصيانة (بطاقات الصيانة)، تنسيق الحقول
--  أمر الإنتاج بيعمل سندين مخزون مسودة: إخراج المواد الخام، وإدخال المنتج بكلفتها؛ وبيترحّلوا بالطريقة العادية.
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

-- تنسيق الحقول لكل شركة: {entity: {field: {hide, label, required}}}
alter table public.company_settings add column if not exists field_layout jsonb not null default '{}'::jsonb;

-- ---------------------------------------------------------------------
--  قوائم المواد (الوصفة): منتج نهائي = مجموعة مواد خام بكميات
-- ---------------------------------------------------------------------
create table if not exists public.boms (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  code        text not null,
  name        text not null,
  item_id     uuid not null references public.items(id) on delete restrict,   -- المنتج
  output_qty  numeric(18,3) not null default 1 check (output_qty > 0),         -- الكمية اللي بتطلع من الوصفة
  extra_cost  numeric(18,3) not null default 0 check (extra_cost >= 0),       -- كلفة إضافية (عمالة، تشغيل) لكل دفعة
  is_active   boolean not null default true,
  notes       text,
  created_by  uuid default auth.uid(),
  created_at  timestamptz default now(),
  unique (company_id, code)
);
alter table public.boms add column if not exists updated_by uuid;
alter table public.boms add column if not exists updated_at timestamptz;
create table if not exists public.bom_lines (
  id       uuid primary key default gen_random_uuid(),
  bom_id   uuid not null references public.boms(id) on delete cascade,
  line_no  int not null default 1,
  item_id  uuid not null references public.items(id) on delete restrict,
  qty      numeric(18,3) not null check (qty > 0)
);
create unique index if not exists bom_lines_no_uniq on public.bom_lines (bom_id, line_no);
create or replace function public.boms_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then new.company_id := old.company_id; end if;
  if public.is_internal() then return new; end if;
  if not exists (select 1 from public.items where id = new.item_id and company_id = new.company_id and item_type = 'goods') then
    raise exception 'المنتج لازم يكون صنف بضاعة من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists boms_before on public.boms;
create trigger boms_before before insert or update on public.boms for each row execute function public.boms_before();
create or replace function public.bom_lines_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare b public.boms;
begin
  if tg_op = 'UPDATE' and new.bom_id <> old.bom_id then raise exception 'السطر ما بينقل لوصفة ثانية'; end if;
  if public.is_internal() then return new; end if;
  select * into b from public.boms where id = new.bom_id;
  if not exists (select 1 from public.items where id = new.item_id and company_id = b.company_id and item_type = 'goods') then
    raise exception 'المادة لازم تكون صنف بضاعة من نفس الشركة';
  end if;
  if new.item_id = b.item_id then raise exception 'المنتج ما بيكون مادة بوصفته'; end if;
  return new;
end $$;
drop trigger if exists bom_lines_before on public.bom_lines;
create trigger bom_lines_before before insert or update on public.bom_lines for each row execute function public.bom_lines_before();

-- أوامر الإنتاج
create table if not exists public.productions (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  prod_no      int check (prod_no > 0),
  prod_date    date not null default current_date,
  bom_id       uuid not null references public.boms(id) on delete restrict,
  batches      numeric(18,3) not null check (batches > 0),      -- عدد الدفعات
  warehouse_id uuid not null references public.warehouses(id) on delete restrict,
  out_doc_id   uuid references public.stock_docs(id) on delete set null,
  in_doc_id    uuid references public.stock_docs(id) on delete set null,
  total_cost   numeric(18,3) not null default 0,
  notes        text,
  created_by   uuid default auth.uid(),
  created_at   timestamptz default now(),
  unique (company_id, prod_no)
);

alter table public.stock_docs add column if not exists production_id uuid;

-- سندات أمر الإنتاج بتترحّل وبتنحذف من أمر الإنتاج بس (post_production / delete_production)
create or replace function public.prod_token_ok() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(current_setting('sumou.prod', true), '') = public.internal_token()
$$;
revoke execute on function public.prod_token_ok() from public, anon, authenticated;
create or replace function public.ab_production_doc_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if old.production_id is not null and not public.prod_token_ok() and not public.is_internal()
       and exists (select 1 from public.companies where id = old.company_id) then
      raise exception 'هالسند تابع لأمر إنتاج، احذف أمر الإنتاج من شاشة التصنيع';
    end if;
    return old;
  end if;
  if tg_op = 'UPDATE' then
    new.production_id := old.production_id;
    if old.production_id is not null and old.status = 'draft' and new.status = 'posted' and not public.prod_token_ok() then
      raise exception 'سندات أمر الإنتاج بتترحّل من شاشة أوامر الإنتاج (عشان الكلفة)';
    end if;
  elsif new.production_id is not null and not public.prod_token_ok() and not public.is_internal() then
    new.production_id := null;
  end if;
  return new;
end $$;
drop trigger if exists ab_production_doc_guard on public.stock_docs;
create trigger ab_production_doc_guard before insert or update or delete on public.stock_docs
  for each row execute function public.ab_production_doc_guard();
create or replace function public.ab_production_lines_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  select production_id into pid from public.stock_docs where id = coalesce(new.doc_id, old.doc_id);
  if pid is not null and not public.prod_token_ok() and not public.is_internal() then
    raise exception 'سطور سندات أمر الإنتاج ما بتتعدّل';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists ab_production_lines_guard on public.stock_doc_lines;
create trigger ab_production_lines_guard before insert or update or delete on public.stock_doc_lines
  for each row execute function public.ab_production_lines_guard();

-- إنشاء أمر إنتاج: بيعمل السندين (مسودة)، والكلفة بتنحسب وقت الترحيل
create or replace function public.create_production(p_bom uuid, p_batches numeric, p_date date, p_warehouse uuid, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare b public.boms; pid uuid := gen_random_uuid(); od uuid; idoc uuid; n int; r record; ln int := 0; prev text := current_setting('sumou.prod', true);
begin
  select * into b from public.boms where id = p_bom;
  if b.id is null or not b.is_active then raise exception 'الوصفة مش موجودة أو موقوفة'; end if;
  if not public.can(b.company_id, 'manufacturing', 'add') or not public.can(b.company_id, 'inventory', 'add') then raise exception 'ما عندك صلاحية'; end if;
  if coalesce(p_batches, 0) <= 0 then raise exception 'عدد الدفعات لازم أكبر من صفر'; end if;
  if p_date is null then raise exception 'اختار التاريخ'; end if;
  if not exists (select 1 from public.fiscal_years where company_id = b.company_id and not is_closed and p_date between start_date and end_date) then
    raise exception 'التاريخ لازم يكون جوّا سنة مالية مفتوحة';
  end if;
  if not exists (select 1 from public.warehouses where id = p_warehouse and company_id = b.company_id and is_active) then raise exception 'المستودع مش لهالشركة أو موقوف'; end if;
  if not exists (select 1 from public.bom_lines where bom_id = b.id) then raise exception 'الوصفة ما فيها مواد'; end if;
  if exists (select 1 from public.bom_lines l join public.items i on i.id = l.item_id where l.bom_id = b.id and (i.item_type <> 'goods' or not i.is_active)) then
    raise exception 'في مادة بالوصفة موقوفة أو مش بضاعة';
  end if;
  perform pg_advisory_xact_lock(hashtext('prod' || b.company_id::text));
  select coalesce(max(prod_no), 0) + 1 into n from public.productions where company_id = b.company_id;
  perform set_config('sumou.prod', public.internal_token(), true);
  insert into public.stock_docs (company_id, doc_type, doc_date, warehouse_id, notes, production_id)
  values (b.company_id, 'out', p_date, p_warehouse, 'أمر إنتاج ' || n || ': مواد خام لـ ' || b.name, pid) returning id into od;
  for r in select l.item_id, l.qty * p_batches as q from public.bom_lines l where l.bom_id = b.id order by l.line_no loop
    ln := ln + 1;
    insert into public.stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost) values (od, ln, r.item_id, r.q, 0);
  end loop;
  insert into public.stock_docs (company_id, doc_type, doc_date, warehouse_id, notes, production_id)
  values (b.company_id, 'in', p_date, p_warehouse, 'أمر إنتاج ' || n || ': ' || b.name, pid) returning id into idoc;
  insert into public.stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost) values (idoc, 1, b.item_id, b.output_qty * p_batches, 0);
  insert into public.productions (id, company_id, prod_no, prod_date, bom_id, batches, warehouse_id, out_doc_id, in_doc_id, total_cost, notes)
  values (pid, b.company_id, n, p_date, b.id, p_batches, p_warehouse, od, idoc, 0, p_notes);
  perform set_config('sumou.prod', coalesce(prev, ''), true);
  return pid;
end $$;
grant execute on function public.create_production(uuid, numeric, date, uuid, text) to authenticated;

-- ترحيل أمر الإنتاج للمخزون: إخراج المواد أول، وبعدين إدخال المنتج بكلفتها الفعلية + الكلفة الإضافية
create or replace function public.post_production(p_id uuid) returns numeric
language plpgsql security definer set search_path = public as $$
declare p public.productions; b public.boms; od public.stock_docs; idoc public.stock_docs; cost numeric; q numeric;
        prev text := current_setting('sumou.prod', true); previ text := current_setting('sumou.internal', true);
begin
  select * into p from public.productions where id = p_id for update;
  if p.id is null or not public.can(p.company_id, 'manufacturing', 'post') or not public.can(p.company_id, 'inventory', 'post') then raise exception 'ما عندك صلاحية ترحيل'; end if;
  select * into b from public.boms where id = p.bom_id;
  select * into od from public.stock_docs where id = p.out_doc_id;
  select * into idoc from public.stock_docs where id = p.in_doc_id;
  if od.id is null or idoc.id is null then raise exception 'سندات أمر الإنتاج ناقصة'; end if;
  if idoc.status = 'posted' then raise exception 'أمر الإنتاج مرحّل من قبل'; end if;
  perform set_config('sumou.prod', public.internal_token(), true);
  if od.status <> 'posted' then perform public.post_stock_doc(od.id); end if;
  select coalesce(-sum(qty * unit_cost), 0) into cost from public.stock_moves where source_type = 'stock_doc' and source_id = od.id;
  cost := round(cost + b.extra_cost * p.batches, 3);
  q := b.output_qty * p.batches;
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.stock_doc_lines set unit_cost = round(cost / q, 3) where doc_id = idoc.id;
  update public.productions set total_cost = cost where id = p.id;
  perform set_config('sumou.internal', coalesce(previ, ''), true);
  perform public.post_stock_doc(idoc.id);
  perform set_config('sumou.prod', coalesce(prev, ''), true);
  return cost;
end $$;
grant execute on function public.post_production(uuid) to authenticated;

-- حذف أمر الإنتاج مع سنداته (مسودات بس)
create or replace function public.delete_production(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p public.productions; prev text := current_setting('sumou.prod', true);
begin
  select * into p from public.productions where id = p_id for update;
  if p.id is null or not public.can(p.company_id, 'manufacturing', 'delete') or not public.can(p.company_id, 'inventory', 'delete') then raise exception 'ما عندك صلاحية'; end if;
  if exists (select 1 from public.stock_docs where id in (p.out_doc_id, p.in_doc_id) and status = 'posted') then
    raise exception 'في سند مرحّل لأمر الإنتاج؛ ألغِ ترحيله أول';
  end if;
  perform set_config('sumou.prod', public.internal_token(), true);
  delete from public.productions where id = p.id;
  delete from public.stock_docs where id in (p.out_doc_id, p.in_doc_id);
  perform set_config('sumou.prod', coalesce(prev, ''), true);
end $$;
grant execute on function public.delete_production(uuid) to authenticated;

-- الإنتاج ما بينعدّل مباشرة (بس الملاحظات)
create or replace function public.productions_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if public.is_internal() then return new; end if;
  v := new.notes; new := old; new.notes := v; return new;
end $$;
drop trigger if exists productions_before on public.productions;
create trigger productions_before before update on public.productions for each row execute function public.productions_before();

alter table public.boms enable row level security;
alter table public.bom_lines enable row level security;
alter table public.productions enable row level security;
drop policy if exists bom_select on public.boms;
create policy bom_select on public.boms for select to authenticated using (public.can(company_id, 'manufacturing', 'view'));
drop policy if exists bom_insert on public.boms;
create policy bom_insert on public.boms for insert to authenticated with check (public.can(company_id, 'manufacturing', 'add'));
drop policy if exists bom_update on public.boms;
create policy bom_update on public.boms for update to authenticated using (public.can(company_id, 'manufacturing', 'edit')) with check (public.can(company_id, 'manufacturing', 'edit'));
drop policy if exists bom_delete on public.boms;
create policy bom_delete on public.boms for delete to authenticated using (public.can(company_id, 'manufacturing', 'delete'));
drop policy if exists boml_select on public.bom_lines;
create policy boml_select on public.bom_lines for select to authenticated
  using (exists (select 1 from public.boms b where b.id = bom_id and public.can(b.company_id, 'manufacturing', 'view')));
drop policy if exists boml_write on public.bom_lines;
create or replace function public.bom_has_lines(p_bom uuid) returns boolean
language sql stable security definer set search_path = public as $$ select exists (select 1 from public.bom_lines where bom_id = p_bom) $$;
drop policy if exists boml_insert on public.bom_lines;
create policy boml_insert on public.bom_lines for insert to authenticated
  with check (exists (select 1 from public.boms b where b.id = bom_id and (public.can(b.company_id, 'manufacturing', 'edit')
    or (public.can(b.company_id, 'manufacturing', 'add') and b.created_by = auth.uid() and not public.bom_has_lines(b.id)))));
drop policy if exists boml_update on public.bom_lines;
create policy boml_update on public.bom_lines for update to authenticated
  using (exists (select 1 from public.boms b where b.id = bom_id and public.can(b.company_id, 'manufacturing', 'edit')))
  with check (exists (select 1 from public.boms b where b.id = bom_id and public.can(b.company_id, 'manufacturing', 'edit')));
drop policy if exists boml_delete on public.bom_lines;
create policy boml_delete on public.bom_lines for delete to authenticated
  using (exists (select 1 from public.boms b where b.id = bom_id and public.can(b.company_id, 'manufacturing', 'edit')));
drop policy if exists prod_select on public.productions;
create policy prod_select on public.productions for select to authenticated using (public.can(company_id, 'manufacturing', 'view'));
drop policy if exists prod_update on public.productions;
create policy prod_update on public.productions for update to authenticated using (public.can(company_id, 'manufacturing', 'edit')) with check (public.can(company_id, 'manufacturing', 'edit'));
drop policy if exists prod_delete on public.productions;
grant select, insert, update, delete on public.boms, public.bom_lines to authenticated;
grant select, update on public.productions to authenticated;
revoke delete on public.productions from authenticated;
drop trigger if exists ac_audit_stamp on public.boms;
create trigger ac_audit_stamp before insert or update on public.boms for each row execute function public.ac_audit_stamp();
drop trigger if exists zy_audit_log on public.boms;
create trigger zy_audit_log after insert or update or delete on public.boms for each row execute function public.zy_audit_log();

-- ---------------------------------------------------------------------
--  الصيانة: بطاقة لكل جهاز بيستلمه المحل من العميل
-- ---------------------------------------------------------------------
create table if not exists public.service_tickets (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  ticket_no     int check (ticket_no > 0),
  received_at   date not null default current_date,
  party_id      uuid references public.parties(id) on delete restrict,
  customer_name text,
  phone         text,
  device        text not null,
  serial_no     text,
  problem       text,
  accessories   text,
  technician    text,
  estimate      numeric(18,3) not null default 0 check (estimate >= 0),
  status        text not null default 'received' check (status in ('received','in_progress','waiting_parts','ready','delivered','cancelled')),
  promised_at   date,
  delivered_at  date,
  work_done     text,
  invoice_id    uuid references public.invoices(id) on delete set null,
  notes         text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz default now(),
  updated_by    uuid,
  updated_at    timestamptz,
  unique (company_id, ticket_no)
);
create or replace function public.service_tickets_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if tg_op = 'UPDATE' then new.company_id := old.company_id; new.ticket_no := old.ticket_no; end if;
  if tg_op = 'INSERT' and not (public.is_internal() and new.ticket_no is not null) then
    perform pg_advisory_xact_lock(hashtext('svc' || new.company_id::text));
    select coalesce(max(ticket_no), 0) + 1 into n from public.service_tickets where company_id = new.company_id;
    new.ticket_no := n;
  end if;
  if btrim(coalesce(new.device, '')) = '' then raise exception 'اكتب الجهاز'; end if;
  if new.party_id is not null and (tg_op = 'INSERT' or new.party_id is distinct from old.party_id)
     and not exists (select 1 from public.parties where id = new.party_id and company_id = new.company_id and party_type = 'customer') then
    raise exception 'العميل مش لهالشركة';
  end if;
  if new.invoice_id is not null and (tg_op = 'INSERT' or new.invoice_id is distinct from old.invoice_id) and not public.is_internal()
     and (not public.can(new.company_id, 'sales_invoices', 'add')
          or not exists (select 1 from public.invoices where id = new.invoice_id and company_id = new.company_id and inv_type = 'sale' and created_by = auth.uid())) then
    raise exception 'الفاتورة مش مناسبة';
  end if;
  if new.status = 'delivered' and new.delivered_at is null then new.delivered_at := current_date; end if;
  return new;
end $$;
drop trigger if exists service_tickets_before on public.service_tickets;
create trigger service_tickets_before before insert or update on public.service_tickets for each row execute function public.service_tickets_before();
alter table public.service_tickets enable row level security;
drop policy if exists svc_select on public.service_tickets;
create policy svc_select on public.service_tickets for select to authenticated using (public.can(company_id, 'maintenance', 'view'));
drop policy if exists svc_insert on public.service_tickets;
create policy svc_insert on public.service_tickets for insert to authenticated with check (public.can(company_id, 'maintenance', 'add'));
drop policy if exists svc_update on public.service_tickets;
create policy svc_update on public.service_tickets for update to authenticated using (public.can(company_id, 'maintenance', 'edit')) with check (public.can(company_id, 'maintenance', 'edit'));
drop policy if exists svc_delete on public.service_tickets;
create policy svc_delete on public.service_tickets for delete to authenticated using (public.can(company_id, 'maintenance', 'delete') and invoice_id is null);
grant select, insert, update, delete on public.service_tickets to authenticated;
drop trigger if exists ac_audit_stamp on public.service_tickets;
create trigger ac_audit_stamp before insert or update on public.service_tickets for each row execute function public.ac_audit_stamp();
drop trigger if exists zy_audit_log on public.service_tickets;
create trigger zy_audit_log after insert or update or delete on public.service_tickets for each row execute function public.zy_audit_log();

-- ---------------------------------------------------------------------
--  النسخ الاحتياطي
-- ---------------------------------------------------------------------
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
   (36, 'fixed_assets',       'company_id = $1', 'code'),
   (37, 'depreciation_runs',  'company_id = $1', 'created_at'),
   (38, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (39, 'bank_recons',        'company_id = $1', 'created_at'),
   (40, 'bank_cleared',       'company_id = $1', 'line_id'),
   (41, 'attachments',        'company_id = $1', 'created_at'),
   (42, 'fiscal_periods',     'company_id = $1', 'start_date');
$$;
