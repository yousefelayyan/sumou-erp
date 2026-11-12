-- =====================================================================
--  السمو ERP — المرحلة 25: طلبات المبيعات والتزويد، العروض الترويجية، بطاقات الولاء، الحقول الإضافية
--  الطلب ما بيأثّر على الحسابات ولا المخزون؛ بيتحوّل لفاتورة (مسودة) وبينربط عليها.
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

-- ---------------------------------------------------------------------
--  الطلبات (طلب مبيعات / عرض سعر، طلب تزويد / أمر شراء)
-- ---------------------------------------------------------------------
create table if not exists public.orders (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies(id) on delete cascade,
  order_type     text not null check (order_type in ('sales_order','purchase_order')),
  order_no       int check (order_no > 0),
  order_date     date not null default current_date,
  valid_until    date,
  party_id       uuid references public.parties(id) on delete restrict,
  party_name     text,
  reference      text,
  notes          text,
  sales_rep_id   uuid references public.lookups(id) on delete set null,
  department_id  uuid references public.departments(id) on delete set null,
  status         text not null default 'open' check (status in ('open','converted','cancelled')),
  invoice_id     uuid references public.invoices(id) on delete set null,
  subtotal       numeric(18,3) not null default 0,
  tax_total      numeric(18,3) not null default 0,
  total          numeric(18,3) not null default 0,
  created_by     uuid default auth.uid(),
  created_at     timestamptz default now(),
  updated_by     uuid,
  updated_at     timestamptz,
  unique (company_id, order_type, order_no)
);
create table if not exists public.order_lines (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders(id) on delete cascade,
  line_no     int not null default 1,
  item_id     uuid references public.items(id) on delete restrict,
  description text,
  qty         numeric(18,3) not null default 1 check (qty > 0),
  unit_price  numeric(18,3) not null default 0 check (unit_price >= 0),
  discount    numeric(18,3) not null default 0 check (discount >= 0),
  tax_rate    numeric(6,3) not null default 0 check (tax_rate >= 0),
  check (discount <= qty * unit_price)
);
create unique index if not exists orders_invoice_uniq on public.orders (invoice_id) where invoice_id is not null;
create index if not exists order_lines_order_idx on public.order_lines (order_id, line_no);

create or replace function public.order_screen(p_type text) returns text
language sql immutable as $$ select case p_type when 'sales_order' then 'sales_orders' else 'purchase_orders' end $$;

create or replace function public.orders_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.parties; inv public.invoices; ptype text; itype text; v_notes text; v_by uuid; v_at timestamptz;
begin
  if tg_op = 'UPDATE' then
    new.company_id := old.company_id; new.order_type := old.order_type; new.order_no := old.order_no;
    if old.invoice_id is not null and new.invoice_id is null and not exists (select 1 from public.invoices where id = old.invoice_id) then
      new.status := 'open';   -- الفاتورة (المسودة) انحذفت: الطلب بيرجع مفتوح
      return new;
    end if;
    if not public.is_internal() then
      -- المجاميع من السطور بس، والربط بالفاتورة من link_order_invoice بس
      new.subtotal := old.subtotal; new.tax_total := old.tax_total; new.total := old.total;
      new.invoice_id := old.invoice_id;
      if old.status <> 'open' then
        -- الطلب المحوّل أو الملغى: بس الملاحظات بتتعدّل
        v_notes := new.notes; v_by := new.updated_by; v_at := new.updated_at;
        new := old; new.notes := v_notes; new.updated_by := v_by; new.updated_at := v_at;
        return new;
      end if;
      if new.status not in ('open', 'cancelled') then new.status := old.status; end if;
    end if;
  end if;
  if tg_op = 'INSERT' then
    if new.order_no is null then
      perform pg_advisory_xact_lock(hashtext('orders' || new.company_id::text || new.order_type));
      select coalesce(max(order_no), 0) + 1 into new.order_no from public.orders where company_id = new.company_id and order_type = new.order_type;
    end if;
    if not public.is_internal() then new.status := 'open'; new.invoice_id := null; new.subtotal := 0; new.tax_total := 0; new.total := 0; end if;
  end if;
  ptype := (case new.order_type when 'sales_order' then 'customer' else 'supplier' end);
  itype := (case new.order_type when 'sales_order' then 'sale' else 'purchase' end);
  if new.party_id is not null and (tg_op = 'INSERT' or new.party_id is distinct from old.party_id) then
    select * into p from public.parties where id = new.party_id;
    if p.id is null or p.company_id <> new.company_id or p.party_type <> ptype then
      raise exception 'الطرف مش مناسب لهالطلب';
    end if;
  end if;
  if new.sales_rep_id is not null and (tg_op = 'INSERT' or new.sales_rep_id is distinct from old.sales_rep_id) and not exists (select 1 from public.lookups l where l.id = new.sales_rep_id and l.company_id = new.company_id and l.kind = 'sales_rep') then
    raise exception 'المندوب مش لهالشركة';
  end if;
  if new.department_id is not null and (tg_op = 'INSERT' or new.department_id is distinct from old.department_id)
     and not exists (select 1 from public.departments d where d.id = new.department_id and d.company_id = new.company_id and d.kind = 'sub') then
    raise exception 'الدائرة لازم تكون فرعية ومن نفس الشركة';
  end if;
  if new.invoice_id is not null and (tg_op = 'INSERT' or new.invoice_id is distinct from old.invoice_id) then
    select * into inv from public.invoices where id = new.invoice_id;
    if inv.id is null or inv.company_id <> new.company_id
       or inv.inv_type <> itype then
      raise exception 'الفاتورة مش مناسبة لهالطلب';
    end if;
    new.status := 'converted';
  end if;
  return new;
