-- =====================================================================
--  المرحلة 81: شيكات الضمان (أمانات)
--  شيك بتستلمه أو بتعطيه كضمان (عقد، مندوب، كفالة، مناقصة…): ما إله قيد بالحسابات.
--  الحالة: held (محفوظ عندنا للوارد / عند الطرف للصادر) → returned (انرجع) | converted (تسييل: صار شيك عادي بقيد) | cancelled
--  الصلاحيات من شاشة «محفظة الشيكات» (cheques): العرض view، الإضافة add، التعديل والحالة edit، الحذف delete، التسييل add.
-- =====================================================================

create table if not exists public.guarantee_cheques (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  doc_no       int not null,
  direction    text not null check (direction in ('in','out')),
  cheque_no    text not null check (length(cheque_no) between 1 and 40),
  bank_name    text,
  drawer_name  text,
  party_id     uuid references public.parties(id) on delete restrict,
  employee_id  uuid references public.employees(id) on delete restrict,
  amount       numeric(18,3) not null check (amount > 0),
  receive_date date not null default current_date,
  due_date     date,
  purpose      text,
  reference    text,
  expiry_date  date,               -- موعد إرجاع الضمان المتوقع
  status       text not null default 'held' check (status in ('held','returned','converted','cancelled')),
  status_date  date,
  status_note  text,
  cheque_id    uuid references public.cheques(id) on delete set null,
  department_id uuid references public.departments(id) on delete set null,
  notes        text,
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  updated_by   uuid,
  updated_at   timestamptz,
  unique (company_id, doc_no)
);
create index if not exists guarantee_cheques_co on public.guarantee_cheques (company_id, status, expiry_date);
create index if not exists guarantee_cheques_party on public.guarantee_cheques (party_id) where party_id is not null;

create or replace function public.ab_guarantee_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare sys boolean := coalesce(current_setting('sumou.guarantee', true) = public.internal_token(), false) or coalesce(public.is_internal(), false);
begin
  if tg_op = 'DELETE' then
    if old.status <> 'held' and not sys and exists (select 1 from public.companies where id = old.company_id) then
      raise exception 'شيك الضمان بعد ما انرجع أو تسيّل ما بينحذف'; end if;
    return old;
  end if;
  new.cheque_no := trim(new.cheque_no);
  if new.party_id is not null and not exists (select 1 from public.parties where id = new.party_id and company_id = new.company_id) then
    raise exception 'الطرف مش من هالشركة'; end if;
  if new.employee_id is not null and not exists (select 1 from public.employees where id = new.employee_id and company_id = new.company_id) then
    raise exception 'الموظف مش من هالشركة'; end if;
  if new.department_id is not null and not exists (select 1 from public.departments where id = new.department_id and company_id = new.company_id) then
    raise exception 'الدائرة مش من هالشركة'; end if;
  if tg_op = 'INSERT' then
    if not sys then
      new.status := 'held'; new.status_date := null; new.status_note := null; new.cheque_id := null;
      new.created_by := auth.uid(); new.created_at := now();
    end if;
    if new.doc_no is null then
      perform pg_advisory_xact_lock(hashtext('gch:' || new.company_id::text));
      select coalesce(max(doc_no), 0) + 1 into new.doc_no from public.guarantee_cheques where company_id = new.company_id;
    end if;
    return new;
  end if;
  new.company_id := old.company_id; new.created_by := old.created_by; new.created_at := old.created_at;
  if not sys then
    new.doc_no := old.doc_no; new.status := old.status; new.status_date := old.status_date; new.status_note := old.status_note; new.cheque_id := old.cheque_id;
    if old.status <> 'held' and (to_jsonb(new) - array['notes','updated_by','updated_at']) is distinct from (to_jsonb(old) - array['notes','updated_by','updated_at']) then
      raise exception 'شيك الضمان بعد ما انرجع أو تسيّل بتتعدّل ملاحظاته بس'; end if;
  end if;
  new.updated_by := auth.uid(); new.updated_at := now();
  return new;
