-- =====================================================================
--  السمو ERP — المرحلة 50: قوائم الأسعار وضوابط سعر البيع
--  price_lists / price_list_items (سعر الصنف لكل قائمة)، parties.price_list_id (قائمة الزبون).
--  ضوابط على الصنف (وإذا فاضي من فئته): min_price (أقل سعر بيع للوحدة بعد الخصم)، max_discount_pct.
--  company_settings.block_below_cost: منع البيع بسعر صافي أقل من متوسط الكلفة.
--  تجاوز الضوابط: المدير أو شاشة price_override (edit). الفحص على سطور فواتير البيع (مش الداخلي).
-- =====================================================================
create table if not exists public.price_lists (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code       text not null,
  name       text not null,
  is_active  boolean not null default true,
  notes      text,
  created_at timestamptz not null default now(),
  unique (company_id, code)
);
create table if not exists public.price_list_items (
  id       uuid primary key default gen_random_uuid(),
  list_id  uuid not null references public.price_lists(id) on delete cascade,
  item_id  uuid not null references public.items(id) on delete cascade,
  price    numeric(18,3) not null check (price >= 0),
  unique (list_id, item_id)
);
alter table public.price_lists enable row level security;
alter table public.price_list_items enable row level security;
grant select, insert, update, delete on public.price_lists, public.price_list_items to authenticated;
drop policy if exists pl_select on public.price_lists;
create policy pl_select on public.price_lists for select to authenticated using (public.has_company(company_id));
drop policy if exists pl_write on public.price_lists;
create policy pl_write on public.price_lists for all to authenticated
  using (public.can(company_id, 'items', 'edit') and public.tenant_writable()) with check (public.can(company_id, 'items', 'edit') and public.tenant_writable());
drop policy if exists pli_select on public.price_list_items;
create policy pli_select on public.price_list_items for select to authenticated
  using (exists (select 1 from public.price_lists l where l.id = list_id and public.has_company(l.company_id)));
drop policy if exists pli_write on public.price_list_items;
create policy pli_write on public.price_list_items for all to authenticated
  using (exists (select 1 from public.price_lists l where l.id = list_id and public.can(l.company_id, 'items', 'edit')) and public.tenant_writable())
  with check (exists (select 1 from public.price_lists l join public.items i on i.id = item_id and i.company_id = l.company_id
                      where l.id = list_id and public.can(l.company_id, 'items', 'edit')) and public.tenant_writable());

alter table public.parties add column if not exists price_list_id uuid references public.price_lists(id) on delete set null;
alter table public.items add column if not exists min_price numeric(18,3) check (min_price >= 0);
alter table public.items add column if not exists max_discount_pct numeric(6,3) check (max_discount_pct between 0 and 100);
alter table public.item_categories add column if not exists min_margin_pct numeric(6,3) check (min_margin_pct between -100 and 1000);
alter table public.item_categories add column if not exists max_discount_pct numeric(6,3) check (max_discount_pct between 0 and 100);
alter table public.company_settings add column if not exists block_below_cost boolean not null default false;

-- قائمة الزبون لازم من نفس الشركة
create or replace function public.ad_party_price_list_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.price_list_id is not null and not exists (select 1 from public.price_lists where id = new.price_list_id and company_id = new.company_id) then
    if public.is_internal() then new.price_list_id := null; else raise exception 'قائمة الأسعار مش من نفس الشركة'; end if;
  end if;
  return new;
end $$;
drop trigger if exists ad_party_price_list_check on public.parties;
create trigger ad_party_price_list_check before insert or update of price_list_id on public.parties for each row execute function public.ad_party_price_list_check();