end $$;
drop trigger if exists orders_before on public.orders;
create trigger orders_before before insert or update on public.orders
  for each row execute function public.orders_before();

-- مجموع الطلب من سطوره
create or replace function public.order_lines_after() returns trigger
language plpgsql security definer set search_path = public as $$
declare oid uuid := coalesce(new.order_id, old.order_id); s numeric; t numeric; prev text := current_setting('sumou.internal', true);
begin
  select coalesce(sum(round(qty * unit_price - discount, 3)), 0), coalesce(sum(round((qty * unit_price - discount) * tax_rate / 100, 3)), 0)
    into s, t from public.order_lines where order_id = oid;
  if exists (select 1 from public.orders where id = oid and (subtotal, tax_total) is distinct from (s, t)) then
    perform set_config('sumou.internal', public.internal_token(), true);
    update public.orders set subtotal = s, tax_total = t, total = s + t where id = oid;
    perform set_config('sumou.internal', coalesce(prev, ''), true);
  end if;
  return null;
end $$;
drop trigger if exists order_lines_after on public.order_lines;
create trigger order_lines_after after insert or update or delete on public.order_lines
  for each row execute function public.order_lines_after();

create or replace function public.order_lines_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare o public.orders; it public.items;
begin
  if tg_op = 'UPDATE' and new.order_id <> old.order_id then raise exception 'السطر ما بينقل لطلب ثاني'; end if;
  select * into o from public.orders where id = coalesce(new.order_id, old.order_id);
  if o.status <> 'open' and not public.is_internal() then raise exception 'الطلب مش مفتوح، ما بينعدّل'; end if;
  if tg_op <> 'DELETE' and new.item_id is not null then
    select * into it from public.items where id = new.item_id;
    if it.id is null or it.company_id <> o.company_id then raise exception 'الصنف مش لهالشركة'; end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists order_lines_before on public.order_lines;
create trigger order_lines_before before insert or update or delete on public.order_lines
  for each row execute function public.order_lines_before();

alter table public.orders enable row level security;
alter table public.order_lines enable row level security;
drop policy if exists ord_select on public.orders;
create policy ord_select on public.orders for select to authenticated using (public.can(company_id, public.order_screen(order_type), 'view'));
drop policy if exists ord_insert on public.orders;
create policy ord_insert on public.orders for insert to authenticated with check (public.can(company_id, public.order_screen(order_type), 'add'));
drop policy if exists ord_update on public.orders;
create policy ord_update on public.orders for update to authenticated
  using (public.can(company_id, public.order_screen(order_type), 'edit')) with check (public.can(company_id, public.order_screen(order_type), 'edit'));
drop policy if exists ord_delete on public.orders;
create policy ord_delete on public.orders for delete to authenticated using (status = 'open' and public.can(company_id, public.order_screen(order_type), 'delete'));
drop policy if exists ordl_all on public.order_lines;
drop policy if exists ordl_select on public.order_lines;
create policy ordl_select on public.order_lines for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id and public.can(o.company_id, public.order_screen(o.order_type), 'view')));
drop policy if exists ordl_insert on public.order_lines;
create policy ordl_insert on public.order_lines for insert to authenticated
  with check (exists (select 1 from public.orders o where o.id = order_id
                and (public.can(o.company_id, public.order_screen(o.order_type), 'edit') or public.can(o.company_id, public.order_screen(o.order_type), 'add'))));
