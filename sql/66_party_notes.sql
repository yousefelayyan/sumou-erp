-- =====================================================================
--  السمو ERP — المرحلة 66: الإشعارات المدينة والدائنة (للعملاء والموردين) + أعمار الذمم التفصيلية
--  party_notes: إشعار مدين/دائن على طرف (عميل أو مورد)، حساب مقابل (خصم مسموح/مكتسب، إيراد، مصروف…)،
--  مبلغ + نسبة ضريبة، فاتورة مرجعية اختيارية. الكتابة من الدوال بس: note_save (المسودة)، note_post (قيد journal داخلي)،
--  note_cancel (قيد عكسي)، note_delete (المسودة). الإشعار اللي بينزّل رصيد الطرف (دائن للعميل، مدين للمورد) بيتوزّع لحاله
--  على فاتورته المرجعية إذا ممكن. القيد ما بيتغيّر إلا من شاشة الإشعارات (ab_note_entry_guard).
--  الصلاحيات: customer_notes (قسم sales) و supplier_notes (قسم purchases). الضريبة بإقرار ضريبة المبيعات (rep_sales_tax).
--  rep_party_aging_docs: حركات الأطراف لتقرير الأعمار التفصيلي (رقم المستند والبيان والاستحقاق).
-- =====================================================================
do $$ begin
  if to_regclass('public.party_notes') is null then   -- مرة وحدة: نفس صلاحية الفواتير
    update public.user_groups set permissions = permissions || jsonb_build_object('customer_notes', permissions -> 'sales_invoices')
     where permissions ? 'sales_invoices' and not permissions ? 'customer_notes';
    update public.user_groups set permissions = permissions || jsonb_build_object('supplier_notes', permissions -> 'purchase_invoices')
     where permissions ? 'purchase_invoices' and not permissions ? 'supplier_notes';
  end if;
end $$;

create or replace function public.screen_module(s text) returns text
language sql immutable as $$
  select case
    when s in ('customers','sales_invoices','sales_orders','pos','rep_visits','customer_notes')  then 'sales'
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


create table if not exists public.party_notes (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  fiscal_year_id  uuid not null references public.fiscal_years(id) on delete restrict,
  party_type      text not null check (party_type in ('customer','supplier')),
  note_kind       text not null check (note_kind in ('debit','credit')),
  note_no         int not null,
  note_date       date not null,
  party_id        uuid not null references public.parties(id) on delete restrict,
  invoice_id      uuid references public.invoices(id) on delete restrict,
  account_id      uuid not null references public.accounts(id) on delete restrict,
  amount          numeric(18,3) not null check (amount > 0),
  tax_rate        numeric(6,3) not null default 0 check (tax_rate between 0 and 100),
  tax_amount      numeric(18,3) not null default 0,
  total           numeric(18,3) not null default 0,
  description     text,
  reference       text,
  department_id   uuid references public.departments(id) on delete set null,
  cost_center_id  uuid references public.cost_centers(id) on delete set null,
  status          text not null default 'draft' check (status in ('draft','posted','cancelled')),
  entry_id        uuid references public.journal_entries(id) on delete set null,
  cancel_entry_id uuid references public.journal_entries(id) on delete set null,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_by      uuid,
  updated_at      timestamptz,
  posted_by       uuid,
  posted_at       timestamptz,
  unique (company_id, fiscal_year_id, party_type, note_kind, note_no)
);
create index if not exists party_notes_party_idx on public.party_notes (company_id, party_id);
create index if not exists party_notes_entry_idx on public.party_notes (entry_id);
grant select on public.party_notes to authenticated;
alter table public.party_notes enable row level security;
create or replace function public.note_screen(p_type text) returns text
language sql immutable as $$ select case p_type when 'supplier' then 'supplier_notes' else 'customer_notes' end $$;
drop policy if exists party_notes_sel on public.party_notes;
create policy party_notes_sel on public.party_notes for select
  using (public.can(company_id, public.note_screen(party_type), 'view') and public.dept_ok(company_id, department_id));

