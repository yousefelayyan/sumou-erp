-- =====================================================================
--  السمو ERP — المرحلة 70: العقود والرسوم المتكررة
--  contracts (عقد على عميل: كل كم شهر، يوم الشهر، من/إلى، التاريخ الجاي، فعّال/موقوف/منتهي، ترحيل تلقائي) و contract_lines
--  (زي سطور الفاتورة). contract_generate(company, until): بيطلّع فاتورة بيع آجلة لكل استحقاق لغاية التاريخ (مسودة أو مرحّلة)
--  وبيقدّم التاريخ الجاي. invoices.contract_id + contract_period (الفترة اللي بتغطيها). contract_due(company, until) للمعاينة.
--  الصلاحية شاشة contracts (قسم sales، أخذتها مرة وحدة المجموعات اللي إلها sales_invoices).
-- =====================================================================
do $$ begin
  if to_regclass('public.contracts') is null then
    update public.user_groups set permissions = permissions || jsonb_build_object('contracts', permissions -> 'sales_invoices')
     where permissions ? 'sales_invoices' and not permissions ? 'contracts';
  end if;
end $$;

create or replace function public.screen_module(s text) returns text
language sql immutable as $$
  select case
    when s in ('customers','sales_invoices','sales_orders','pos','rep_visits','customer_notes','contracts')  then 'sales'
    when s in ('suppliers','purchase_invoices','purchase_orders','landed_costs','supplier_notes') then 'purchases'
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

create table if not exists public.contracts (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies(id) on delete cascade,
  contract_no    int not null,
  party_id       uuid not null references public.parties(id) on delete restrict,
  title          text not null check (length(title) between 1 and 200),
  every_months   int not null default 1 check (every_months in (1, 2, 3, 4, 6, 12)),
  day_of_month   int not null default 1 check (day_of_month between 1 and 28),
  start_date     date not null,
  end_date       date,
  next_date      date not null,
  status         text not null default 'active' check (status in ('active','paused','ended')),
  auto_post      boolean not null default false,
  prices_include_tax boolean not null default false,
  department_id  uuid references public.departments(id) on delete set null,
  sales_rep_id   uuid references public.lookups(id) on delete set null,
  notes          text,
  created_by     uuid default auth.uid(),
  created_at     timestamptz not null default now(),
  updated_by     uuid,
  updated_at     timestamptz,
  unique (company_id, contract_no),
  check (end_date is null or end_date >= start_date)
);
create table if not exists public.contract_lines (
  id           uuid primary key default gen_random_uuid(),
  contract_id  uuid not null references public.contracts(id) on delete cascade,
  line_no      int not null default 1,
  item_id      uuid references public.items(id) on delete set null,
  description  text,
  qty          numeric(18,3) not null default 1 check (qty > 0),
  unit_price   numeric(18,3) not null default 0 check (unit_price >= 0),
  discount     numeric(18,3) not null default 0 check (discount >= 0),
  tax_rate     numeric(6,3) not null default 16 check (tax_rate between 0 and 100)
);
create index if not exists contract_lines_c_idx on public.contract_lines (contract_id, line_no);
create index if not exists contracts_due_idx on public.contracts (company_id, status, next_date);
alter table public.invoices add column if not exists contract_id uuid references public.contracts(id) on delete set null;
alter table public.invoices add column if not exists contract_period text;
create index if not exists invoices_contract_idx on public.invoices (contract_id) where contract_id is not null;
grant select, insert, update, delete on public.contracts, public.contract_lines to authenticated;

alter table public.contracts enable row level security;
alter table public.contract_lines enable row level security;
drop policy if exists contracts_sel on public.contracts;
create policy contracts_sel on public.contracts for select using (public.can(company_id, 'contracts', 'view') and public.dept_ok(company_id, department_id));
drop policy if exists contracts_ins on public.contracts;
create policy contracts_ins on public.contracts for insert with check (public.can(company_id, 'contracts', 'add') and public.tenant_writable() and public.dept_ok(company_id, department_id));
drop policy if exists contracts_upd on public.contracts;
create policy contracts_upd on public.contracts for update using (public.can(company_id, 'contracts', 'edit') and public.tenant_writable() and public.dept_ok(company_id, department_id))
  with check (public.can(company_id, 'contracts', 'edit') and public.tenant_writable() and public.dept_ok(company_id, department_id));
