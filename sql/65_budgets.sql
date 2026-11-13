-- =====================================================================
--  السمو ERP — المرحلة 65: الموازنات التقديرية ومقارنتها بالفعلي
--  budgets (لكل سنة مالية، رمز، اسم، دائرة/مركز كلفة اختياري، draft/approved) و budget_lines
--  (حساب فرعي + 12 شهر من بداية السنة المالية). الكتابة مباشرة بصلاحية شاشة budgets، والمعتمدة مقفولة
--  (الاعتماد/فكه من budget_set_status بصلاحية post). budget_vs_actual(budget): الموازنة والفعلي لكل حساب ولكل شهر
--  (القيود المرحّلة بدون الإغلاق؛ الإيرادات/الالتزامات/حقوق الملكية دائن−مدين والباقي مدين−دائن؛ فلتر دائرة الموازنة
--  وفروعها ومركز الكلفة؛ موظف الفرع فرعه بس). budget_fill(budget, pct, replace): تعبئة من فعلي السنة السابقة ± نسبة.
-- =====================================================================
do $$ begin
  if to_regclass('public.budgets') is null then   -- مرة وحدة: اللي إله سندات القيد بياخذ نفس الصلاحية على الموازنات
    update public.user_groups set permissions = permissions || jsonb_build_object('budgets', permissions -> 'journal_entries')
     where permissions ? 'journal_entries' and not permissions ? 'budgets';
  end if;
end $$;

create table if not exists public.budgets (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  fiscal_year_id  uuid not null references public.fiscal_years(id) on delete cascade,
  code            text not null check (length(code) between 1 and 20),
  name            text not null check (length(name) between 1 and 120),
  department_id   uuid references public.departments(id) on delete set null,
  cost_center_id  uuid references public.cost_centers(id) on delete set null,
  status          text not null default 'draft' check (status in ('draft','approved')),
  notes           text,
  approved_by     uuid,
  approved_at     timestamptz,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_by      uuid,
  updated_at      timestamptz,
  unique (company_id, fiscal_year_id, code)
);
create table if not exists public.budget_lines (
  id          uuid primary key default gen_random_uuid(),
  budget_id   uuid not null references public.budgets(id) on delete cascade,
  account_id  uuid not null references public.accounts(id) on delete cascade,
  amounts     numeric(18,3)[] not null default array_fill(0::numeric, array[12]),
  notes       text,
  unique (budget_id, account_id),
  check (array_length(amounts, 1) = 12 and array_ndims(amounts) = 1)
);
-- المفاتيح: حذف الحساب بيمسح سطره بالموازنة، وحذف الدائرة/المركز بيفضّيه (عشان حذف الشركة المتسلسل يمشي)
do $$ declare r record; want "char"; begin
  for r in select c.conname, c.conrelid::regclass t, a.attname col, c.confrelid::regclass ref, c.confdeltype dt from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
            where c.contype = 'f' and c.conrelid in ('public.budgets'::regclass, 'public.budget_lines'::regclass)
              and a.attname in ('department_id','cost_center_id','account_id') loop
    want := case r.col when 'account_id' then 'c' else 'n' end;
    if r.dt <> want then
      execute format('alter table %s drop constraint %I', r.t, r.conname);
      execute format('alter table %s add constraint %I foreign key (%I) references %s(id) on delete %s', r.t, r.conname, r.col, r.ref, case want when 'c' then 'cascade' else 'set null' end);
    end if;
  end loop;
end $$;
create index if not exists budget_lines_budget_idx on public.budget_lines (budget_id);
grant select, insert, update, delete on public.budgets, public.budget_lines to authenticated;