end $$;
drop trigger if exists ab_guarantee_guard on public.guarantee_cheques;
create trigger ab_guarantee_guard before insert or update or delete on public.guarantee_cheques
  for each row execute function public.ab_guarantee_guard();

alter table public.guarantee_cheques enable row level security;
drop policy if exists gch_select on public.guarantee_cheques;
create policy gch_select on public.guarantee_cheques for select to authenticated using (public.can(company_id, 'cheques', 'view') and public.dept_ok(company_id, department_id));
drop policy if exists gch_insert on public.guarantee_cheques;
create policy gch_insert on public.guarantee_cheques for insert to authenticated with check (public.can(company_id, 'cheques', 'add') and public.dept_ok(company_id, department_id));
drop policy if exists gch_update on public.guarantee_cheques;
create policy gch_update on public.guarantee_cheques for update to authenticated
  using (public.can(company_id, 'cheques', 'edit') and public.dept_ok(company_id, department_id))
  with check (public.can(company_id, 'cheques', 'edit') and public.dept_ok(company_id, department_id));
drop policy if exists gch_delete on public.guarantee_cheques;
create policy gch_delete on public.guarantee_cheques for delete to authenticated using (public.can(company_id, 'cheques', 'delete') and public.dept_ok(company_id, department_id));
grant select, insert, update, delete on public.guarantee_cheques to authenticated;