drop policy if exists contracts_del on public.contracts;
create policy contracts_del on public.contracts for delete using (public.can(company_id, 'contracts', 'delete') and public.tenant_writable() and public.dept_ok(company_id, department_id)
  and not exists (select 1 from public.invoices i where i.contract_id = contracts.id));
drop policy if exists contract_lines_sel on public.contract_lines;
create policy contract_lines_sel on public.contract_lines for select using (exists (select 1 from public.contracts c where c.id = contract_id and public.can(c.company_id, 'contracts', 'view') and public.dept_ok(c.company_id, c.department_id)));
drop policy if exists contract_lines_wr on public.contract_lines;
drop policy if exists contract_lines_ins on public.contract_lines;
create policy contract_lines_ins on public.contract_lines for insert
  with check (exists (select 1 from public.contracts c where c.id = contract_id and (public.can(c.company_id, 'contracts', 'add') or public.can(c.company_id, 'contracts', 'edit')) and public.tenant_writable() and public.dept_ok(c.company_id, c.department_id)));
drop policy if exists contract_lines_upd on public.contract_lines;
create policy contract_lines_upd on public.contract_lines for update
  using (exists (select 1 from public.contracts c where c.id = contract_id and public.can(c.company_id, 'contracts', 'edit') and public.tenant_writable() and public.dept_ok(c.company_id, c.department_id)))
  with check (exists (select 1 from public.contracts c where c.id = contract_id and public.can(c.company_id, 'contracts', 'edit') and public.tenant_writable() and public.dept_ok(c.company_id, c.department_id)));
drop policy if exists contract_lines_del on public.contract_lines;
create policy contract_lines_del on public.contract_lines for delete
  using (exists (select 1 from public.contracts c where c.id = contract_id and public.can(c.company_id, 'contracts', 'edit') and public.tenant_writable() and public.dept_ok(c.company_id, c.department_id)));
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'contract_lines_disc_chk') then
    alter table public.contract_lines add constraint contract_lines_disc_chk check (discount <= round(qty * unit_price, 3));
  end if;
end $$;
-- ما بتطلع فاتورتين لنفس العقد بنفس التاريخ
create unique index if not exists invoices_contract_date_uq on public.invoices (contract_id, inv_date) where contract_id is not null and status <> 'cancelled';

create or replace function public.ab_contract_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then new.company_id := old.company_id; new.contract_no := old.contract_no; new.created_by := old.created_by; new.created_at := old.created_at;
    new.updated_by := auth.uid(); new.updated_at := now();
  else
    if new.contract_no is null or not public.is_internal() then
      perform pg_advisory_xact_lock(hashtext('contract:' || new.company_id::text));
      select coalesce(max(contract_no), 0) + 1 into new.contract_no from public.contracts where company_id = new.company_id;
    end if;
    if not public.is_internal() then new.created_by := auth.uid(); new.created_at := now(); end if;
  end if;
  if not exists (select 1 from public.parties where id = new.party_id and company_id = new.company_id and party_type = 'customer') then raise exception 'العقد لازم يكون على عميل من نفس الشركة'; end if;
  if new.department_id is not null and not exists (select 1 from public.departments where id = new.department_id and company_id = new.company_id and kind = 'sub') then raise exception 'الدائرة لازم فرعية ومن نفس الشركة'; end if;
  if new.sales_rep_id is not null and not exists (select 1 from public.lookups where id = new.sales_rep_id and company_id = new.company_id and kind = 'sales_rep') then raise exception 'المندوب مش من نفس الشركة'; end if;
  if tg_op = 'INSERT' and new.department_id is null and not public.is_internal() then
    select department_id into new.department_id from public.user_companies where user_id = auth.uid() and company_id = new.company_id;
  end if;
  if new.next_date is null and tg_op = 'UPDATE' then new.next_date := old.next_date; end if;
  if new.next_date is null or new.next_date < new.start_date then new.next_date := new.start_date; end if;
  -- التاريخ الجاي دايماً على يوم الفاتورة بالشهر (أول يوم مناسب من التاريخ المكتوب)
  if extract(day from new.next_date) <> new.day_of_month then
    new.next_date := case when extract(day from new.next_date) < new.day_of_month then date_trunc('month', new.next_date)::date + (new.day_of_month - 1)
                          else (date_trunc('month', new.next_date) + interval '1 month')::date + (new.day_of_month - 1) end;
  end if;
  if tg_op = 'UPDATE' and new.next_date is distinct from old.next_date and not public.is_internal()
     and coalesce(current_setting('sumou.contract', true), '') <> public.internal_token()
     and exists (select 1 from public.invoices i where i.contract_id = new.id and i.status <> 'cancelled' and i.inv_date >= new.next_date) then
    raise exception 'الاستحقاق الجاي لازم يكون بعد آخر فاتورة طلعت من العقد';
  end if;
  new.title := trim(new.title);
  return new;
