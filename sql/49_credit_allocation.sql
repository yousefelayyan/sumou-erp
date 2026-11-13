-- =====================================================================
--  السمو ERP — المرحلة 49: سقف الائتمان + توزيع الدفعات على الفواتير
--  company_settings.credit_limit_mode: 'warn' (تنبيه بالواجهة) | 'block' (منع ترحيل الفاتورة الآجلة فوق السقف)
--  صلاحية تجاوز السقف: شاشة credit_override (edit) أو المدير.
--  invoice_allocations: دفعة (سند قبض/صرف/قيد) ↔ فاتورة آجلة، بالمبلغ. الكتابة من الدوال بس.
-- =====================================================================
alter table public.company_settings add column if not exists credit_limit_mode text not null default 'warn';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'cs_credit_limit_mode_chk') then
    alter table public.company_settings add constraint cs_credit_limit_mode_chk check (credit_limit_mode in ('warn','block'));
  end if;
end $$;

-- رصيد الطرف (مرحّل) بسنة الفاتورة
-- رصيد الطرف التراكمي (كل السنين): قيود الإغلاق والأرصدة المدوّرة (افتتاح سنة إلها سنة قبلها) ما بتنحسب عشان ما يتكرر الرصيد
create or replace function public.party_balance_fy(p_party uuid, p_fy uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(l.debit - l.credit), 0) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
    join public.fiscal_years y on y.id = e.fiscal_year_id
   where l.party_id = p_party and e.status in ('posted','reversed') and e.entry_type <> 'closing'
     and not (e.entry_type = 'opening' and exists (select 1 from public.fiscal_years y2 where y2.company_id = y.company_id and y2.start_date < y.start_date));
$$;
revoke execute on function public.party_balance_fy(uuid, uuid) from public, anon, authenticated;

create or replace function public.ab_credit_limit_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare lim numeric; mode text; bal numeric;
begin
  if new.inv_type <> 'sale' or new.payment_type <> 'credit' or new.party_id is null then return new; end if;
  if not (new.status = 'posted' and old.status = 'draft') then return new; end if;
  select credit_limit_mode into mode from public.company_settings where company_id = new.company_id;
  if coalesce(mode, 'warn') <> 'block' then return new; end if;
  select credit_limit into lim from public.parties where id = new.party_id;
  if coalesce(lim, 0) <= 0 then return new; end if;
  if public.is_admin() or public.can(new.company_id, 'credit_override', 'edit') then return new; end if;
  perform pg_advisory_xact_lock(hashtext('credit|' || new.party_id));
  bal := public.party_balance_fy(new.party_id, new.fiscal_year_id);
  -- قيد الفاتورة نفسها بينعمل قبل تحديث الحالة: ما بينحسب مرتين
  bal := bal - coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                          where l.entry_id = new.entry_id and l.party_id = new.party_id and e.status in ('posted','reversed')), 0);
  if bal + new.total > lim + 0.0005 then
    raise exception 'الزبون تجاوز سقف الائتمان (السقف %، الرصيد بعد الفاتورة %). بدها صلاحية «تجاوز سقف الائتمان»', lim, round(bal + new.total, 3);
  end if;
  return new;
end $$;
drop trigger if exists ab_credit_limit_check on public.invoices;
create trigger ab_credit_limit_check before update of status on public.invoices for each row execute function public.ab_credit_limit_check();