-- حفظ مسودة (جديد أو تعديل)
create or replace function public.note_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id','')::uuid; n public.party_notes; cid uuid := (p->>'company_id')::uuid; pt text := p->>'party_type';
  pa public.parties; inv public.invoices; d date := coalesce(nullif(p->>'note_date','')::date, public.local_today()); fy uuid;
  amt numeric := round(coalesce((p->>'amount')::numeric, 0), 3); rate numeric := coalesce(nullif(p->>'tax_rate','')::numeric, 0);
  dept uuid := nullif(p->>'department_id','')::uuid; cc uuid := nullif(p->>'cost_center_id','')::uuid; kind text := p->>'note_kind'; no int;
begin
  if v_id is not null then
    select * into n from public.party_notes where id = v_id for update;
    if n.id is null then raise exception 'الإشعار مش موجود'; end if;
    if n.status <> 'draft' then raise exception 'الإشعار مرحّل — ما بيتعدّل'; end if;
    cid := n.company_id; pt := n.party_type; kind := n.note_kind;
    if not public.can(cid, public.note_screen(pt), 'edit') then raise exception 'ما عندك صلاحية تعديل الإشعارات'; end if;
    if not public.dept_ok(cid, n.department_id) then raise exception 'هالمستند لفرع ثاني'; end if;
  else
    if pt not in ('customer','supplier') or kind not in ('debit','credit') then raise exception 'نوع الإشعار غير معروف'; end if;
    if not public.can(cid, public.note_screen(pt), 'add') then raise exception 'ما عندك صلاحية إضافة الإشعارات'; end if;
  end if;
  if not public.tenant_writable() then raise exception 'الاشتراك منتهي'; end if;
  select * into pa from public.parties where id = (p->>'party_id')::uuid and company_id = cid and party_type = pt;
  if pa.id is null then raise exception '% مش موجود', case pt when 'supplier' then 'المورد' else 'العميل' end; end if;
  if pa.account_id is null then raise exception 'الطرف ما إله حساب'; end if;
  if amt <= 0 then raise exception 'المبلغ لازم أكبر من صفر'; end if;
  if rate < 0 or rate > 100 then raise exception 'نسبة الضريبة غلط'; end if;
  if not exists (select 1 from public.accounts where id = (p->>'account_id')::uuid and company_id = cid and not is_group and is_active and account_type not in ('customer','supplier')) then
    raise exception 'الحساب المقابل لازم يكون فرعي وفعّال من نفس الشركة (مش حساب ذمم)'; end if;
  if (p->>'account_id')::uuid = pa.account_id then raise exception 'الحساب المقابل ما بيكون حساب الطرف نفسه'; end if;
  if nullif(p->>'invoice_id','') is not null then
    select * into inv from public.invoices where id = (p->>'invoice_id')::uuid and company_id = cid and party_id = pa.id and status = 'posted'
       and inv_type = case pt when 'supplier' then 'purchase' else 'sale' end;
    if inv.id is null then raise exception 'الفاتورة المرجعية لازم تكون مرحّلة ولنفس الطرف'; end if;
  end if;
  if dept is not null and not exists (select 1 from public.departments where id = dept and company_id = cid) then raise exception 'الدائرة مش من نفس الشركة'; end if;
  if cc is not null and not exists (select 1 from public.cost_centers where id = cc and company_id = cid) then raise exception 'مركز الكلفة مش من نفس الشركة'; end if;
  if dept is null and v_id is null then select department_id into dept from public.user_companies where user_id = auth.uid() and company_id = cid; end if;
  if not public.dept_ok(cid, dept) then raise exception 'ما عندك صلاحية على هالفرع'; end if;
  select id into fy from public.fiscal_years where company_id = cid and d between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy is null then raise exception 'ما في سنة مالية مفتوحة بالتاريخ'; end if;
  if v_id is null then
    perform pg_advisory_xact_lock(hashtext('note:' || cid::text || pt || kind || fy::text));
    select coalesce(max(note_no), 0) + 1 into no from public.party_notes where company_id = cid and fiscal_year_id = fy and party_type = pt and note_kind = kind;
    insert into public.party_notes (company_id, fiscal_year_id, party_type, note_kind, note_no, note_date, party_id, invoice_id, account_id, amount, tax_rate,
                                    tax_amount, total, description, reference, department_id, cost_center_id)
    values (cid, fy, pt, kind, no, d, pa.id, inv.id, (p->>'account_id')::uuid, amt, rate, round(amt * rate / 100, 3), amt + round(amt * rate / 100, 3),
            nullif(trim(p->>'description'), ''), nullif(trim(p->>'reference'), ''), dept, cc) returning id into v_id;
  else
    if fy <> n.fiscal_year_id then raise exception 'تاريخ الإشعار لازم يضل بنفس السنة المالية'; end if;
    update public.party_notes set note_date = d, party_id = pa.id, invoice_id = inv.id, account_id = (p->>'account_id')::uuid, amount = amt, tax_rate = rate,
           tax_amount = round(amt * rate / 100, 3), total = amt + round(amt * rate / 100, 3), description = nullif(trim(p->>'description'), ''),
           reference = nullif(trim(p->>'reference'), ''), department_id = coalesce(dept, n.department_id), cost_center_id = cc, updated_by = auth.uid(), updated_at = now()
     where id = v_id;
  end if;
  return v_id;
