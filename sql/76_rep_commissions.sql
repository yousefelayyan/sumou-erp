-- =====================================================================
--  السمو ERP — المرحلة 76: عمولات المندوبين بخطط وأهداف
--  commission_plans: أساس العمولة (صافي المبيعات أو التحصيل)، شرائح حسب نسبة تحقيق الهدف [{min_pct, rate}]،
--  نسبة بدون هدف، ومكافأة ثابتة عند نسبة معيّنة. lookups.commission_plan_id = خطة المندوب (بدونها بياخذ lookups.rate ثابتة).
--  rep_targets: هدف شهري لكل مندوب. rep_commissions(company, from, to): الحساب لكل مندوب وشهر (قراءة بس).
--  الصلاحية شاشة rep_commissions (قسم sales، أخذتها مرة وحدة المجموعات اللي إلها reports)، والمندوب المربوط بمستخدم بيشوف حاله.
-- =====================================================================
do $$ begin
  if to_regclass('public.commission_plans') is null then
    update public.user_groups set permissions = permissions || jsonb_build_object('rep_commissions', permissions -> 'reports')
     where permissions ? 'reports' and not permissions ? 'rep_commissions';
  end if;
end $$;

create or replace function public.screen_module(s text) returns text
language sql immutable as $$
  select case
    when s in ('customers','sales_invoices','sales_orders','pos','rep_visits','customer_notes','contracts','rep_commissions')  then 'sales'
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

create table if not exists public.commission_plans (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  code            text not null check (length(code) between 1 and 20),
  name            text not null check (length(name) between 1 and 120),
  basis           text not null default 'sales' check (basis in ('sales','collections')),
  tiers           jsonb not null default '[]'::jsonb check (jsonb_typeof(tiers) = 'array' and jsonb_array_length(tiers) <= 20),
  no_target_rate  numeric(6,3) not null default 0 check (no_target_rate between 0 and 100),
  bonus_at_pct    numeric(7,2) check (bonus_at_pct is null or bonus_at_pct > 0),
  bonus_amount    numeric(18,3) not null default 0 check (bonus_amount >= 0),
  is_active       boolean not null default true,
  notes           text,
  unique (company_id, code)
);
create table if not exists public.rep_targets (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  rep_id      uuid not null references public.lookups(id) on delete cascade,
  month       date not null check (extract(day from month) = 1),
  target      numeric(18,3) not null check (target >= 0),
  notes       text,
  unique (rep_id, month)
);
alter table public.lookups add column if not exists commission_plan_id uuid references public.commission_plans(id) on delete set null;

alter table public.commission_plans enable row level security;
alter table public.rep_targets enable row level security;
grant select, insert, update, delete on public.commission_plans, public.rep_targets to authenticated;
drop policy if exists cp_sel on public.commission_plans;
create policy cp_sel on public.commission_plans for select using (public.can(company_id, 'rep_commissions', 'view'));
drop policy if exists cp_wr on public.commission_plans;
create policy cp_wr on public.commission_plans for all using (public.can(company_id, 'rep_commissions', 'edit') and public.tenant_writable())
  with check (public.can(company_id, 'rep_commissions', 'edit') and public.tenant_writable());
drop policy if exists rt_sel on public.rep_targets;
create policy rt_sel on public.rep_targets for select using (public.can(company_id, 'rep_commissions', 'view')
  or exists (select 1 from public.lookups l where l.id = rep_id and l.user_id = auth.uid() and public.has_company(company_id)));
drop policy if exists rt_wr on public.rep_targets;
create policy rt_wr on public.rep_targets for all using (public.can(company_id, 'rep_commissions', 'edit') and public.tenant_writable())
  with check (public.can(company_id, 'rep_commissions', 'edit') and public.tenant_writable());

create or replace function public.ab_commission_checks() returns trigger
language plpgsql security definer set search_path = public as $$
declare t jsonb;
begin
  if tg_table_name = 'rep_targets' then
    if not exists (select 1 from public.lookups where id = new.rep_id and company_id = new.company_id and kind = 'sales_rep') then
      raise exception 'المندوب مش من نفس الشركة'; end if;
  elsif tg_table_name = 'commission_plans' then
    for t in select * from jsonb_array_elements(new.tiers) loop
      if jsonb_typeof(t -> 'min_pct') <> 'number' or jsonb_typeof(t -> 'rate') <> 'number'
         or (t ->> 'min_pct')::numeric < 0 or (t ->> 'rate')::numeric not between 0 and 100 then
        raise exception 'شرائح الخطة لازم تكون نسبة تحقيق (0 أو أكثر) ونسبة عمولة (0–100)'; end if;
    end loop;
  elsif tg_table_name = 'lookups' then
    if new.commission_plan_id is not null and (new.kind <> 'sales_rep'
       or not exists (select 1 from public.commission_plans where id = new.commission_plan_id and company_id = new.company_id)) then
      raise exception 'خطة العمولة لازم تكون لمندوب ومن نفس الشركة'; end if;
  end if;
  return new;