-- فحص سطر فاتورة البيع
create or replace function public.ab_sale_price_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv public.invoices; it public.items; cat public.item_categories; net_unit numeric; gross numeric; disc_pct numeric; maxd numeric; minp numeric; cost numeric; blk boolean;
begin
  if public.is_internal() or new.item_id is null then return new; end if;
  if tg_op = 'UPDATE' and new.unit_price = old.unit_price and new.discount = old.discount and new.qty = old.qty and new.item_id is not distinct from old.item_id then return new; end if;
  select * into inv from public.invoices where id = new.invoice_id;
  if inv.inv_type <> 'sale' then return new; end if;
  if public.is_admin() or public.can(inv.company_id, 'price_override', 'edit') then return new; end if;
  select * into it from public.items where id = new.item_id;
  select * into cat from public.item_categories where id = it.category_id;
  gross := new.qty * new.unit_price;
  net_unit := case when new.qty > 0 then (gross - new.discount) / new.qty else 0 end;
  -- السعر اللي داخل بالفاتورة ممكن يكون شامل الضريبة؛ الفحص على السعر قبل الضريبة
  if inv.prices_include_tax and new.tax_rate > 0 then net_unit := net_unit / (1 + new.tax_rate / 100); end if;
  disc_pct := case when gross > 0 then new.discount * 100 / gross else 0 end;
  maxd := coalesce(it.max_discount_pct, cat.max_discount_pct);
  if maxd is not null and disc_pct > maxd + 0.0005 then
    raise exception 'الخصم على «%» (% %%) أكثر من المسموح (% %%)', it.name, round(disc_pct, 2), maxd;
  end if;
  minp := it.min_price;
  if minp is not null and net_unit + 0.0005 < minp then
    raise exception 'سعر «%» بعد الخصم (%) أقل من أقل سعر بيع (%)', it.name, round(net_unit, 3), minp;
  end if;
  select block_below_cost into blk from public.company_settings where company_id = inv.company_id;
  if coalesce(blk, false) or cat.min_margin_pct is not null then
    cost := public.item_avg_cost(inv.company_id, new.item_id, inv.inv_date);
    if coalesce(cost, 0) > 0 then
      if coalesce(blk, false) and net_unit + 0.0005 < cost then
        raise exception 'سعر «%» بعد الخصم (%) أقل من الكلفة (%)', it.name, round(net_unit, 3), round(cost, 3);
      end if;
      if cat.min_margin_pct is not null and net_unit + 0.0005 < cost * (1 + cat.min_margin_pct / 100) then
        raise exception 'سعر «%» أقل من هامش الربح الأدنى لفئته (% %%)', it.name, cat.min_margin_pct;
      end if;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists ab_sale_price_guard on public.invoice_lines;
create trigger ab_sale_price_guard before insert or update on public.invoice_lines for each row execute function public.ab_sale_price_guard();

-- سعر الصنف للزبون: من قائمته، وإلا سعر البيع
create or replace function public.party_item_prices(p_company uuid, p_party uuid) returns table (item_id uuid, price numeric)
language sql stable security definer set search_path = public as $$
  select pli.item_id, pli.price from public.parties p join public.price_lists l on l.id = p.price_list_id and l.is_active
    join public.price_list_items pli on pli.list_id = l.id
   where p.id = p_party and p.company_id = p_company and public.has_company(p_company);
$$;
revoke execute on function public.party_item_prices(uuid, uuid) from public, anon;
grant execute on function public.party_item_prices(uuid, uuid) to authenticated;

-- النسخة الاحتياطية: قوائم الأسعار بعد الأصناف وقبل العملاء
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
   (10, 'price_lists', 'company_id = $1', 'code'),
   (11, 'parties', 'company_id = $1', 'code'),
   (12, 'sales_visits', 'company_id = $1', 'started_at'),
   (13, 'item_categories', 'company_id = $1', 'code'),
   (14, 'items', 'company_id = $1', 'code'),
   (15, 'price_list_items', 'list_id in (select id from public.price_lists where company_id = $1)', 'list_id'),
   (16, 'promotions', 'company_id = $1', 'date_from'),
   (17, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (18, 'warehouses', 'company_id = $1', 'code'),
   (19, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (20, 'departments', 'company_id = $1', 'level, code'),
   (21, 'doc_types', 'company_id = $1', 'kind, code'),
   (22, 'boms', 'company_id = $1', 'code'),
   (23, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (24, 'journal_entries', 'company_id = $1', 'created_at'),
   (25, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (26, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (27, 'invoices', 'company_id = $1', 'created_at'),
   (28, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (29, 'invoice_allocations', 'company_id = $1', 'created_at'),
   (30, 'orders', 'company_id = $1', 'created_at'),
   (31, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (32, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (33, 'cheques', 'company_id = $1', 'created_at'),
   (34, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (35, 'supply_requests', 'company_id = $1', 'req_no'),
   (36, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (37, 'stock_docs', 'company_id = $1', 'created_at'),
   (38, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (39, 'stock_moves', 'company_id = $1', 'created_at'),
   (40, 'productions', 'company_id = $1', 'prod_no'),
   (41, 'obligations', 'company_id = $1', 'due_date'),
   (42, 'recurring_entries', 'company_id = $1', 'created_at'),
   (43, 'work_locations', 'company_id = $1', 'name'),
   (44, 'employees', 'company_id = $1', 'code'),
   (45, 'attendance', 'company_id = $1', 'day, employee_id'),
   (46, 'payroll_runs', 'company_id = $1', 'period'),
   (47, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (48, 'employee_loans', 'company_id = $1', 'loan_no'),
   (49, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (50, 'asset_custodians', 'company_id = $1', 'code'),
   (51, 'fixed_assets', 'company_id = $1', 'code'),
   (52, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (53, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (54, 'asset_movements', 'company_id = $1', 'mov_no'),
   (55, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (56, 'custody_docs', 'company_id = $1', 'doc_no'),
   (57, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (58, 'bank_recons', 'company_id = $1', 'created_at'),
   (59, 'bank_cleared', 'company_id = $1', 'line_id'),
   (60, 'attachments', 'company_id = $1', 'created_at'),
   (61, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