-- تغيير الحالة: returned | cancelled | held (رجوع عن إرجاع/إلغاء)
create or replace function public.guarantee_set_status(p_id uuid, p_status text, p_date date default null, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare g public.guarantee_cheques;
begin
  select * into g from public.guarantee_cheques where id = p_id for update;
  if g.id is null then raise exception 'الشيك مش موجود'; end if;
  if not public.can(g.company_id, 'cheques', 'edit') or not public.tenant_writable() or not public.dept_ok(g.company_id, g.department_id) then raise exception 'ما عندك صلاحية'; end if;
  if p_status not in ('returned','cancelled','held') then raise exception 'الحالة مش صحيحة'; end if;
  if g.status = 'converted' then raise exception 'الشيك تسيّل وصار بمحفظة الشيكات'; end if;
  if p_status = 'held' and g.status = 'held' then return; end if;
  if p_status <> 'held' and g.status <> 'held' then raise exception 'الشيك مش محفوظ'; end if;
  perform set_config('sumou.guarantee', public.internal_token(), true);
  update public.guarantee_cheques set status = p_status,
    status_date = case when p_status = 'held' then null else coalesce(p_date, public.local_today()) end,
    status_note = case when p_status = 'held' then null else left(nullif(trim(p_note), ''), 300) end
   where id = p_id;
  perform set_config('sumou.guarantee', '', true);
end $$;

-- التسييل: بيصير شيك عادي بمحفظة الشيكات بقيده (register_cheque)
create or replace function public.guarantee_convert(p_id uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare g public.guarantee_cheques; ch uuid;
begin
  select * into g from public.guarantee_cheques where id = p_id for update;
  if g.id is null then raise exception 'الشيك مش موجود'; end if;
  if not public.can(g.company_id, 'cheques', 'edit') or not public.dept_ok(g.company_id, g.department_id) then raise exception 'ما عندك صلاحية'; end if;
  if g.status <> 'held' then raise exception 'الشيك مش محفوظ'; end if;
  ch := public.register_cheque(jsonb_build_object(
    'company_id', g.company_id, 'direction', g.direction, 'cheque_no', g.cheque_no, 'bank_name', g.bank_name,
    'issue_date', coalesce(nullif(p ->> 'date', ''), public.local_today()::text),
    'due_date', coalesce(nullif(p ->> 'due_date', ''), g.due_date::text, public.local_today()::text),
    'amount', g.amount, 'party_id', g.party_id, 'account_id', nullif(p ->> 'account_id', ''),
    'drawer_name', g.drawer_name, 'notes', coalesce(nullif(trim(p ->> 'notes'), ''), 'تسييل شيك ضمان رقم ' || g.doc_no)));
  perform set_config('sumou.guarantee', public.internal_token(), true);
  update public.guarantee_cheques set status = 'converted', cheque_id = ch,
    status_date = coalesce(nullif(p ->> 'date', '')::date, public.local_today()), status_note = left(nullif(trim(p ->> 'notes'), ''), 300)
   where id = p_id;
  perform set_config('sumou.guarantee', '', true);
  return ch;
end $$;

revoke execute on function public.ab_guarantee_guard() from public, anon, authenticated;
revoke execute on function public.guarantee_set_status(uuid, text, date, text), public.guarantee_convert(uuid, jsonb) from public, anon;
grant execute on function public.guarantee_set_status(uuid, text, date, text), public.guarantee_convert(uuid, jsonb) to authenticated;

-- النسخة الاحتياطية: بعد cheque_events
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
   (50, 'guarantee_cheques', 'company_id = $1', 'doc_no'),
   (51, 'supply_requests', 'company_id = $1', 'req_no'),
   (52, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (53, 'stock_docs', 'company_id = $1', 'created_at'),
   (54, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (55, 'stock_moves', 'company_id = $1', 'created_at'),
   (56, 'batch_moves', 'company_id = $1', 'created_at'),
   (57, 'landed_costs', 'company_id = $1', 'doc_no'),
   (58, 'landed_cost_invoices', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (59, 'landed_cost_charges', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id, line_no'),
   (60, 'landed_cost_allocs', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (61, 'productions', 'company_id = $1', 'prod_no'),
   (62, 'obligations', 'company_id = $1', 'due_date'),
   (63, 'recurring_entries', 'company_id = $1', 'created_at'),
   (64, 'budgets', 'company_id = $1', 'code'),
   (65, 'budget_lines', 'budget_id in (select id from public.budgets where company_id = $1)', 'budget_id'),
   (66, 'attendance', 'company_id = $1', 'day, employee_id'),
   (67, 'leave_types', 'company_id = $1', 'code'),
   (68, 'leave_requests', 'company_id = $1', 'req_no'),
   (69, 'payroll_runs', 'company_id = $1', 'period'),
   (70, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (71, 'employee_loans', 'company_id = $1', 'loan_no'),
   (72, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (73, 'asset_custodians', 'company_id = $1', 'code'),
   (74, 'fixed_assets', 'company_id = $1', 'code'),
   (75, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (76, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (77, 'asset_movements', 'company_id = $1', 'mov_no'),
   (78, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (79, 'custody_docs', 'company_id = $1', 'doc_no'),
   (80, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (81, 'bank_recons', 'company_id = $1', 'created_at'),
   (82, 'bank_cleared', 'company_id = $1', 'line_id'),
   (83, 'message_log', 'company_id = $1', 'sent_at'),
   (84, 'doc_follow', 'company_id = $1', 'updated_at'),
   (85, 'doc_follow_log', 'company_id = $1', 'set_at'),
   (86, 'attachments', 'company_id = $1', 'created_at'),
   (87, 'fiscal_periods', 'company_id = $1', 'start_date')
$$;

-- مرفقات شيك الضمان لمين إله الشيكات
create or replace function public.attachment_visible(p_company uuid, p_entity text) returns boolean
language sql stable security definer set search_path = public as $$
  select case p_entity when 'employee' then public.can(p_company, 'payroll', 'view')
                       when 'payroll'  then public.can(p_company, 'payroll', 'view')
                       when 'asset'    then public.can(p_company, 'fixed_assets', 'view')
                       when 'visit'    then public.can(p_company, 'rep_visits', 'view')
                       when 'guarantee_cheque' then public.can(p_company, 'cheques', 'view')
                       else public.has_company(p_company) end;
$$;
