-- =====================================================================
--  السمو ERP — المرحلة 68: الموظف على سطور القيود + ميزان مراجعة الموظفين
--  journal_lines.employee_id (اختياري، من نفس الشركة، ما بيجتمع مع party_id). سند القيد/القبض/الصرف بيختار الموظف،
--  وقيد الرواتب (post_payroll) بيسجّل الصافي والسلف لكل موظف لحاله، والمصروف = الإجمالي ناقص الخصومات الأخرى بسطر واحد.
--  rep_employee_tb(company, fy, account, from, to): لكل موظف رصيد أول المدة ومدين ودائن الفترة.
--  rep_employee_ledger(company, fy, account, employee, from, to): كشف حساب الموظف.
-- =====================================================================
-- بالنسخة الاحتياطية الموظفين صاروا قبل القيود (تحت)، فالمفتاح والفحص عاديين
alter table public.journal_lines add column if not exists employee_id uuid references public.employees(id);
create index if not exists jl_employee_idx on public.journal_lines (employee_id) where employee_id is not null;

create or replace function public.ad_jl_employee_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare ro uuid;
begin
  -- القيد العكسي (reverse_entry/reverse_internal/إلغاء المسيّر) بينسخ الموظف من سطر الأصل
  if tg_op = 'INSERT' and new.employee_id is null then
    select reversal_of into ro from public.journal_entries where id = new.entry_id;
    if ro is not null then
      select employee_id into new.employee_id from public.journal_lines where entry_id = ro and line_no = new.line_no and account_id = new.account_id limit 1;
    end if;
  end if;
  if new.employee_id is not null and new.party_id is not null then raise exception 'السطر يا إله عميل/مورد يا موظف، مش الاثنين'; end if;
  if new.employee_id is not null and (tg_op = 'INSERT' or new.employee_id is distinct from old.employee_id)
     and not exists (select 1 from public.employees em join public.journal_entries e on e.company_id = em.company_id where em.id = new.employee_id and e.id = new.entry_id) then
    raise exception 'الموظف مش من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists ad_jl_employee_check on public.journal_lines;
create trigger ad_jl_employee_check before insert or update on public.journal_lines for each row execute function public.ad_jl_employee_check();
drop trigger if exists zc_jl_employee_company on public.journal_lines;
drop function if exists public.zc_jl_employee_company();
revoke execute on function public.ad_jl_employee_check() from public, anon, authenticated;