end $$;
drop trigger if exists ab_commission_checks on public.rep_targets;
create trigger ab_commission_checks before insert or update on public.rep_targets for each row execute function public.ab_commission_checks();
drop trigger if exists ab_commission_checks on public.commission_plans;
create trigger ab_commission_checks before insert or update on public.commission_plans for each row execute function public.ab_commission_checks();
drop trigger if exists ab_commission_plan_check on public.lookups;
create trigger ab_commission_plan_check before insert or update of commission_plan_id on public.lookups for each row execute function public.ab_commission_checks();
revoke execute on function public.ab_commission_checks() from public, anon, authenticated;

-- حساب العمولات لكل مندوب وشهر
create or replace function public.rep_commissions(p_company uuid, p_from date, p_to date)
returns table (rep_id uuid, month date, plan_id uuid, basis text, target numeric, sales numeric, returns numeric, net_sales numeric,
               collections numeric, base numeric, achieved_pct numeric, rate numeric, commission numeric, bonus numeric, total numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare own uuid[];
begin
  if p_to < p_from or p_to > p_from + 731 then raise exception 'الفترة مش صحيحة (لحد سنتين)'; end if;
  if not public.can(p_company, 'rep_commissions', 'view') then
    if not public.has_company(p_company) then raise exception 'ما عندك صلاحية'; end if;
    select array_agg(id) into own from public.lookups where company_id = p_company and kind = 'sales_rep' and user_id = auth.uid();
    if own is null then raise exception 'ما عندك صلاحية'; end if;
  end if;
  return query
  with reps as (
    select l.id, l.rate, l.commission_plan_id from public.lookups l
     where l.company_id = p_company and l.kind = 'sales_rep' and (own is null or l.id = any (own))),
  months as (select generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month')::date m),
  inv as (
    select coalesce(i.sales_rep_id, o.sales_rep_id) rep, date_trunc('month', i.inv_date)::date m, i.inv_type, i.subtotal
      from public.invoices i left join public.invoices o on o.id = i.original_invoice_id
     where i.company_id = p_company and i.status = 'posted' and i.inv_type in ('sale','sale_return')
       and i.inv_date between date_trunc('month', p_from)::date and (date_trunc('month', p_to) + interval '1 month - 1 day')::date
       and public.dept_ok(p_company, i.department_id)),
  col as (
    select i.sales_rep_id rep, date_trunc('month', e.entry_date)::date m, sum(a.amount) amt
      from public.invoice_allocations a join public.invoices i on i.id = a.invoice_id join public.journal_entries e on e.id = a.entry_id
     where a.company_id = p_company and i.inv_type = 'sale' and public.alloc_live(a.entry_id) and public.dept_ok(p_company, i.department_id)
       and e.entry_date between date_trunc('month', p_from)::date and (date_trunc('month', p_to) + interval '1 month - 1 day')::date
     group by 1, 2),
  base as (
    select r.id rep, mo.m, r.rate flat, p.id pid, coalesce(p.basis, 'sales') basis, p.tiers, p.no_target_rate, p.bonus_at_pct, p.bonus_amount,
           t.target,
           coalesce((select sum(subtotal) from inv where inv.rep = r.id and inv.m = mo.m and inv.inv_type = 'sale'), 0) s,
           coalesce((select sum(subtotal) from inv where inv.rep = r.id and inv.m = mo.m and inv.inv_type = 'sale_return'), 0) rt,
           coalesce((select amt from col where col.rep = r.id and col.m = mo.m), 0) c
      from reps r cross join months mo
      left join public.commission_plans p on p.id = r.commission_plan_id and p.is_active
      left join public.rep_targets t on t.rep_id = r.id and t.month = mo.m),
  calc as (
    select b.*, b.s - b.rt ns, case when b.basis = 'collections' then b.c else b.s - b.rt end bs from base b),
  pct as (
    select c.*, case when coalesce(c.target, 0) > 0 then round(c.bs * 100 / c.target, 2) end ach from calc c),
  rated as (
    select p.*,
      case when p.pid is null then coalesce(p.flat, 0)
           when p.ach is null then p.no_target_rate
           else coalesce((select (x ->> 'rate')::numeric from jsonb_array_elements(p.tiers) x
                           where (x ->> 'min_pct')::numeric <= p.ach order by (x ->> 'min_pct')::numeric desc limit 1), 0) end rt_pct,
      case when p.pid is not null and p.bonus_at_pct is not null and p.ach is not null and p.ach >= p.bonus_at_pct then p.bonus_amount else 0 end bn
      from pct p)
  select r.rep, r.m, r.pid, r.basis, r.target, round(r.s, 3), round(r.rt, 3), round(r.ns, 3), round(r.c, 3), round(r.bs, 3), r.ach, r.rt_pct,
         round(greatest(r.bs, 0) * r.rt_pct / 100, 3), r.bn, round(greatest(r.bs, 0) * r.rt_pct / 100, 3) + r.bn
    from rated r
   where r.s <> 0 or r.rt <> 0 or r.c <> 0 or r.target is not null
   order by r.m, r.rep;
end $$;
revoke execute on function public.rep_commissions(uuid, date, date) from public, anon;
grant execute on function public.rep_commissions(uuid, date, date) to authenticated;

-- النسخة الاحتياطية: الخطط قبل القوائم (المندوب بيأشّر عليها) والأهداف بعدها
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
   (8, 'commission_plans', 'company_id = $1', 'code'),
   (9, 'lookups', 'company_id = $1', 'parent_id nulls first, kind, code'),
   (10, 'rep_targets', 'company_id = $1', 'month, rep_id'),
   (11, 'custom_fields', 'company_id = $1', 'entity, sort'),
   (12, 'party_categories', 'company_id = $1', 'party_type, code'),
   (13, 'price_lists', 'company_id = $1', 'code'),
   (14, 'party_doc_types', 'company_id = $1', 'code'),
   (15, 'parties', 'company_id = $1', 'code'),
   (16, 'party_documents', 'company_id = $1', 'party_id, expiry_date'),
   (17, 'sales_visits', 'company_id = $1', 'started_at'),
   (18, 'item_categories', 'company_id = $1', 'code'),
   (19, 'items', 'company_id = $1', 'code'),
   (20, 'item_batches', 'company_id = $1', 'item_id, batch_no'),
   (21, 'price_list_items', 'list_id in (select id from public.price_lists where company_id = $1)', 'list_id'),
   (22, 'promotions', 'company_id = $1', 'date_from'),
   (23, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (24, 'warehouses', 'company_id = $1', 'code'),
   (25, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (26, 'departments', 'company_id = $1', 'level, code'),
   (27, 'doc_types', 'company_id = $1', 'kind, code'),
   (28, 'doc_statuses', 'company_id = $1', 'kind, sort, code'),
   (29, 'boms', 'company_id = $1', 'code'),
   (30, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (31, 'work_locations', 'company_id = $1', 'name'),
   (32, 'work_shifts', 'company_id = $1', 'code'),
   (33, 'employees', 'company_id = $1', 'code'),
   (34, 'contract_templates', 'company_id = $1', 'code'),
   (35, 'contracts', 'company_id = $1', 'contract_no'),
   (36, 'contract_lines', 'contract_id in (select id from public.contracts where company_id = $1)', 'contract_id, line_no'),
   (37, 'journal_entries', 'company_id = $1', 'created_at'),
   (38, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (39, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (40, 'invoices', 'company_id = $1', 'created_at'),
   (41, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (42, 'invoice_party_splits', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (43, 'invoice_allocations', 'company_id = $1', 'created_at'),
   (44, 'party_notes', 'company_id = $1', 'created_at'),
   (45, 'orders', 'company_id = $1', 'created_at'),
   (46, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (47, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (48, 'cheques', 'company_id = $1', 'created_at'),
   (49, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (50, 'supply_requests', 'company_id = $1', 'req_no'),
   (51, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (52, 'stock_docs', 'company_id = $1', 'created_at'),
   (53, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (54, 'stock_moves', 'company_id = $1', 'created_at'),
   (55, 'batch_moves', 'company_id = $1', 'created_at'),
   (56, 'landed_costs', 'company_id = $1', 'doc_no'),
   (57, 'landed_cost_invoices', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (58, 'landed_cost_charges', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id, line_no'),
   (59, 'landed_cost_allocs', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (60, 'productions', 'company_id = $1', 'prod_no'),
   (61, 'obligations', 'company_id = $1', 'due_date'),
   (62, 'recurring_entries', 'company_id = $1', 'created_at'),
   (63, 'budgets', 'company_id = $1', 'code'),
   (64, 'budget_lines', 'budget_id in (select id from public.budgets where company_id = $1)', 'budget_id'),
   (65, 'attendance', 'company_id = $1', 'day, employee_id'),
   (66, 'leave_types', 'company_id = $1', 'code'),
   (67, 'leave_requests', 'company_id = $1', 'req_no'),
   (68, 'payroll_runs', 'company_id = $1', 'period'),
   (69, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (70, 'employee_loans', 'company_id = $1', 'loan_no'),
   (71, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (72, 'asset_custodians', 'company_id = $1', 'code'),
   (73, 'fixed_assets', 'company_id = $1', 'code'),
   (74, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (75, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (76, 'asset_movements', 'company_id = $1', 'mov_no'),
   (77, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (78, 'custody_docs', 'company_id = $1', 'doc_no'),
   (79, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (80, 'bank_recons', 'company_id = $1', 'created_at'),
   (81, 'bank_cleared', 'company_id = $1', 'line_id'),
   (82, 'message_log', 'company_id = $1', 'sent_at'),
   (83, 'doc_follow', 'company_id = $1', 'updated_at'),
   (84, 'doc_follow_log', 'company_id = $1', 'set_at'),
   (85, 'attachments', 'company_id = $1', 'created_at'),
   (86, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