end $$;
drop trigger if exists ab_contract_guard on public.contracts;
create trigger ab_contract_guard before insert or update on public.contracts for each row execute function public.ab_contract_guard();
create or replace function public.ab_contract_line_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare c public.contracts;
begin
  if tg_op = 'UPDATE' then new.contract_id := old.contract_id; end if;
  select * into c from public.contracts where id = new.contract_id;
  if new.item_id is not null and not exists (select 1 from public.items where id = new.item_id and company_id = c.company_id) then raise exception 'الصنف مش من نفس الشركة'; end if;
  return new;
end $$;
drop trigger if exists ab_contract_line_guard on public.contract_lines;
create trigger ab_contract_line_guard before insert or update on public.contract_lines for each row execute function public.ab_contract_line_guard();
-- ربط الفاتورة بالعقد: من النظام بس
create or replace function public.ab_invoice_contract_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() or coalesce(current_setting('sumou.contract', true), '') = public.internal_token() then return new; end if;
  if tg_op = 'INSERT' then new.contract_id := null; new.contract_period := null;
  else new.contract_id := old.contract_id; new.contract_period := old.contract_period; end if;
  return new;
end $$;
drop trigger if exists ab_invoice_contract_guard on public.invoices;
create trigger ab_invoice_contract_guard before insert or update of contract_id, contract_period on public.invoices for each row execute function public.ab_invoice_contract_guard();
revoke execute on function public.ab_contract_guard(), public.ab_contract_line_guard(), public.ab_invoice_contract_guard() from public, anon, authenticated;