end $$;

-- الترحيل: قيد journal داخلي
create or replace function public.note_post(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare n public.party_notes; pa public.parties; st public.company_settings; tax_acc uuid; eid uuid; label text; up boolean; prev text := current_setting('sumou.internal', true);
  rem numeric;
begin
  select * into n from public.party_notes where id = p_id for update;
  if n.id is null then raise exception 'الإشعار مش موجود'; end if;
  if not public.can(n.company_id, public.note_screen(n.party_type), 'post') or not public.tenant_writable() then raise exception 'ما عندك صلاحية ترحيل الإشعارات'; end if;
  if not public.dept_ok(n.company_id, n.department_id) then raise exception 'هالمستند لفرع ثاني'; end if;
  if n.status <> 'draft' then raise exception 'الإشعار مرحّل من قبل'; end if;
  if exists (select 1 from public.fiscal_years where id = n.fiscal_year_id and is_closed) then raise exception 'السنة المالية مغلقة'; end if;
  select * into pa from public.parties where id = n.party_id;
  select * into st from public.company_settings where company_id = n.company_id;
  tax_acc := case n.party_type when 'customer' then st.output_tax_account_id else st.input_tax_account_id end;
  if n.tax_amount > 0 and tax_acc is null then raise exception 'حدّد حساب ضريبة المبيعات بحسابات الربط'; end if;
  -- up = الطرف مدين بالقيد (إشعار مدين للعميل / مدين للمورد)
  up := n.note_kind = 'debit';
  label := case n.note_kind when 'debit' then 'إشعار مدين ' else 'إشعار دائن ' end || case n.party_type when 'customer' then 'للعميل ' else 'للمورد ' end
           || pa.name || ' رقم ' || n.note_no || coalesce(' — ' || n.description, '');
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status, department_id)
  values (n.company_id, n.fiscal_year_id, 'journal', n.note_date, label, coalesce(n.reference, case n.note_kind when 'debit' then 'إشعار مدين' else 'إشعار دائن' end || ' ' || n.note_no), 'draft', n.department_id)
  returning id into eid;
  -- سطر الطرف بالمجموع، والمقابل بالمبلغ، والضريبة: العميل (مخرجات) والمورد (مدخلات)
  insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
  values (eid, 1, pa.account_id, pa.id, label, case when up then n.total else 0 end, case when up then 0 else n.total end);
  insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, cost_center_id)
  values (eid, 2, n.account_id, label, case when up then 0 else n.amount end, case when up then n.amount else 0 end, n.cost_center_id);
  if n.tax_amount > 0 then
    insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit)
    values (eid, 3, tax_acc, 'ضريبة المبيعات — ' || label,
            case when up then 0 else n.tax_amount end, case when up then n.tax_amount else 0 end);   -- الضريبة بنفس جهة الحساب المقابل
  end if;
  if exists (select 1 from public.journal_lines where entry_id = eid having abs(sum(debit) - sum(credit)) > 0.0005) then raise exception 'قيد الإشعار مش متوازن'; end if;
  update public.journal_entries set status = 'posted', total = n.total, posted_by = auth.uid(), posted_at = now() where id = eid;
  update public.party_notes set status = 'posted', entry_id = eid, posted_by = auth.uid(), posted_at = now() where id = p_id;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  -- الإشعار اللي بينزّل الذمة بيتوزّع على فاتورته المرجعية (إذا مسموح ومفتوحة)
  if n.invoice_id is not null and ((n.party_type = 'customer' and not up) or (n.party_type = 'supplier' and up)) then
    begin
      select o.remaining into rem from public.party_open_invoices(n.company_id, n.party_id, eid) o where o.invoice_id = n.invoice_id;
      if coalesce(rem, 0) > 0.0005 then
        perform public.allocate_payment(eid, n.party_id, jsonb_build_array(jsonb_build_object('invoice_id', n.invoice_id, 'amount', least(rem, n.total))));
      end if;
    exception when others then null;   -- التوزيع اختياري؛ الترحيل بيضل
    end;
  end if;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), n.company_id, 'ترحيل', 'party_notes', p_id::text, jsonb_build_object('no', n.note_no, 'kind', n.note_kind, 'party', pa.name, 'total', n.total));
  return eid;