drop policy if exists ordl_update on public.order_lines;
create policy ordl_update on public.order_lines for update to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id and public.can(o.company_id, public.order_screen(o.order_type), 'edit')))
  with check (exists (select 1 from public.orders o where o.id = order_id and public.can(o.company_id, public.order_screen(o.order_type), 'edit')));
drop policy if exists ordl_delete on public.order_lines;
create policy ordl_delete on public.order_lines for delete to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id
           and (public.can(o.company_id, public.order_screen(o.order_type), 'edit') or public.can(o.company_id, public.order_screen(o.order_type), 'add'))));

-- ربط الطلب بالفاتورة اللي انعملت منه (بصلاحية إضافة فواتير، ما بدها تعديل طلبات)
create or replace function public.link_order_invoice(p_order uuid, p_invoice uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.orders; i public.invoices; prev text := current_setting('sumou.internal', true);
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null or not public.can(o.company_id, public.order_screen(o.order_type), 'view') then raise exception 'الطلب مش موجود'; end if;
  select * into i from public.invoices where id = p_invoice;
  if i.id is null or i.company_id <> o.company_id or i.inv_type <> (case o.order_type when 'sales_order' then 'sale' else 'purchase' end) then raise exception 'الفاتورة مش مناسبة لهالطلب'; end if;
  if not public.can(i.company_id, case i.inv_type when 'sale' then 'sales_invoices' else 'purchase_invoices' end, 'add') then raise exception 'ما عندك صلاحية'; end if;
  if i.created_by is distinct from auth.uid() and not public.is_admin() then raise exception 'الفاتورة لازم تكون اللي إنت عملتها هلّق'; end if;
  if o.status <> 'open' then raise exception 'الطلب مش مفتوح (يمكن تحوّل من قبل)'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.orders set invoice_id = p_invoice, status = 'converted' where id = p_order;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
end $$;
grant execute on function public.link_order_invoice(uuid, uuid) to authenticated;
grant select, insert, update, delete on public.orders, public.order_lines to authenticated;

drop trigger if exists ac_audit_stamp on public.orders;
create trigger ac_audit_stamp before insert or update on public.orders for each row execute function public.ac_audit_stamp();
drop trigger if exists zy_audit_log on public.orders;
create trigger zy_audit_log after insert or update or delete on public.orders for each row execute function public.zy_audit_log();

-- ---------------------------------------------------------------------
--  العروض الترويجية: خصم % على صنف أو فئة أو كل الأصناف خلال فترة
-- ---------------------------------------------------------------------
create table if not exists public.promotions (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  name         text not null,
  date_from    date not null,
  date_to      date not null,
  item_id      uuid references public.items(id) on delete cascade,
  category_id  uuid references public.item_categories(id) on delete cascade,
  discount_pct numeric(6,3) not null check (discount_pct > 0 and discount_pct <= 100),
  min_qty      numeric(18,3) not null default 0,
  is_active    boolean not null default true,
  notes        text,
  created_by   uuid default auth.uid(),
  created_at   timestamptz default now(),
  check (date_to >= date_from)
);
create or replace function public.promotions_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then new.company_id := old.company_id; end if;
  if new.item_id is not null and not exists (select 1 from public.items where id = new.item_id and company_id = new.company_id) then raise exception 'الصنف مش لهالشركة'; end if;
  if new.category_id is not null and not exists (select 1 from public.item_categories where id = new.category_id and company_id = new.company_id) then raise exception 'الفئة مش لهالشركة'; end if;
  return new;
end $$;
drop trigger if exists promotions_before on public.promotions;
create trigger promotions_before before insert or update on public.promotions for each row execute function public.promotions_before();
alter table public.promotions enable row level security;
drop policy if exists promo_select on public.promotions;
create policy promo_select on public.promotions for select to authenticated using (public.has_company(company_id));
drop policy if exists promo_write on public.promotions;
create policy promo_write on public.promotions for all to authenticated
  using (public.can(company_id, 'marketing', 'edit')) with check (public.can(company_id, 'marketing', 'edit'));
grant select, insert, update, delete on public.promotions to authenticated;

-- ---------------------------------------------------------------------
--  بطاقات الولاء: نوع البطاقة (lookups kind = loyalty_type، rate = نقاط لكل دينار) ورقم البطاقة على العميل
-- ---------------------------------------------------------------------
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'public.lookups'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) like '%kind%' and pg_get_constraintdef(oid) not like '%loyalty_type%' loop
    execute format('alter table public.lookups drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'lookups_kind_chk2') then
    alter table public.lookups add constraint lookups_kind_chk2
      check (kind in ('payment_method','bank','bank_branch','country','region','cheque_type','sales_rep','loyalty_type'));
  end if;
end $$;
alter table public.parties add column if not exists loyalty_type_id uuid references public.lookups(id) on delete set null;
alter table public.parties add column if not exists loyalty_card_no text;
alter table public.parties add column if not exists loyalty_redeemed numeric(18,3) not null default 0;   -- نقاط مستبدلة
create or replace function public.parties_loyalty_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.loyalty_type_id is not null and (tg_op = 'INSERT' or new.loyalty_type_id is distinct from old.loyalty_type_id)
     and not exists (select 1 from public.lookups l where l.id = new.loyalty_type_id and l.company_id = new.company_id and l.kind = 'loyalty_type') then
    raise exception 'نوع بطاقة الولاء مش لهالشركة';
  end if;
  if new.loyalty_redeemed < 0 then raise exception 'النقاط المستبدلة ما بتكون سالبة'; end if;
  return new;
end $$;
drop trigger if exists parties_loyalty_check on public.parties;
create trigger parties_loyalty_check before insert or update of loyalty_type_id, loyalty_redeemed on public.parties
  for each row execute function public.parties_loyalty_check();

-- ---------------------------------------------------------------------
--  الحقول الإضافية: تعريف حقول للعملاء والموردين والأصناف، والقيم بعمود extra
-- ---------------------------------------------------------------------
create table if not exists public.custom_fields (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  entity     text not null check (entity in ('customer','supplier','item')),
  key        text not null check (key ~ '^[a-z][a-z0-9_]{0,30}$'),
  label      text not null,
  field_type text not null default 'text' check (field_type in ('text','number','date','select','check')),
  options    text,          -- للاختيارات: مفصولة بفاصلة
  sort       int not null default 0,
  is_active  boolean not null default true,
  unique (company_id, entity, key)
);
alter table public.custom_fields enable row level security;
drop policy if exists cf_select on public.custom_fields;
create policy cf_select on public.custom_fields for select to authenticated using (public.has_company(company_id));
drop policy if exists cf_write on public.custom_fields;
create policy cf_write on public.custom_fields for all to authenticated
  using (public.can(company_id, 'lookups', 'edit')) with check (public.can(company_id, 'lookups', 'edit'));
grant select, insert, update, delete on public.custom_fields to authenticated;
alter table public.parties add column if not exists extra jsonb not null default '{}'::jsonb;
alter table public.items   add column if not exists extra jsonb not null default '{}'::jsonb;

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
   (16, 'journal_entries',    'company_id = $1', 'created_at'),
   (17, 'journal_lines',      'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (18, 'invoices',           'company_id = $1', 'created_at'),
   (19, 'invoice_lines',      'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (20, 'orders',             'company_id = $1', 'created_at'),
   (21, 'order_lines',        'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (22, 'cheques',            'company_id = $1', 'created_at'),
   (23, 'cheque_events',      'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (24, 'stock_docs',         'company_id = $1', 'created_at'),
   (25, 'stock_doc_lines',    'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (26, 'stock_moves',        'company_id = $1', 'created_at'),
   (27, 'obligations',        'company_id = $1', 'due_date'),
   (28, 'recurring_entries',  'company_id = $1', 'created_at'),
   (29, 'employees',          'company_id = $1', 'code'),
   (30, 'payroll_runs',       'company_id = $1', 'period'),
   (31, 'payroll_lines',      'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (32, 'fixed_assets',       'company_id = $1', 'code'),
   (33, 'depreciation_runs',  'company_id = $1', 'created_at'),
   (34, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (35, 'bank_recons',        'company_id = $1', 'created_at'),
   (36, 'bank_cleared',       'company_id = $1', 'line_id'),
   (37, 'attachments',        'company_id = $1', 'created_at'),
   (38, 'fiscal_periods',     'company_id = $1', 'start_date');
$$;