alter table public.budgets enable row level security;
alter table public.budget_lines enable row level security;
create or replace function public.budget_dept_ok(p_company uuid, p_dept uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.dept_allowed(p_company) is null or coalesce(p_dept = any (public.dept_allowed(p_company)), false);
$$;
grant execute on function public.budget_dept_ok(uuid, uuid) to authenticated;
drop policy if exists budgets_sel on public.budgets;
create policy budgets_sel on public.budgets for select using (public.can(company_id, 'budgets', 'view') and public.budget_dept_ok(company_id, department_id));
drop policy if exists budgets_ins on public.budgets;
create policy budgets_ins on public.budgets for insert
  with check (public.can(company_id, 'budgets', 'add') and public.tenant_writable() and public.budget_dept_ok(company_id, department_id));
drop policy if exists budgets_upd on public.budgets;
create policy budgets_upd on public.budgets for update
  using (public.can(company_id, 'budgets', 'edit') and public.tenant_writable() and public.budget_dept_ok(company_id, department_id))
  with check (public.can(company_id, 'budgets', 'edit') and public.tenant_writable() and public.budget_dept_ok(company_id, department_id));
drop policy if exists budgets_del on public.budgets;
create policy budgets_del on public.budgets for delete
  using (public.can(company_id, 'budgets', 'delete') and public.tenant_writable() and status = 'draft' and public.budget_dept_ok(company_id, department_id));
drop policy if exists budget_lines_sel on public.budget_lines;
create policy budget_lines_sel on public.budget_lines for select
  using (exists (select 1 from public.budgets b where b.id = budget_id and public.can(b.company_id, 'budgets', 'view') and public.budget_dept_ok(b.company_id, b.department_id)));
drop policy if exists budget_lines_wr on public.budget_lines;
create policy budget_lines_wr on public.budget_lines for all
  using (exists (select 1 from public.budgets b where b.id = budget_id and b.status = 'draft' and public.can(b.company_id, 'budgets', 'edit') and public.tenant_writable() and public.budget_dept_ok(b.company_id, b.department_id)))
  with check (exists (select 1 from public.budgets b where b.id = budget_id and b.status = 'draft' and public.can(b.company_id, 'budgets', 'edit') and public.tenant_writable() and public.budget_dept_ok(b.company_id, b.department_id)));

-- الحماية: الشركة والسنة ثابتين، السنة والدائرة ومركز الكلفة من نفس الشركة، والحالة من الدالة بس
create or replace function public.ab_budget_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    new.company_id := old.company_id; new.fiscal_year_id := old.fiscal_year_id; new.created_by := old.created_by; new.created_at := old.created_at;
    if not public.is_internal() then
      new.status := old.status; new.approved_by := old.approved_by; new.approved_at := old.approved_at;
      -- حذف الدائرة/مركز الكلفة بيفضّيهم (set null) حتى بالمعتمدة
      if old.status = 'approved' and not ((new.department_id is null and old.department_id is not null and not exists (select 1 from public.departments where id = old.department_id))
                                          or (new.cost_center_id is null and old.cost_center_id is not null and not exists (select 1 from public.cost_centers where id = old.cost_center_id))) then
        raise exception 'الموازنة معتمدة — فك الاعتماد أول'; end if;
    end if;
    new.updated_by := auth.uid(); new.updated_at := now();
  else
    if not public.is_internal() then new.status := 'draft'; new.approved_by := null; new.approved_at := null; new.created_by := auth.uid(); new.created_at := now(); end if;
  end if;
  if not exists (select 1 from public.fiscal_years where id = new.fiscal_year_id and company_id = new.company_id) then raise exception 'السنة المالية مش من نفس الشركة'; end if;
  if new.department_id is not null and not exists (select 1 from public.departments where id = new.department_id and company_id = new.company_id) then raise exception 'الدائرة مش من نفس الشركة'; end if;
  if new.cost_center_id is not null and not exists (select 1 from public.cost_centers where id = new.cost_center_id and company_id = new.company_id) then raise exception 'مركز الكلفة مش من نفس الشركة'; end if;
  new.code := trim(new.code); new.name := trim(new.name);
  return new;
end $$;
drop trigger if exists ab_budget_guard on public.budgets;
create trigger ab_budget_guard before insert or update on public.budgets for each row execute function public.ab_budget_guard();

create or replace function public.ab_budget_line_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare b public.budgets;
begin
  if tg_op = 'UPDATE' then new.budget_id := old.budget_id; end if;
  select * into b from public.budgets where id = coalesce(new.budget_id, old.budget_id);
  if b.id is null then return case when tg_op = 'DELETE' then old else new end; end if;
  if b.status = 'approved' and not public.is_internal() then raise exception 'الموازنة معتمدة — فك الاعتماد أول'; end if;
  if tg_op = 'DELETE' then return old; end if;
  if not exists (select 1 from public.accounts where id = new.account_id and company_id = b.company_id and not is_group) then
    raise exception 'الحساب لازم يكون فرعي ومن نفس الشركة'; end if;
  new.amounts := (select array_agg(round(coalesce(x, 0), 3) order by n) from unnest(new.amounts) with ordinality u(x, n));
  return new;
end $$;
drop trigger if exists ab_budget_line_guard on public.budget_lines;
create trigger ab_budget_line_guard before insert or update or delete on public.budget_lines for each row execute function public.ab_budget_line_guard();
revoke execute on function public.ab_budget_guard(), public.ab_budget_line_guard() from public, anon, authenticated;

-- حفظ كل سطور الموازنة دفعة وحدة (يا كلها يا ولا شي)
create or replace function public.budget_save_lines(p_budget uuid, p_lines jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare b public.budgets; n int;
begin
  select * into b from public.budgets where id = p_budget for update;
  if b.id is null or not public.can(b.company_id, 'budgets', 'edit') or not public.tenant_writable() or not public.budget_dept_ok(b.company_id, b.department_id) then
    raise exception 'ما عندك صلاحية'; end if;
  if b.status <> 'draft' then raise exception 'الموازنة معتمدة — فك الاعتماد أول'; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) > 2000 then raise exception 'سطور غلط'; end if;
  delete from public.budget_lines where budget_id = p_budget;
  insert into public.budget_lines (budget_id, account_id, amounts)
  select p_budget, (x->>'account_id')::uuid, array(select coalesce(nullif(v, 'null')::numeric, 0) from jsonb_array_elements_text(x->'amounts') v)
    from jsonb_array_elements(p_lines) x;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.budget_save_lines(uuid, jsonb) from public, anon;
grant execute on function public.budget_save_lines(uuid, jsonb) to authenticated;

-- الاعتماد وفكه
create or replace function public.budget_set_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare b public.budgets;
begin
  select * into b from public.budgets where id = p_id for update;
  if b.id is null then raise exception 'الموازنة مش موجودة'; end if;
  if not public.can(b.company_id, 'budgets', 'post') or not public.tenant_writable() or not public.budget_dept_ok(b.company_id, b.department_id) then
    raise exception 'ما عندك صلاحية اعتماد الموازنات'; end if;
  if p_status not in ('draft','approved') then raise exception 'حالة غير معروفة'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.budgets set status = p_status,
         approved_by = case when p_status = 'approved' then auth.uid() end, approved_at = case when p_status = 'approved' then now() end
   where id = p_id;
  perform set_config('sumou.internal', '', true);
end $$;
revoke execute on function public.budget_set_status(uuid, text) from public, anon;
grant execute on function public.budget_set_status(uuid, text) to authenticated;

-- الفعلي لكل حساب ولكل شهر من شهور السنة (1..12)، بفلاتر الموازنة (داخلية)
drop function if exists public.budget_actual_rows(uuid, date, uuid, uuid);
create or replace function public.budget_actual_rows(p_company uuid, p_from date, p_to date, p_dept uuid, p_cc uuid)
returns table (account_id uuid, mon int, amount numeric)
language sql stable security definer set search_path = public as $$
  with recursive dt as (
    select id from public.departments where id = p_dept and company_id = p_company
    union select d.id from public.departments d join dt on d.parent_id = dt.id where d.company_id = p_company),
  dl as (select public.dept_allowed(p_company) a)
  select l.account_id,
         (extract(year from age(date_trunc('month', e.entry_date), date_trunc('month', p_from))) * 12
          + extract(month from age(date_trunc('month', e.entry_date), date_trunc('month', p_from))))::int + 1,
         sum(case when a.category in ('revenue','liabilities','equity') then l.credit - l.debit else l.debit - l.credit end)
    from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id, dl
   where e.company_id = p_company and e.status = 'posted' and e.entry_type not in ('closing','opening')
     and e.entry_date >= p_from and e.entry_date <= p_to
     and (p_dept is null or e.department_id in (select id from dt))
     and (p_cc is null or l.cost_center_id = p_cc)
     and (dl.a is null or e.department_id = any (dl.a))
   group by 1, 2;
$$;
revoke execute on function public.budget_actual_rows(uuid, date, date, uuid, uuid) from public, anon, authenticated;

-- الموازنة مقابل الفعلي: سطر لكل حساب × شهر (حسابات الموازنة + أي حساب إيرادات/مصاريف إله فعلي)
create or replace function public.budget_vs_actual(p_budget uuid)
returns table (account_id uuid, mon int, budget numeric, actual numeric)
language plpgsql stable security definer set search_path = public as $$
declare b public.budgets; f public.fiscal_years;
begin
  select * into b from public.budgets where id = p_budget;
  if b.id is null or not public.can(b.company_id, 'budgets', 'view') or not public.budget_dept_ok(b.company_id, b.department_id) then
    raise exception 'ما عندك صلاحية'; end if;
  select * into f from public.fiscal_years where id = b.fiscal_year_id;
  return query
    with bud as (select bl.account_id, u.n::int mon, u.x amt from public.budget_lines bl, unnest(bl.amounts) with ordinality u(x, n) where bl.budget_id = p_budget),
    act as (select r.account_id, r.mon, r.amount from public.budget_actual_rows(b.company_id, f.start_date, f.end_date, b.department_id, b.cost_center_id) r
             where r.mon between 1 and 12
               and (r.account_id in (select x.account_id from bud x)
                    or exists (select 1 from public.accounts a where a.id = r.account_id and a.category in ('revenue','expenses'))))
    select coalesce(x.account_id, y.account_id), coalesce(x.mon, y.mon), coalesce(x.amt, 0)::numeric, coalesce(y.amount, 0)::numeric
      from bud x full join act y on y.account_id = x.account_id and y.mon = x.mon;
end $$;
revoke execute on function public.budget_vs_actual(uuid) from public, anon;
grant execute on function public.budget_vs_actual(uuid) to authenticated;

-- تعبئة من فعلي السنة السابقة (إيرادات ومصاريف) ± نسبة
create or replace function public.budget_fill(p_budget uuid, p_pct numeric default 0, p_replace boolean default false) returns int
language plpgsql security definer set search_path = public as $$
declare b public.budgets; f public.fiscal_years; pf public.fiscal_years; n int;
begin
  select * into b from public.budgets where id = p_budget for update;
  if b.id is null or not public.can(b.company_id, 'budgets', 'edit') or not public.tenant_writable() or not public.budget_dept_ok(b.company_id, b.department_id) then
    raise exception 'ما عندك صلاحية'; end if;
  if b.status <> 'draft' then raise exception 'الموازنة معتمدة — فك الاعتماد أول'; end if;
  if coalesce(p_pct, 0) < -100 or coalesce(p_pct, 0) > 1000 then raise exception 'النسبة لازم بين -100 و 1000'; end if;
  select * into f from public.fiscal_years where id = b.fiscal_year_id;
  select * into pf from public.fiscal_years where company_id = b.company_id and end_date < f.start_date order by end_date desc limit 1;
  if pf.id is null then raise exception 'ما في سنة مالية سابقة'; end if;
  if p_replace then delete from public.budget_lines where budget_id = p_budget; end if;
  create temp table if not exists _bud_act (account_id uuid, mon int, amount numeric) on commit drop;
  delete from _bud_act;
  insert into _bud_act select * from public.budget_actual_rows(b.company_id, pf.start_date, pf.end_date, b.department_id, b.cost_center_id) r where r.mon between 1 and 12;
  insert into public.budget_lines (budget_id, account_id, amounts)
  select p_budget, a.id,
         (select array_agg(round(coalesce(x.amount, 0) * (1 + coalesce(p_pct, 0) / 100), 3) order by g)
            from generate_series(1, 12) g left join _bud_act x on x.account_id = a.id and x.mon = g)
    from public.accounts a
   where a.id in (select account_id from _bud_act) and a.company_id = b.company_id and a.category in ('revenue','expenses') and not a.is_group
  on conflict (budget_id, account_id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.budget_fill(uuid, numeric, boolean) from public, anon;
grant execute on function public.budget_fill(uuid, numeric, boolean) to authenticated;

-- النسخة الاحتياطية: الموازنات بعد القيود المتكررة
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
   (29, 'journal_entries', 'company_id = $1', 'created_at'),
   (30, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (31, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (32, 'invoices', 'company_id = $1', 'created_at'),
   (33, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (34, 'invoice_allocations', 'company_id = $1', 'created_at'),
   (35, 'orders', 'company_id = $1', 'created_at'),
   (36, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (37, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (38, 'cheques', 'company_id = $1', 'created_at'),
   (39, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (40, 'supply_requests', 'company_id = $1', 'req_no'),
   (41, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (42, 'stock_docs', 'company_id = $1', 'created_at'),
   (43, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (44, 'stock_moves', 'company_id = $1', 'created_at'),
   (45, 'batch_moves', 'company_id = $1', 'created_at'),
   (46, 'landed_costs', 'company_id = $1', 'doc_no'),
   (47, 'landed_cost_invoices', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (48, 'landed_cost_charges', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id, line_no'),
   (49, 'landed_cost_allocs', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (50, 'productions', 'company_id = $1', 'prod_no'),
   (51, 'obligations', 'company_id = $1', 'due_date'),
   (52, 'recurring_entries', 'company_id = $1', 'created_at'),
   (53, 'budgets', 'company_id = $1', 'code'),
   (54, 'budget_lines', 'budget_id in (select id from public.budgets where company_id = $1)', 'budget_id'),
   (55, 'work_locations', 'company_id = $1', 'name'),
   (56, 'work_shifts', 'company_id = $1', 'code'),
   (57, 'employees', 'company_id = $1', 'code'),
   (58, 'attendance', 'company_id = $1', 'day, employee_id'),
   (59, 'leave_types', 'company_id = $1', 'code'),
   (60, 'leave_requests', 'company_id = $1', 'req_no'),
   (61, 'payroll_runs', 'company_id = $1', 'period'),
   (62, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (63, 'employee_loans', 'company_id = $1', 'loan_no'),
   (64, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (65, 'asset_custodians', 'company_id = $1', 'code'),
   (66, 'fixed_assets', 'company_id = $1', 'code'),
   (67, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (68, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (69, 'asset_movements', 'company_id = $1', 'mov_no'),
   (70, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (71, 'custody_docs', 'company_id = $1', 'doc_no'),
   (72, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (73, 'bank_recons', 'company_id = $1', 'created_at'),
   (74, 'bank_cleared', 'company_id = $1', 'line_id'),
   (75, 'message_log', 'company_id = $1', 'sent_at'),
   (76, 'doc_follow', 'company_id = $1', 'updated_at'),
   (77, 'doc_follow_log', 'company_id = $1', 'set_at'),
   (78, 'attachments', 'company_id = $1', 'created_at'),
   (79, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