end $$;

create or replace function public.note_cancel(p_id uuid, p_date date default null) returns void
language plpgsql security definer set search_path = public as $$
declare n public.party_notes; rid uuid; prev text := current_setting('sumou.internal', true);
begin
  select * into n from public.party_notes where id = p_id for update;
  if n.id is null then raise exception 'الإشعار مش موجود'; end if;
  if not public.can(n.company_id, public.note_screen(n.party_type), 'post') or not public.tenant_writable() then raise exception 'ما عندك صلاحية'; end if;
  if not public.dept_ok(n.company_id, n.department_id) then raise exception 'هالمستند لفرع ثاني'; end if;
  if n.status <> 'posted' then raise exception 'الإشعار مش مرحّل'; end if;
  if exists (select 1 from public.journal_entries where id = n.entry_id and is_frozen) then raise exception 'القيد مجمّد'; end if;
  if exists (select 1 from public.bank_cleared bc join public.journal_lines l on l.id = bc.line_id where l.entry_id = n.entry_id) then raise exception 'قيد الإشعار عليه تسوية بنكية — فكّها أول'; end if;
  perform set_config('sumou.note', public.internal_token(), true);
  rid := public.reverse_internal(n.entry_id, greatest(coalesce(p_date, public.local_today()), n.note_date), 'إلغاء إشعار رقم ' || n.note_no);
  update public.journal_entries set department_id = n.department_id where id = rid;
  perform set_config('sumou.note', '', true);
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  update public.party_notes set status = 'cancelled', cancel_entry_id = rid where id = p_id;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), n.company_id, 'إلغاء', 'party_notes', p_id::text, jsonb_build_object('no', n.note_no));
end $$;

create or replace function public.note_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n public.party_notes;
begin
  select * into n from public.party_notes where id = p_id for update;
  if n.id is null then raise exception 'الإشعار مش موجود'; end if;
  if not public.can(n.company_id, public.note_screen(n.party_type), 'delete') or not public.tenant_writable() then raise exception 'ما عندك صلاحية'; end if;
  if not public.dept_ok(n.company_id, n.department_id) then raise exception 'هالمستند لفرع ثاني'; end if;
  if n.status <> 'draft' then raise exception 'بس المسودة بتنحذف؛ المرحّل بينلغى'; end if;
  delete from public.party_notes where id = p_id;
end $$;
revoke execute on function public.note_save(jsonb), public.note_post(uuid), public.note_cancel(uuid, date), public.note_delete(uuid) from public, anon;
grant execute on function public.note_save(jsonb), public.note_post(uuid), public.note_cancel(uuid, date), public.note_delete(uuid) to authenticated;

-- قيد الإشعار ما بيتغيّر من شاشة القيود
create or replace function public.ab_note_entry_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('sumou.note', true), '') = public.internal_token() then return new; end if;
  if old.status = 'posted' and new.status is distinct from old.status
     and exists (select 1 from public.party_notes where entry_id = old.id) then
    raise exception 'قيد الإشعار بينلغى من شاشة الإشعارات';
  end if;
  return new;