create or replace function public.post_payroll(p_run uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare r public.payroll_runs; st public.company_settings; fy uuid; eid uuid; ln int := 0; s record; ln_chk record; descr text; d date;
begin
  select * into r from public.payroll_runs where id = p_run for update;
  if r.id is null then raise exception 'المسيّر مش موجود'; end if;
  if not public.can(r.company_id, 'payroll', 'post') then raise exception 'ما عندك صلاحية ترحيل الرواتب'; end if;
  if r.status <> 'draft' then raise exception 'المسيّر مرحّل من قبل'; end if;
  perform public.ensure_payroll_settings(r.company_id);
  select * into st from public.company_settings where company_id = r.company_id;
  if st.salaries_account_id is null or st.salaries_payable_account_id is null or st.ss_payable_account_id is null or st.ss_expense_account_id is null then
    raise exception 'حدّد حسابات الرواتب بشاشة «حسابات الربط»';
  end if;
  select coalesce(sum(gross),0) g, coalesce(sum(ss_employee),0) se, coalesce(sum(ss_employer),0) sr, coalesce(sum(income_tax),0) t,
         coalesce(sum(advances),0) a, coalesce(sum(other_ded),0) o, coalesce(sum(net),0) n, count(*) c into s
    from public.payroll_lines where run_id = p_run;
  if s.c = 0 or s.g <= 0 then raise exception 'المسيّر فاضي'; end if;
  -- «خصم السلف» لازم يغطي الأقساط المحجوزة لكل موظف
  select e.name, x.amt, coalesce(pl.advances, 0) adv into ln_chk from (select employee_id, sum(amount) amt from public.loan_installments where run_id = p_run and status = 'pending' group by employee_id) x
    join public.employees e on e.id = x.employee_id left join public.payroll_lines pl on pl.run_id = p_run and pl.employee_id = x.employee_id
   where coalesce(pl.advances, 0) + 0.0005 < x.amt limit 1;
  if ln_chk.name is not null then
    raise exception '«خصم السلف» للموظف % (%) أقل من أقساط القروض المستحقة (%)؛ عدّله أو أجّل القسط', ln_chk.name, ln_chk.adv, ln_chk.amt;
  end if;
  if s.t > 0 and st.wht_payable_account_id is null then raise exception 'حدّد حساب أمانات ضريبة الدخل'; end if;
  if s.a > 0 and st.advances_account_id is null then raise exception 'حدّد حساب ذمم/سلف الموظفين'; end if;
  d := r.run_date;
  select id into fy from public.fiscal_years where company_id = r.company_id and d between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ المسيّر'; end if;
  descr := 'رواتب شهر ' || r.period;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (r.company_id, fy, 'payroll', d, descr, 'رواتب ' || r.period, 'draft') returning id into eid;
  -- المصروف (حسب مركز كلفة الموظف)
  -- المصروف = الإجمالي ناقص الخصومات الأخرى (غياب/جزاءات/بدون راتب) — سطر واحد زي «إجمالي الدخل»
  for s in select e.cost_center_id cc, sum(l.gross - l.other_ded) g, sum(l.ss_employer) sr from public.payroll_lines l join public.employees e on e.id = l.employee_id
           where l.run_id = p_run group by 1 loop
    if s.g > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, cost_center_id) values (eid, ln, st.salaries_account_id, descr, s.g, 0, s.cc); end if;
    if s.sr > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, cost_center_id) values (eid, ln, st.ss_expense_account_id, 'حصة المنشأة بالضمان - ' || descr, s.sr, 0, s.cc); end if;
  end loop;
  select coalesce(sum(ss_employee),0) se, coalesce(sum(ss_employer),0) sr, coalesce(sum(income_tax),0) t, coalesce(sum(advances),0) a,
         coalesce(sum(other_ded),0) o, coalesce(sum(net),0) n into s from public.payroll_lines where run_id = p_run;
  if s.se + s.sr > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, st.ss_payable_account_id, 'اشتراكات الضمان - ' || descr, 0, s.se + s.sr); end if;
  if s.t > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, st.wht_payable_account_id, 'ضريبة دخل مقتطعة - ' || descr, 0, s.t); end if;
  -- السلف والصافي لكل موظف لحاله (employee_id) عشان ميزان مراجعة الموظفين
  for s in select l.employee_id emp, e.name nm, l.advances a, l.net n from public.payroll_lines l join public.employees e on e.id = l.employee_id
           where l.run_id = p_run order by e.code loop
    if s.a > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, employee_id) values (eid, ln, st.advances_account_id, 'خصم سلف ' || s.nm || ' - ' || descr, 0, s.a, s.emp); end if;
    if s.n > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, employee_id) values (eid, ln, st.salaries_payable_account_id, 'صافي راتب ' || s.nm || ' - ' || descr, 0, s.n, s.emp); end if;
  end loop;
  if (select sum(debit) - sum(credit) from public.journal_lines where entry_id = eid) <> 0 then raise exception 'قيد الرواتب مش متوازن'; end if;
  update public.journal_entries set status = 'posted', total = (select sum(debit) from public.journal_lines where entry_id = eid), posted_by = auth.uid(), posted_at = now() where id = eid;
  update public.payroll_runs set status = 'posted', entry_id = eid where id = p_run;
  -- الأقساط اللي انخصمت بهالمسيّر صارت مدفوعة (بالترتيب لحد مبلغ «خصم السلف» بالسطر)
  perform public.loan_mark_paid(p_run);
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details) values (auth.uid(), r.company_id, 'ترحيل', 'payroll', p_run::text, jsonb_build_object('period', r.period));
  return eid;
end $$;

create or replace function public.rep_employee_tb(p_company uuid, p_fy uuid, p_account uuid, p_from date, p_to date)
returns table (employee_id uuid, account_id uuid, open_debit numeric, open_credit numeric, period_debit numeric, period_credit numeric)
language plpgsql stable security definer set search_path = public as $$
declare dl uuid[];
begin
  if not (public.can(p_company, 'payroll', 'view') or public.can(p_company, 'reports', 'view')) then raise exception 'ما عندك صلاحية'; end if;
  dl := public.dept_allowed(p_company);
  return query
    select l.employee_id, l.account_id,
           coalesce(sum(l.debit) filter (where e.entry_date < p_from), 0), coalesce(sum(l.credit) filter (where e.entry_date < p_from), 0),
           coalesce(sum(l.debit) filter (where e.entry_date >= p_from), 0), coalesce(sum(l.credit) filter (where e.entry_date >= p_from), 0)
      from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
     where e.company_id = p_company and e.fiscal_year_id = p_fy and e.status in ('posted','reversed') and e.entry_date <= p_to
       and l.employee_id is not null and (p_account is null or l.account_id = p_account)
       and (dl is null or e.department_id = any (dl))
     group by l.employee_id, l.account_id;