-- الاستحقاقات لغاية تاريخ (معاينة): عقد × تاريخ
create or replace function public.contract_due(p_company uuid, p_until date)
returns table (contract_id uuid, contract_no int, party_id uuid, title text, due_date date, amount numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.can(p_company, 'contracts', 'view') then raise exception 'ما عندك صلاحية'; end if;
  return query
  with recursive d as (
    select c.id, c.next_date dd, c.every_months, c.end_date, 1 k from public.contracts c
     where c.company_id = p_company and c.status = 'active' and c.next_date <= p_until and (c.end_date is null or c.next_date <= c.end_date)
       and public.dept_ok(c.company_id, c.department_id) and exists (select 1 from public.contract_lines l where l.contract_id = c.id)
    union all
    select d.id, x.nd, d.every_months, d.end_date, d.k + 1 from d, lateral (select (date_trunc('month', d.dd) + make_interval(months => d.every_months))::date + (c2.day_of_month - 1) nd from public.contracts c2 where c2.id = d.id) x
     where x.nd <= p_until and (d.end_date is null or x.nd <= d.end_date) and d.k < 36)
  select c.id, c.contract_no, c.party_id, c.title, d.dd,
         (select coalesce(sum(round((l.qty * l.unit_price - l.discount) * case when c.prices_include_tax then 1 else 1 + l.tax_rate / 100 end, 3)), 0) from public.contract_lines l where l.contract_id = c.id)
    from d join public.contracts c on c.id = d.id order by d.dd, c.contract_no;
end $$;

-- توليد الفواتير المستحقة لغاية تاريخ: كل عقد لحاله (العقد اللي بيفشل بيرجع بالأخطاء والباقي بيكمل)
drop function if exists public.contract_generate(uuid, date, uuid[]);
create or replace function public.contract_generate(p_company uuid, p_until date, p_ids uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.contracts; fy uuid; iid uuid; n int := 0; d date; nd date; sub numeric; tax numeric; dsc numeric; can_post boolean; per text; g int; k int;
        fails jsonb := '[]'::jsonb; posted int := 0; pp int;
begin
  if not public.can(p_company, 'contracts', 'add') or not public.can(p_company, 'sales_invoices', 'add') or not public.tenant_writable() then
    raise exception 'ما عندك صلاحية توليد فواتير العقود'; end if;
  can_post := public.can(p_company, 'sales_invoices', 'post');
  for c in select * from public.contracts where company_id = p_company and status = 'active' and next_date <= p_until
             and (p_ids is null or id = any (p_ids)) and public.dept_ok(company_id, department_id) order by next_date, contract_no loop
    begin
      perform 1 from public.contracts where id = c.id for update;
      if not exists (select 1 from public.contract_lines where contract_id = c.id) then raise exception 'العقد ما فيه سطور'; end if;
      if not exists (select 1 from public.parties where id = c.party_id and is_active) then raise exception 'العميل موقوف'; end if;
      g := 0; k := 0; pp := 0; nd := c.next_date;
      while nd <= p_until and (c.end_date is null or nd <= c.end_date) and g < 36 loop
        g := g + 1; d := nd;
        select id into fy from public.fiscal_years where company_id = p_company and d between start_date and end_date and not is_closed order by start_date desc limit 1;
        if fy is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ %', to_char(d, 'DD/MM/YYYY'); end if;
        per := to_char(d, 'YYYY-MM') || case when c.every_months > 1 then ' → ' || to_char((d + make_interval(months => c.every_months - 1))::date, 'YYYY-MM') else '' end;
        perform set_config('sumou.contract', public.internal_token(), true);
        insert into public.invoices (company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id, reference, notes, prices_include_tax,
                                     department_id, sales_rep_id, contract_id, contract_period)
        values (p_company, fy, 'sale', d, 'credit', c.party_id, 'عقد رقم ' || c.contract_no || ' — ' || per, c.title, c.prices_include_tax,
                c.department_id, c.sales_rep_id, c.id, per) returning id into iid;
        perform set_config('sumou.contract', '', true);
        insert into public.invoice_lines (invoice_id, line_no, item_id, description, qty, unit_price, discount, tax_rate, account_id, subtotal, tax_amount, line_total)
        select iid, l.line_no, l.item_id, coalesce(nullif(l.description, ''), it.name) || ' (' || per || ')', l.qty, l.unit_price, l.discount, l.tax_rate, it.sales_account_id,
               x.s, x.t, x.s + x.t
          from public.contract_lines l left join public.items it on it.id = l.item_id,
               lateral (select case when c.prices_include_tax then round((l.qty * l.unit_price - l.discount) / (1 + l.tax_rate / 100), 3) else round(l.qty * l.unit_price - l.discount, 3) end s) s0,
               lateral (select s0.s s, case when c.prices_include_tax then round(l.qty * l.unit_price - l.discount, 3) - s0.s else round(s0.s * l.tax_rate / 100, 3) end t) x
         where l.contract_id = c.id order by l.line_no;
        select coalesce(sum(subtotal), 0), coalesce(sum(tax_amount), 0), coalesce(sum(discount), 0) into sub, tax, dsc from public.invoice_lines where invoice_id = iid;
        update public.invoices set subtotal = sub, tax_total = tax, discount_total = dsc, total = sub + tax where id = iid;
        if c.auto_post and can_post then
          if public.posting_flag(p_company, 'sale', 'gl') then perform public.post_invoice(iid); pp := pp + 1; end if;
          if public.posting_flag(p_company, 'sale', 'stock') then perform public.post_invoice_stock(iid); end if;
        end if;
        k := k + 1;
        nd := (date_trunc('month', d) + make_interval(months => c.every_months))::date + (c.day_of_month - 1);
      end loop;
      perform set_config('sumou.contract', public.internal_token(), true);
      update public.contracts set next_date = nd, status = case when end_date is not null and nd > end_date then 'ended' else status end where id = c.id;
      perform set_config('sumou.contract', '', true);
      n := n + k; posted := posted + pp;
    exception when others then
      perform set_config('sumou.contract', '', true);
      fails := fails || jsonb_build_object('contract_no', c.contract_no, 'title', c.title, 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('made', n, 'posted', posted, 'failed', fails);
end $$;
revoke execute on function public.contract_due(uuid, date), public.contract_generate(uuid, date, uuid[]) from public, anon;
grant execute on function public.contract_due(uuid, date), public.contract_generate(uuid, date, uuid[]) to authenticated;

-- النسخة الاحتياطية: العقود قبل القيود والفواتير
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
   (12, 'party_doc_types', 'company_id = $1', 'code'),
   (13, 'parties', 'company_id = $1', 'code'),
   (14, 'party_documents', 'company_id = $1', 'party_id, expiry_date'),
   (15, 'sales_visits', 'company_id = $1', 'started_at'),
   (16, 'item_categories', 'company_id = $1', 'code'),
   (17, 'items', 'company_id = $1', 'code'),
   (18, 'item_batches', 'company_id = $1', 'item_id, batch_no'),
   (19, 'price_list_items', 'list_id in (select id from public.price_lists where company_id = $1)', 'list_id'),
   (20, 'promotions', 'company_id = $1', 'date_from'),
   (21, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (22, 'warehouses', 'company_id = $1', 'code'),
   (23, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (24, 'departments', 'company_id = $1', 'level, code'),
   (25, 'doc_types', 'company_id = $1', 'kind, code'),
   (26, 'doc_statuses', 'company_id = $1', 'kind, sort, code'),
   (27, 'boms', 'company_id = $1', 'code'),
   (28, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (29, 'work_locations', 'company_id = $1', 'name'),
   (30, 'work_shifts', 'company_id = $1', 'code'),
   (31, 'employees', 'company_id = $1', 'code'),
   (32, 'contracts', 'company_id = $1', 'contract_no'),
   (33, 'contract_lines', 'contract_id in (select id from public.contracts where company_id = $1)', 'contract_id, line_no'),
   (34, 'journal_entries', 'company_id = $1', 'created_at'),
   (35, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (36, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (37, 'invoices', 'company_id = $1', 'created_at'),
   (38, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (39, 'invoice_party_splits', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (40, 'invoice_allocations', 'company_id = $1', 'created_at'),
   (41, 'party_notes', 'company_id = $1', 'created_at'),
   (42, 'orders', 'company_id = $1', 'created_at'),
   (43, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (44, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (45, 'cheques', 'company_id = $1', 'created_at'),
   (46, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (47, 'supply_requests', 'company_id = $1', 'req_no'),
   (48, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (49, 'stock_docs', 'company_id = $1', 'created_at'),
   (50, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (51, 'stock_moves', 'company_id = $1', 'created_at'),
   (52, 'batch_moves', 'company_id = $1', 'created_at'),
   (53, 'landed_costs', 'company_id = $1', 'doc_no'),
   (54, 'landed_cost_invoices', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (55, 'landed_cost_charges', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id, line_no'),
   (56, 'landed_cost_allocs', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (57, 'productions', 'company_id = $1', 'prod_no'),
   (58, 'obligations', 'company_id = $1', 'due_date'),
   (59, 'recurring_entries', 'company_id = $1', 'created_at'),
   (60, 'budgets', 'company_id = $1', 'code'),
   (61, 'budget_lines', 'budget_id in (select id from public.budgets where company_id = $1)', 'budget_id'),
   (62, 'attendance', 'company_id = $1', 'day, employee_id'),
   (63, 'leave_types', 'company_id = $1', 'code'),
   (64, 'leave_requests', 'company_id = $1', 'req_no'),
   (65, 'payroll_runs', 'company_id = $1', 'period'),
   (66, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (67, 'employee_loans', 'company_id = $1', 'loan_no'),
   (68, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (69, 'asset_custodians', 'company_id = $1', 'code'),
   (70, 'fixed_assets', 'company_id = $1', 'code'),
   (71, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (72, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (73, 'asset_movements', 'company_id = $1', 'mov_no'),
   (74, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (75, 'custody_docs', 'company_id = $1', 'doc_no'),
   (76, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (77, 'bank_recons', 'company_id = $1', 'created_at'),
   (78, 'bank_cleared', 'company_id = $1', 'line_id'),
   (79, 'message_log', 'company_id = $1', 'sent_at'),
   (80, 'doc_follow', 'company_id = $1', 'updated_at'),
   (81, 'doc_follow_log', 'company_id = $1', 'set_at'),
   (82, 'attachments', 'company_id = $1', 'created_at'),
   (83, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