end $$;
drop trigger if exists ab_note_entry_guard on public.journal_entries;
create trigger ab_note_entry_guard before update of status on public.journal_entries for each row execute function public.ab_note_entry_guard();
revoke execute on function public.ab_note_entry_guard() from public, anon, authenticated;

-- إقرار ضريبة المبيعات: الفواتير + الإشعارات (sale_dn, sale_cn, purchase_dn, purchase_cn)
create or replace function public.rep_sales_tax(p_company uuid, p_from date, p_to date)
returns table (inv_type text, tax_rate numeric, invoices bigint, subtotal numeric, tax numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  select x.t, x.r, sum(x.c)::bigint, sum(x.s), sum(x.x) from (
    select i.inv_type t, l.tax_rate r, count(distinct i.id) c, sum(l.subtotal) s, sum(l.tax_amount) x
      from public.invoices i join public.invoice_lines l on l.invoice_id = i.id
     where i.company_id = p_company and i.status = 'posted' and i.inv_date between p_from and p_to
     group by i.inv_type, l.tax_rate
    union all
    select case n.party_type when 'customer' then 'sale_' else 'purchase_' end || case n.note_kind when 'debit' then 'dn' else 'cn' end, n.tax_rate, count(*), sum(n.amount), sum(n.tax_amount)
      from public.party_notes n
     where n.company_id = p_company and n.status = 'posted' and n.note_date between p_from and p_to
     group by 1, 2) x
  group by x.t, x.r order by x.t, x.r desc;
end $$;

-- حركات الأطراف بالتفصيل لتقرير الأعمار (السنة المالية لغاية تاريخ)
create or replace function public.rep_party_aging_docs(p_company uuid, p_fy uuid, p_type text, p_to date)
returns table (party_id uuid, entry_id uuid, entry_date date, entry_type text, doc_no text, description text, due_date date, debit numeric, credit numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  select l.party_id, e.id, e.entry_date, e.entry_type, coalesce(i.doc_code, i.inv_no::text, e.doc_code, e.entry_no::text),
         coalesce(e.description, max(l.description)), i.due_date, sum(l.debit), sum(l.credit)
    from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
    join public.parties p on p.id = l.party_id
    left join public.invoices i on i.entry_id = e.id
   where p.party_type = p_type and e.company_id = p_company and e.fiscal_year_id = p_fy
     and e.status = 'posted' and e.reversal_of is null and e.entry_date <= p_to   -- المعكوس وعكسه بيلغوا بعض
   group by l.party_id, e.id, e.entry_date, e.entry_type, i.doc_code, i.inv_no, e.doc_code, e.entry_no, e.description, i.due_date
   order by l.party_id, e.entry_date, e.created_at;
end $$;
revoke execute on function public.rep_party_aging_docs(uuid, uuid, text, date) from public, anon;
grant execute on function public.rep_party_aging_docs(uuid, uuid, text, date) to authenticated;

-- النسخة الاحتياطية: الإشعارات بعد توزيع الدفعات
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
   (35, 'party_notes', 'company_id = $1', 'created_at'),
   (36, 'orders', 'company_id = $1', 'created_at'),
   (37, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (38, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (39, 'cheques', 'company_id = $1', 'created_at'),
   (40, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (41, 'supply_requests', 'company_id = $1', 'req_no'),
   (42, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (43, 'stock_docs', 'company_id = $1', 'created_at'),
   (44, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (45, 'stock_moves', 'company_id = $1', 'created_at'),
   (46, 'batch_moves', 'company_id = $1', 'created_at'),
   (47, 'landed_costs', 'company_id = $1', 'doc_no'),
   (48, 'landed_cost_invoices', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (49, 'landed_cost_charges', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id, line_no'),
   (50, 'landed_cost_allocs', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (51, 'productions', 'company_id = $1', 'prod_no'),
   (52, 'obligations', 'company_id = $1', 'due_date'),
   (53, 'recurring_entries', 'company_id = $1', 'created_at'),
   (54, 'budgets', 'company_id = $1', 'code'),
   (55, 'budget_lines', 'budget_id in (select id from public.budgets where company_id = $1)', 'budget_id'),
   (56, 'work_locations', 'company_id = $1', 'name'),
   (57, 'work_shifts', 'company_id = $1', 'code'),
   (58, 'employees', 'company_id = $1', 'code'),
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