end $$;
revoke execute on function public.rep_employee_tb(uuid, uuid, uuid, date, date) from public, anon;
grant execute on function public.rep_employee_tb(uuid, uuid, uuid, date, date) to authenticated;

create or replace function public.rep_employee_ledger(p_company uuid, p_fy uuid, p_account uuid, p_employee uuid, p_from date, p_to date)
returns table (entry_id uuid, entry_date date, entry_type text, entry_no int, doc_code text, description text, line_description text, reference text, account_id uuid, debit numeric, credit numeric)
language plpgsql stable security definer set search_path = public as $$
declare dl uuid[];
begin
  if not (public.can(p_company, 'payroll', 'view') or public.can(p_company, 'reports', 'view')) then raise exception 'ما عندك صلاحية'; end if;
  dl := public.dept_allowed(p_company);
  return query
    select e.id, e.entry_date, e.entry_type, e.entry_no, e.doc_code, e.description, l.description, e.reference, l.account_id, l.debit, l.credit
      from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
     where e.company_id = p_company and e.fiscal_year_id = p_fy and e.status in ('posted','reversed') and e.entry_date between p_from and p_to
       and l.employee_id = p_employee and (p_account is null or l.account_id = p_account)
       and (dl is null or e.department_id = any (dl))
     order by e.entry_date, e.created_at, l.line_no;
end $$;
revoke execute on function public.rep_employee_ledger(uuid, uuid, uuid, uuid, date, date) from public, anon;
grant execute on function public.rep_employee_ledger(uuid, uuid, uuid, uuid, date, date) to authenticated;

-- النسخة الاحتياطية: الموظفين (ومواقع العمل والمناوبات) قبل القيود عشان سطور القيود بتأشّر عليهم
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
   (32, 'journal_entries', 'company_id = $1', 'created_at'),
   (33, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (34, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (35, 'invoices', 'company_id = $1', 'created_at'),
   (36, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (37, 'invoice_allocations', 'company_id = $1', 'created_at'),
   (38, 'party_notes', 'company_id = $1', 'created_at'),
   (39, 'orders', 'company_id = $1', 'created_at'),
   (40, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (41, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (42, 'cheques', 'company_id = $1', 'created_at'),
   (43, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (44, 'supply_requests', 'company_id = $1', 'req_no'),
   (45, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (46, 'stock_docs', 'company_id = $1', 'created_at'),
   (47, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (48, 'stock_moves', 'company_id = $1', 'created_at'),
   (49, 'batch_moves', 'company_id = $1', 'created_at'),
   (50, 'landed_costs', 'company_id = $1', 'doc_no'),
   (51, 'landed_cost_invoices', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (52, 'landed_cost_charges', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id, line_no'),
   (53, 'landed_cost_allocs', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (54, 'productions', 'company_id = $1', 'prod_no'),
   (55, 'obligations', 'company_id = $1', 'due_date'),
   (56, 'recurring_entries', 'company_id = $1', 'created_at'),
   (57, 'budgets', 'company_id = $1', 'code'),
   (58, 'budget_lines', 'budget_id in (select id from public.budgets where company_id = $1)', 'budget_id'),
   (59, 'attendance', 'company_id = $1', 'day, employee_id'),
   (60, 'leave_types', 'company_id = $1', 'code'),
   (61, 'leave_requests', 'company_id = $1', 'req_no'),
   (62, 'payroll_runs', 'company_id = $1', 'period'),
   (63, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (64, 'employee_loans', 'company_id = $1', 'loan_no'),
   (65, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (66, 'asset_custodians', 'company_id = $1', 'code'),
   (67, 'fixed_assets', 'company_id = $1', 'code'),
   (68, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (69, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (70, 'asset_movements', 'company_id = $1', 'mov_no'),
   (71, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (72, 'custody_docs', 'company_id = $1', 'doc_no'),
   (73, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (74, 'bank_recons', 'company_id = $1', 'created_at'),
   (75, 'bank_cleared', 'company_id = $1', 'line_id'),
   (76, 'message_log', 'company_id = $1', 'sent_at'),
   (77, 'doc_follow', 'company_id = $1', 'updated_at'),
   (78, 'doc_follow_log', 'company_id = $1', 'set_at'),
   (79, 'attachments', 'company_id = $1', 'created_at'),
   (80, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