-- ---------------------------------------------------------------------
--  توزيع الدفعات على الفواتير
-- ---------------------------------------------------------------------
create table if not exists public.invoice_allocations (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  entry_id   uuid not null references public.journal_entries(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  amount     numeric(18,3) not null check (amount > 0),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  unique (entry_id, invoice_id)
);
create index if not exists inv_alloc_inv on public.invoice_allocations (invoice_id);
alter table public.invoice_allocations enable row level security;
revoke insert, update, delete on public.invoice_allocations from authenticated;
grant select on public.invoice_allocations to authenticated;
drop policy if exists ia_select on public.invoice_allocations;
create policy ia_select on public.invoice_allocations for select to authenticated using (
  (public.can(company_id, 'receipt_vouchers', 'view') or public.can(company_id, 'payment_vouchers', 'view')
   or public.can(company_id, 'sales_invoices', 'view') or public.can(company_id, 'purchase_invoices', 'view'))
  and exists (select 1 from public.invoices i where i.id = invoice_id and public.dept_ok(company_id, i.department_id)));

-- الدفعة الفعّالة: مش ملغاة ولا معكوسة
create or replace function public.alloc_live(p_entry uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.journal_entries e where e.id = p_entry and e.status = 'posted' and e.reversed_by is null and e.reversal_of is null)
     and not exists (select 1 from public.cheque_events ev join public.cheques c on c.id = ev.cheque_id
                      where ev.entry_id = p_entry and c.status in ('returned','cancelled'));
$$;

-- فواتير الطرف الآجلة المرحّلة مع المتبقي (الفاتورة − المرتجعات المرحّلة − الموزّع من دفعات فعّالة)
create or replace function public.party_open_invoices(p_company uuid, p_party uuid, p_except_entry uuid default null)
returns table (invoice_id uuid, inv_type text, doc_code text, inv_no int, inv_date date, due_date date, total numeric, returned numeric, allocated numeric, remaining numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.can(p_company, 'receipt_vouchers', 'view') or public.can(p_company, 'payment_vouchers', 'view')
          or public.can(p_company, 'sales_invoices', 'view') or public.can(p_company, 'purchase_invoices', 'view')) then raise exception 'ما عندك صلاحية'; end if;
  return query
  select i.id, i.inv_type, i.doc_code, i.inv_no, i.inv_date, coalesce(i.due_date, (i.inv_date + coalesce(p.payment_terms_days, 0))::date), i.total,
         coalesce(r.amt, 0), coalesce(a.amt, 0), round(i.total - coalesce(r.amt, 0) - coalesce(a.amt, 0), 3)
    from public.invoices i join public.parties p on p.id = i.party_id
    left join lateral (select sum(x.total) amt from public.invoices x where x.original_invoice_id = i.id and x.status = 'posted' and x.payment_type = 'credit') r on true
    left join lateral (select sum(al.amount) amt from public.invoice_allocations al
                        where al.invoice_id = i.id and public.alloc_live(al.entry_id) and al.entry_id is distinct from p_except_entry) a on true
   where i.company_id = p_company and i.party_id = p_party and i.status = 'posted' and i.payment_type = 'credit'
     and i.inv_type in ('sale','purchase') and public.dept_ok(p_company, i.department_id)
   order by i.inv_date, i.inv_no;
end $$;

-- مبلغ الطرف بالدفعة: القبض = دائن الزبون، الصرف = مدين المورد
create or replace function public.entry_party_amount(p_entry uuid, p_party uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(case when p.party_type = 'supplier' then l.debit - l.credit else l.credit - l.debit end), 0)
    from public.journal_lines l join public.parties p on p.id = l.party_id
   where l.entry_id = p_entry and l.party_id = p_party;
$$;

-- حفظ التوزيع (بيستبدل توزيع الدفعة لهالطرف): p_items = [{invoice_id, amount}]
create or replace function public.allocate_payment(p_entry uuid, p_party uuid, p_items jsonb) returns numeric
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries; scr text; avail numeric; tot numeric := 0; it jsonb; inv record; amt numeric;
begin
  select * into e from public.journal_entries where id = p_entry for update;
  if e.id is null then raise exception 'السند مش موجود'; end if;
  scr := public.entry_screen(e.entry_type);
  if not (public.can(e.company_id, scr, 'edit') or public.can(e.company_id, scr, 'add')) or not public.tenant_writable() then raise exception 'ما عندك صلاحية'; end if;
  if e.entry_type not in ('receipt','payment','journal','cheque','opening') then raise exception 'هالنوع من القيود ما بيتوزّع على الفواتير'; end if;
  if not public.alloc_live(p_entry) then raise exception 'التوزيع بس لسند مرحّل (مش معكوس ولا شيكه راجع)'; end if;
  if e.is_frozen then raise exception 'السند مجمّد'; end if;
  if exists (select 1 from public.fiscal_years y where y.id = e.fiscal_year_id and y.is_closed) then raise exception 'السنة المالية مغلقة'; end if;
  if not public.dept_ok(e.company_id, e.department_id) then raise exception 'ما عندك صلاحية على هالفرع'; end if;
  avail := public.entry_party_amount(p_entry, p_party);
  if avail <= 0 then raise exception 'السند ما فيه دفعة لهالطرف'; end if;
  perform pg_advisory_xact_lock(hashtext('alloc|' || p_party));
  delete from public.invoice_allocations a using public.invoices i where a.entry_id = p_entry and i.id = a.invoice_id and i.party_id = p_party;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    amt := round(coalesce(nullif(it ->> 'amount', '')::numeric, 0), 3);
    if amt <= 0 then continue; end if;
    select * into inv from public.party_open_invoices(e.company_id, p_party, p_entry) o where o.invoice_id = (it ->> 'invoice_id')::uuid;
    if inv.invoice_id is null then raise exception 'الفاتورة مش مفتوحة لهالطرف'; end if;
    if amt > inv.remaining + 0.0005 then raise exception 'المبلغ على الفاتورة % أكبر من المتبقي (%)', coalesce(inv.doc_code, inv.inv_no::text), inv.remaining; end if;
    tot := tot + amt;
    insert into public.invoice_allocations (company_id, entry_id, invoice_id, amount) values (e.company_id, p_entry, inv.invoice_id, amt);
  end loop;
  if tot > avail + 0.0005 then raise exception 'المجموع الموزّع (%) أكبر من مبلغ الدفعة (%)', tot, avail; end if;
  return tot;
end $$;

-- توزيع تلقائي: الأقدم أول
create or replace function public.auto_allocate(p_entry uuid, p_party uuid) returns numeric
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries; left_amt numeric; items jsonb := '[]'; r record;
begin
  select * into e from public.journal_entries where id = p_entry;
  if e.id is null or not public.has_company(e.company_id) then raise exception 'السند مش موجود'; end if;
  left_amt := public.entry_party_amount(p_entry, p_party);
  for r in select * from public.party_open_invoices(e.company_id, p_party, p_entry) where remaining > 0 loop
    exit when left_amt <= 0.0005;
    items := items || jsonb_build_array(jsonb_build_object('invoice_id', r.invoice_id, 'amount', least(r.remaining, left_amt)));
    left_amt := left_amt - least(r.remaining, left_amt);
  end loop;
  return public.allocate_payment(p_entry, p_party, items);
end $$;


-- التوزيع بينمسح لما السند ينلغى ترحيله، أو الفاتورة تنلغى/ينلغى ترحيلها/يتغيّر طرفها
create or replace function public.zv_alloc_cleanup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'journal_entries' then
    if old.status = 'posted' and new.status <> 'posted' then delete from public.invoice_allocations where entry_id = new.id; end if;
  else
    if (old.status = 'posted' and new.status <> 'posted') or new.party_id is distinct from old.party_id then
      delete from public.invoice_allocations where invoice_id = new.id;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists zv_alloc_cleanup on public.journal_entries;
create trigger zv_alloc_cleanup after update of status on public.journal_entries for each row execute function public.zv_alloc_cleanup();
drop trigger if exists zv_alloc_cleanup on public.invoices;
create trigger zv_alloc_cleanup after update of status, party_id on public.invoices for each row execute function public.zv_alloc_cleanup();

revoke execute on function public.alloc_live(uuid), public.entry_party_amount(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.party_open_invoices(uuid, uuid, uuid), public.allocate_payment(uuid, uuid, jsonb), public.auto_allocate(uuid, uuid) from public, anon;
grant execute on function public.party_open_invoices(uuid, uuid, uuid), public.allocate_payment(uuid, uuid, jsonb), public.auto_allocate(uuid, uuid) to authenticated;

-- النسخة الاحتياطية: التوزيع بعد الفواتير والقيود
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
   (11, 'sales_visits', 'company_id = $1', 'started_at'),
   (12, 'item_categories', 'company_id = $1', 'code'),
   (13, 'items', 'company_id = $1', 'code'),
   (14, 'promotions', 'company_id = $1', 'date_from'),
   (15, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (16, 'warehouses', 'company_id = $1', 'code'),
   (17, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (18, 'departments', 'company_id = $1', 'level, code'),
   (19, 'doc_types', 'company_id = $1', 'kind, code'),
   (20, 'boms', 'company_id = $1', 'code'),
   (21, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (22, 'journal_entries', 'company_id = $1', 'created_at'),
   (23, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (24, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (25, 'invoices', 'company_id = $1', 'created_at'),
   (26, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (27, 'invoice_allocations', 'company_id = $1', 'created_at'),
   (28, 'orders', 'company_id = $1', 'created_at'),
   (29, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (30, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (31, 'cheques', 'company_id = $1', 'created_at'),
   (32, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (33, 'supply_requests', 'company_id = $1', 'req_no'),
   (34, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (35, 'stock_docs', 'company_id = $1', 'created_at'),
   (36, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (37, 'stock_moves', 'company_id = $1', 'created_at'),
   (38, 'productions', 'company_id = $1', 'prod_no'),
   (39, 'obligations', 'company_id = $1', 'due_date'),
   (40, 'recurring_entries', 'company_id = $1', 'created_at'),
   (41, 'work_locations', 'company_id = $1', 'name'),
   (42, 'employees', 'company_id = $1', 'code'),
   (43, 'attendance', 'company_id = $1', 'day, employee_id'),
   (44, 'payroll_runs', 'company_id = $1', 'period'),
   (45, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (46, 'employee_loans', 'company_id = $1', 'loan_no'),
   (47, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (48, 'asset_custodians', 'company_id = $1', 'code'),
   (49, 'fixed_assets', 'company_id = $1', 'code'),
   (50, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (51, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (52, 'asset_movements', 'company_id = $1', 'mov_no'),
   (53, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (54, 'custody_docs', 'company_id = $1', 'doc_no'),
   (55, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (56, 'bank_recons', 'company_id = $1', 'created_at'),
   (57, 'bank_cleared', 'company_id = $1', 'line_id'),
   (58, 'attachments', 'company_id = $1', 'created_at'),
   (59, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
