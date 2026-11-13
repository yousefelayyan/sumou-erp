-- =====================================================================
--  المرحلة 91: صرف الرواتب (سند صرف تلقائي من المسيّر المرحّل) وشيكات الرواتب
--  payroll_pay(run, p jsonb): سند صرف واحد — السطر الأول دائن الصندوق/البنك (أو «شيكات صادرة» للشيكات)،
--  والباقي مدين «رواتب مستحقة» لكل موظف (employee_id) بصافي راتبه. الشيكات بتنعمل بمحفظة الشيكات (صادرة) لكل موظف.
--  payroll_payments بتسجّل مين انصرفله؛ الموظف ما بينصرفله مرتين إلا إذا السند انحذف أو انعكس.
-- =====================================================================
create table if not exists public.payroll_payments (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  run_id      uuid not null references public.payroll_runs(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete restrict,
  entry_id    uuid references public.journal_entries(id) on delete set null,
  cheque_id   uuid references public.cheques(id) on delete set null,
  amount      numeric(18,3) not null check (amount > 0),
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
create index if not exists payroll_payments_run on public.payroll_payments (run_id);
alter table public.payroll_payments enable row level security;
grant select on public.payroll_payments to authenticated;
drop policy if exists pp_select on public.payroll_payments;
create policy pp_select on public.payroll_payments for select to authenticated using (public.can(company_id, 'payroll', 'view'));

-- الصرف الفعّال = سنده موجود ومش معكوس
create or replace function public.payroll_paid_live(p_entry uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_entry is not null and exists (select 1 from public.journal_entries e where e.id = p_entry and e.status in ('draft','posted'));
$$;
revoke execute on function public.payroll_paid_live(uuid) from public, anon, authenticated;

-- حالة الصرف لكل موظف بالمسيّر
create or replace function public.payroll_pay_status(p_run uuid)
returns table (employee_id uuid, net numeric, paid boolean, entry_id uuid, doc_code text, entry_status text, cheque_no text)
language plpgsql stable security definer set search_path = public as $$
declare r public.payroll_runs;
begin
  select * into r from public.payroll_runs where id = p_run;
  if r.id is null or not public.can(r.company_id, 'payroll', 'view') then raise exception 'ما عندك صلاحية'; end if;
  return query
  select l.employee_id, l.net, pp.id is not null, pp.entry_id, e.doc_code, e.status, c.cheque_no
    from public.payroll_lines l
    left join lateral (select x.* from public.payroll_payments x where x.run_id = p_run and x.employee_id = l.employee_id and public.payroll_paid_live(x.entry_id)
                        order by x.created_at desc limit 1) pp on true
    left join public.journal_entries e on e.id = pp.entry_id
    left join public.cheques c on c.id = pp.cheque_id
   where l.run_id = p_run;
end $$;

create or replace function public.payroll_pay(p_run uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare r public.payroll_runs; st public.company_settings; d date := coalesce(nullif(p ->> 'date', '')::date, public.local_today());
  meth text := coalesce(p ->> 'method', 'account'); acc uuid := nullif(p ->> 'account_id', '')::uuid; fy uuid; eid uuid; ln int := 1;
  tot numeric := 0; x record; ch uuid; cq jsonb; emps uuid[]; post boolean; descr text; n int := 0;
begin
  select * into r from public.payroll_runs where id = p_run for update;
  if r.id is null then raise exception 'المسيّر مش موجود'; end if;
  if not (public.can(r.company_id, 'payroll', 'post') and public.can(r.company_id, 'payment_vouchers', 'add')) or not public.tenant_writable() then
    raise exception 'صرف الرواتب بدها صلاحية ترحيل الرواتب وإضافة سندات الصرف';
  end if;
  if r.status <> 'posted' then raise exception 'المسيّر لازم يكون مرحّل قبل الصرف'; end if;
  if meth not in ('account','cheques') then raise exception 'طريقة الصرف غلط'; end if;
  if meth = 'cheques' and not public.can(r.company_id, 'cheques', 'add') then raise exception 'ما عندك صلاحية إضافة شيكات'; end if;
  select * into st from public.company_settings where company_id = r.company_id;
  if st.salaries_payable_account_id is null then raise exception 'حدّد حساب الرواتب المستحقة بحسابات الربط'; end if;
  if meth = 'account' then
    if acc is null or not exists (select 1 from public.accounts where id = acc and company_id = r.company_id and not is_group and is_active) then
      raise exception 'اختار حساب الصندوق أو البنك';
    end if;
  else
    update public.company_settings s set cheques_out_account_id = coalesce(s.cheques_out_account_id,
      (select id from public.accounts where company_id = r.company_id and code = '2102' and not is_group)) where s.company_id = r.company_id;
    select cheques_out_account_id into acc from public.company_settings where company_id = r.company_id;
    if acc is null then raise exception 'حدّد حساب الشيكات الصادرة بحسابات الربط'; end if;
  end if;
  select id into fy from public.fiscal_years where company_id = r.company_id and d between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ الصرف'; end if;
  if p ? 'employees' and jsonb_typeof(p -> 'employees') = 'array' then
    select array_agg(v::uuid) into emps from jsonb_array_elements_text(p -> 'employees') v;
  end if;
  post := public.can(r.company_id, 'payment_vouchers', 'post');
  descr := 'صرف رواتب شهر ' || r.period;

  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (r.company_id, fy, 'payment', d, descr, 'رواتب ' || r.period, 'draft') returning id into eid;
  for x in select l.employee_id emp, l.net, em.name, em.code from public.payroll_lines l join public.employees em on em.id = l.employee_id
           where l.run_id = p_run and l.net > 0 and (emps is null or l.employee_id = any (emps))
             and not exists (select 1 from public.payroll_payments pp where pp.run_id = p_run and pp.employee_id = l.employee_id and public.payroll_paid_live(pp.entry_id))
           order by em.code loop
    ch := null;
    if meth = 'cheques' then
      select c into cq from jsonb_array_elements(coalesce(p -> 'cheques', '[]')) c where c ->> 'employee_id' = x.emp::text limit 1;
      if cq is null or nullif(trim(cq ->> 'cheque_no'), '') is null then raise exception 'اكتب رقم الشيك للموظف %', x.name; end if;
      insert into public.cheques (company_id, direction, cheque_no, bank_name, issue_date, due_date, amount, account_id, drawer_name, status, notes)
      values (r.company_id, 'out', trim(cq ->> 'cheque_no'), nullif(trim(coalesce(cq ->> 'bank_name', p ->> 'bank_name')), ''), d,
              coalesce(nullif(cq ->> 'due_date', '')::date, d), x.net, st.salaries_payable_account_id, x.name, 'issued', descr)
      returning id into ch;
      insert into public.cheque_events (cheque_id, action, event_date, entry_id) values (ch, 'إصدار', d, eid);
    end if;
    ln := ln + 1; tot := tot + x.net; n := n + 1;
    insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, employee_id)
    values (eid, ln, st.salaries_payable_account_id, 'صافي راتب ' || x.name || ' - ' || r.period || case when ch is not null then ' - شيك ' || (cq ->> 'cheque_no') else '' end, x.net, 0, x.emp);
    insert into public.payroll_payments (company_id, run_id, employee_id, entry_id, cheque_id, amount) values (r.company_id, p_run, x.emp, eid, ch, x.net);
  end loop;
  if n = 0 then raise exception 'ما في رواتب لسا ما انصرفت بهالمسيّر'; end if;
  insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit)
  values (eid, 1, acc, descr || case when meth = 'cheques' then ' (شيكات)' else '' end, 0, tot);
  update public.journal_entries set total = tot,
    status = case when post then 'posted' else 'draft' end, posted_by = case when post then auth.uid() end, posted_at = case when post then now() end
   where id = eid;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), r.company_id, 'صرف رواتب', 'payroll', p_run::text, jsonb_build_object('entry', eid, 'count', n, 'total', tot, 'method', meth));
  return eid;
end $$;

-- إلغاء مسيّر انصرفت رواتبه ممنوع (لازم يتلغى سند الصرف أول)
create or replace function public.ab_payroll_paid_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'posted' and new.status <> 'posted'
     and exists (select 1 from public.payroll_payments pp where pp.run_id = old.id and public.payroll_paid_live(pp.entry_id)) then
    raise exception 'رواتب هالمسيّر انصرفت بسند صرف؛ احذف أو اعكس سند الصرف قبل إلغاء المسيّر';
  end if;
  return new;
end $$;
drop trigger if exists ab_payroll_paid_guard on public.payroll_runs;
create trigger ab_payroll_paid_guard before update on public.payroll_runs for each row execute function public.ab_payroll_paid_guard();
revoke execute on function public.ab_payroll_paid_guard() from public, anon, authenticated;

revoke execute on function public.payroll_pay(uuid, jsonb), public.payroll_pay_status(uuid) from public, anon;
grant execute on function public.payroll_pay(uuid, jsonb), public.payroll_pay_status(uuid) to authenticated;

-- النسخة الاحتياطية: مدفوعات الرواتب بعد سطور المسيّر (آخر تعريف بالمرحلة 91)
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
   (20, 'item_barcodes', 'company_id = $1', 'item_id, barcode'),
   (21, 'item_batches', 'company_id = $1', 'item_id, batch_no'),
   (22, 'price_list_items', 'list_id in (select id from public.price_lists where company_id = $1)', 'list_id'),
   (23, 'promotions', 'company_id = $1', 'date_from'),
   (24, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (25, 'warehouses', 'company_id = $1', 'code'),
   (26, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (27, 'departments', 'company_id = $1', 'level, code'),
   (28, 'doc_types', 'company_id = $1', 'kind, code'),
   (29, 'doc_statuses', 'company_id = $1', 'kind, sort, code'),
   (30, 'boms', 'company_id = $1', 'code'),
   (31, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (32, 'work_locations', 'company_id = $1', 'name'),
   (33, 'work_shifts', 'company_id = $1', 'code'),
   (34, 'employees', 'company_id = $1', 'code'),
   (35, 'contract_templates', 'company_id = $1', 'code'),
   (36, 'contracts', 'company_id = $1', 'contract_no'),
   (37, 'contract_lines', 'contract_id in (select id from public.contracts where company_id = $1)', 'contract_id, line_no'),
   (38, 'journal_entries', 'company_id = $1', 'created_at'),
   (39, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (40, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (41, 'invoices', 'company_id = $1', 'created_at'),
   (42, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (43, 'invoice_party_splits', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (44, 'invoice_allocations', 'company_id = $1', 'created_at'),
   (45, 'party_notes', 'company_id = $1', 'created_at'),
   (46, 'orders', 'company_id = $1', 'created_at'),
   (47, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (48, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (49, 'cheques', 'company_id = $1', 'created_at'),
   (50, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (51, 'guarantee_cheques', 'company_id = $1', 'doc_no'),
   (52, 'supply_requests', 'company_id = $1', 'req_no'),
   (53, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (54, 'stock_docs', 'company_id = $1', 'created_at'),
   (55, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (56, 'stock_moves', 'company_id = $1', 'created_at'),
   (57, 'batch_moves', 'company_id = $1', 'created_at'),
   (58, 'serial_moves', 'company_id = $1', 'created_at'),
   (59, 'landed_costs', 'company_id = $1', 'doc_no'),
   (60, 'landed_cost_invoices', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (61, 'landed_cost_charges', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id, line_no'),
   (62, 'landed_cost_allocs', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (63, 'productions', 'company_id = $1', 'prod_no'),
   (64, 'obligations', 'company_id = $1', 'due_date'),
   (65, 'recurring_entries', 'company_id = $1', 'created_at'),
   (66, 'budgets', 'company_id = $1', 'code'),
   (67, 'budget_lines', 'budget_id in (select id from public.budgets where company_id = $1)', 'budget_id'),
   (68, 'attendance', 'company_id = $1', 'day, employee_id'),
   (69, 'leave_types', 'company_id = $1', 'code'),
   (70, 'leave_requests', 'company_id = $1', 'req_no'),
   (71, 'payroll_runs', 'company_id = $1', 'period'),
   (72, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (73, 'payroll_payments', 'company_id = $1', 'created_at'),
   (74, 'employee_loans', 'company_id = $1', 'loan_no'),
   (75, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (76, 'asset_custodians', 'company_id = $1', 'code'),
   (77, 'fixed_assets', 'company_id = $1', 'code'),
   (78, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (79, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (80, 'asset_movements', 'company_id = $1', 'mov_no'),
   (81, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (82, 'custody_docs', 'company_id = $1', 'doc_no'),
   (83, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (84, 'bank_recons', 'company_id = $1', 'created_at'),
   (85, 'bank_cleared', 'company_id = $1', 'line_id'),
   (86, 'message_log', 'company_id = $1', 'sent_at'),
   (87, 'doc_follow', 'company_id = $1', 'updated_at'),
   (88, 'doc_follow_log', 'company_id = $1', 'set_at'),
   (89, 'attachments', 'company_id = $1', 'created_at'),
   (90, 'fiscal_periods', 'company_id = $1', 'start_date')
$$;
