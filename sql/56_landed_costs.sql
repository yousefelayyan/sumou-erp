-- =====================================================================
--  السمو ERP — المرحلة 56: الكلفة المحمّلة (توزيع مصاريف الاستيراد والشحن على الأصناف)
--  مستند فيه: فواتير شراء مرحّلة للمخزون + مصاريف (حساب/مورد/مبلغ) + طريقة التوزيع (قيمة/كمية).
--  الترحيل: بيوزّع المصاريف على حركات الفواتير (صنف × مستودع)، الجزء الموجود بالمخزون بيرفع قيمته
--  (حركتين +1 بالمبلغ و−1 بصفر = قيمة بدون كمية)، والجزء المباع بيروح لكلفة المبيعات.
--  القيد: مدين المخزون (جرد مستمر) أو المشتريات (جرد دوري) + كلفة المبيعات، دائن حسابات المصاريف.
-- =====================================================================
create or replace function public.screen_module(s text) returns text
language sql immutable as $$
  select case
    when s in ('customers','sales_invoices','sales_orders','pos','rep_visits')  then 'sales'
    when s in ('suppliers','purchase_invoices','purchase_orders','landed_costs') then 'purchases'
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

do $$
begin
  if to_regclass('public.landed_costs') is null then
    -- مرة وحدة: المجموعات اللي إلها فواتير الشراء بتاخذ نفس الصلاحية على الكلفة المحمّلة
    update public.user_groups set permissions = permissions || jsonb_build_object('landed_costs', permissions -> 'purchase_invoices')
     where permissions ? 'purchase_invoices' and not permissions ? 'landed_costs';
  end if;
end $$;

create table if not exists public.landed_costs (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  doc_no        int not null,
  doc_date      date not null,
  description   text,
  method        text not null default 'value' check (method in ('value','qty')),
  status        text not null default 'draft' check (status in ('draft','posted','cancelled')),
  entry_id      uuid references public.journal_entries(id) on delete set null,
  cancel_entry_id uuid references public.journal_entries(id) on delete set null,
  total         numeric(18,3) not null default 0,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  posted_at     timestamptz,
  unique (company_id, doc_no)
);
create table if not exists public.landed_cost_invoices (
  landed_id  uuid not null references public.landed_costs(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id) on delete restrict,
  primary key (landed_id, invoice_id)
);
create table if not exists public.landed_cost_charges (
  id          uuid primary key default gen_random_uuid(),
  landed_id   uuid not null references public.landed_costs(id) on delete cascade,
  line_no     int not null default 1,
  description text,
  account_id  uuid not null references public.accounts(id) on delete restrict,
  party_id    uuid references public.parties(id) on delete restrict,
  amount      numeric(18,3) not null check (amount > 0)
);
create table if not exists public.landed_cost_allocs (
  id          uuid primary key default gen_random_uuid(),
  landed_id   uuid not null references public.landed_costs(id) on delete cascade,
  item_id     uuid not null references public.items(id) on delete restrict,
  warehouse_id uuid not null references public.warehouses(id) on delete restrict,
  qty         numeric(18,3) not null,
  base_value  numeric(18,3) not null,
  amount      numeric(18,3) not null,
  to_stock    numeric(18,3) not null,
  to_cogs     numeric(18,3) not null
);
create index if not exists landed_cost_invoices_inv on public.landed_cost_invoices(invoice_id);
create index if not exists landed_cost_allocs_l on public.landed_cost_allocs(landed_id);
create index if not exists landed_costs_entry on public.landed_costs(entry_id) where entry_id is not null;
create index if not exists landed_costs_centry on public.landed_costs(cancel_entry_id) where cancel_entry_id is not null;
do $$ begin   -- لو الجدول انعمل بنسخة سابقة بـ cascade
  if exists (select 1 from pg_constraint where conname = 'landed_cost_invoices_invoice_id_fkey' and confdeltype = 'c') then
    alter table public.landed_cost_invoices drop constraint landed_cost_invoices_invoice_id_fkey;
    alter table public.landed_cost_invoices add constraint landed_cost_invoices_invoice_id_fkey foreign key (invoice_id) references public.invoices(id) on delete restrict;
  end if;
end $$;

grant select on public.landed_costs, public.landed_cost_invoices, public.landed_cost_charges, public.landed_cost_allocs to authenticated;
alter table public.landed_costs enable row level security;
alter table public.landed_cost_invoices enable row level security;
alter table public.landed_cost_charges enable row level security;
alter table public.landed_cost_allocs enable row level security;
drop policy if exists lc_select on public.landed_costs;
create policy lc_select on public.landed_costs for select using (public.can(company_id, 'landed_costs', 'view'));
drop policy if exists zz_branch_only on public.landed_costs;
create policy zz_branch_only on public.landed_costs as restrictive for select using (public.dept_allowed(company_id) is null);
drop policy if exists lci_select on public.landed_cost_invoices;
create policy lci_select on public.landed_cost_invoices for select using (exists (select 1 from public.landed_costs l where l.id = landed_id and public.can(l.company_id, 'landed_costs', 'view')));
drop policy if exists lcc_select on public.landed_cost_charges;
create policy lcc_select on public.landed_cost_charges for select using (exists (select 1 from public.landed_costs l where l.id = landed_id and public.can(l.company_id, 'landed_costs', 'view')));
drop policy if exists lca_select on public.landed_cost_allocs;
create policy lca_select on public.landed_cost_allocs for select using (exists (select 1 from public.landed_costs l where l.id = landed_id and public.can(l.company_id, 'landed_costs', 'view')));

-- التوزيع المقترح (بدون ما ينكتب شي): صنف × مستودع من حركات الفواتير، ناقص مرتجعات الشراء المرحّلة.
-- الجزء «الموجود» = رصيد الصنف الحالي على مستوى الشركة (كل التواريخ) ÷ الكمية المشتراة (لحد 100%)،
-- لأنه الكميات اللي طلعت (حتى بعد تاريخ المستند) انحسبت كلفتها خلص، فنصيبها بيروح لكلفة المبيعات.
create or replace function public.landed_preview(p_id uuid)
returns table (item_id uuid, warehouse_id uuid, qty numeric, base_value numeric, amount numeric, on_hand numeric, to_stock numeric, to_cogs numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare l public.landed_costs; tot numeric;
begin
  select * into l from public.landed_costs where id = p_id;
  if l.id is null or not public.can(l.company_id, 'landed_costs', 'view') or public.dept_allowed(l.company_id) is not null then raise exception 'المستند غير موجود'; end if;
  select coalesce(sum(c.amount), 0) into tot from public.landed_cost_charges c where c.landed_id = p_id;
  return query
  with mv as (
    select m.item_id, m.warehouse_id, sum(m.qty) q, sum(m.qty * m.unit_cost) v
      from public.stock_moves m join public.landed_cost_invoices li on li.invoice_id = m.source_id
     where li.landed_id = p_id and m.source_type = 'invoice' and m.qty > 0 and m.company_id = l.company_id
     group by m.item_id, m.warehouse_id),
  rt as (   -- مرتجعات الشراء المرحّلة للمخزون من هالفواتير
    select m.item_id, m.warehouse_id, -sum(m.qty) rq
      from public.invoices r join public.landed_cost_invoices li on li.invoice_id = r.original_invoice_id
      join public.stock_moves m on m.source_type = 'invoice' and m.source_id = r.id and m.qty < 0
     where li.landed_id = p_id and r.inv_type = 'purchase_return' and r.status = 'posted'
     group by m.item_id, m.warehouse_id),
  net as (
    select mv.item_id, mv.warehouse_id, greatest(mv.q - coalesce(rt.rq, 0), 0) q,
           case when mv.q > 0 then mv.v * greatest(mv.q - coalesce(rt.rq, 0), 0) / mv.q else 0 end v
      from mv left join rt on rt.item_id = mv.item_id and rt.warehouse_id = mv.warehouse_id),
  b as (select n.*, case when l.method = 'qty' then n.q else n.v end as w from net n where n.q > 0),
  s as (select sum(w) sw from b),
  oh as (select b2.item_id, greatest(coalesce((select sum(x.qty) from public.stock_moves x where x.company_id = l.company_id and x.item_id = b2.item_id), 0), 0) oh,
                sum(b2.q) qi from b b2 group by b2.item_id),
  a as (
    select b.item_id, b.warehouse_id, b.q, b.v,
           case when s.sw > 0 then round(tot * b.w / s.sw, 3) else 0 end amt,
           least(1, oh.oh / nullif(oh.qi, 0)) ratio, oh.oh,
           row_number() over (order by b.w desc, b.item_id, b.warehouse_id) rn
      from b cross join s join oh on oh.item_id = b.item_id),
  fix as (   -- فرق التقريب على أكبر سطر
    select a.*, a.amt + case when a.rn = 1 then tot - sum(a.amt) over () else 0 end amt2 from a)
  select f.item_id, f.warehouse_id, round(f.q, 3), round(f.v, 3), f.amt2, f.oh,
         round(f.amt2 * coalesce(f.ratio, 0), 3), f.amt2 - round(f.amt2 * coalesce(f.ratio, 0), 3)
    from fix f order by f.rn;
end $$;

-- فحص فواتير المستند (بالحفظ والترحيل)
create or replace function public.landed_check_invoice(p_cid uuid, p_inv uuid, p_date date) returns void
language plpgsql stable security definer set search_path = public as $$
declare inv public.invoices;
begin
  select * into inv from public.invoices where id = p_inv;
  if inv.id is null or inv.company_id <> p_cid or inv.inv_type <> 'purchase' then raise exception 'الفاتورة مش فاتورة شراء لهالشركة'; end if;
  if inv.status <> 'posted' or not coalesce(inv.stock_posted, false) then raise exception 'فاتورة الشراء % لازم تكون مرحّلة للمحاسبة والمخزون', coalesce(inv.doc_code, inv.inv_no::text); end if;
  if inv.inv_date > p_date then raise exception 'تاريخ المستند لازم يكون بعد تاريخ فاتورة الشراء %', coalesce(inv.doc_code, inv.inv_no::text); end if;
end $$;
revoke all on function public.landed_check_invoice(uuid, uuid, date) from public, anon, authenticated;

-- حفظ المسودة: {id?, company_id, doc_date, description, method, invoices:[uuid], charges:[{description, account_id, party_id, amount}]}
create or replace function public.landed_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid; lid uuid; l public.landed_costs; r jsonb; n int := 0; acc uuid; pa public.parties; tot numeric := 0; d date;
begin
  cid := (p ->> 'company_id')::uuid; lid := nullif(p ->> 'id', '')::uuid; d := (p ->> 'doc_date')::date;
  if cid is null or not public.has_company(cid) or not public.tenant_writable() then raise exception 'ما عندك صلاحية'; end if;
  if public.dept_allowed(cid) is not null then raise exception 'الكلفة المحمّلة للشركة كلها، مش لموظف فرع'; end if;
  if d is null then raise exception 'التاريخ مطلوب'; end if;
  if lid is null then
    if not public.can(cid, 'landed_costs', 'add') then raise exception 'ما عندك صلاحية إضافة'; end if;
  else
    select * into l from public.landed_costs where id = lid and company_id = cid for update;
    if l.id is null then raise exception 'المستند غير موجود'; end if;
    if l.status <> 'draft' then raise exception 'المستند مرحّل، ما بيتعدّل'; end if;
    if not public.can(cid, 'landed_costs', 'edit') then raise exception 'ما عندك صلاحية تعديل'; end if;
  end if;
  if not exists (select 1 from public.fiscal_years where company_id = cid and d between start_date and end_date and not is_closed) then
    raise exception 'ما في سنة مالية مفتوحة بهالتاريخ';
  end if;
  if jsonb_array_length(coalesce(p -> 'invoices', '[]')) = 0 then raise exception 'اختار فاتورة شراء وحدة على الأقل'; end if;
  if jsonb_array_length(coalesce(p -> 'charges', '[]')) = 0 then raise exception 'أضف مصروف واحد على الأقل'; end if;
  if jsonb_array_length(p -> 'invoices') > 200 or jsonb_array_length(p -> 'charges') > 100 then raise exception 'عدد كبير كثير'; end if;

  perform set_config('sumou.internal', public.internal_token(), true);
  if lid is null then
    perform pg_advisory_xact_lock(hashtext('landed:' || cid::text));
    insert into public.landed_costs (company_id, doc_no, doc_date, description, method)
    values (cid, coalesce((select max(doc_no) from public.landed_costs where company_id = cid), 0) + 1, d,
            left(p ->> 'description', 500), coalesce(nullif(p ->> 'method', ''), 'value'))
    returning id into lid;
  else
    update public.landed_costs set doc_date = d, description = left(p ->> 'description', 500), method = coalesce(nullif(p ->> 'method', ''), 'value') where id = lid;
    delete from public.landed_cost_invoices where landed_id = lid;
    delete from public.landed_cost_charges where landed_id = lid;
  end if;
  for r in select * from jsonb_array_elements(p -> 'invoices') loop
    perform public.landed_check_invoice(cid, (r #>> '{}')::uuid, d);
    insert into public.landed_cost_invoices (landed_id, invoice_id) values (lid, (r #>> '{}')::uuid) on conflict do nothing;
  end loop;
  for r in select * from jsonb_array_elements(p -> 'charges') loop
    n := n + 1;
    if coalesce((r ->> 'amount')::numeric, 0) <= 0 then raise exception 'المصروف %: المبلغ لازم أكبر من صفر', n; end if;
    pa := null; acc := nullif(r ->> 'account_id', '')::uuid;
    if nullif(r ->> 'party_id', '') is not null then
      select * into pa from public.parties where id = (r ->> 'party_id')::uuid and company_id = cid;
      if pa.id is null or not pa.is_active then raise exception 'المصروف %: الطرف مش من هالشركة أو موقوف', n; end if;
      acc := pa.account_id;   -- الطرف دايماً على حسابه
    end if;
    if acc is null or not exists (select 1 from public.accounts where id = acc and company_id = cid and not is_group) then
      raise exception 'المصروف %: اختار حساب فرعي (المورد أو الصندوق أو المصروف المستحق)', n;
    end if;
    insert into public.landed_cost_charges (landed_id, line_no, description, account_id, party_id, amount)
    values (lid, n, left(r ->> 'description', 300), acc, pa.id, round((r ->> 'amount')::numeric, 3));
    tot := tot + round((r ->> 'amount')::numeric, 3);
  end loop;
  update public.landed_costs set total = tot where id = lid;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), cid, case when (p ->> 'id') is null then 'إضافة' else 'تعديل' end, 'landed_costs', lid::text, jsonb_build_object('total', tot));
  return lid;
end $$;

create or replace function public.landed_post(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare l public.landed_costs; st public.company_settings; fy uuid; eid uuid; a record; c record; n int := 0;
        dr_stock uuid; v_stock numeric := 0; v_cogs numeric := 0; descr text;
begin
  select * into l from public.landed_costs where id = p_id for update;
  if l.id is null then raise exception 'المستند غير موجود'; end if;
  if not public.can(l.company_id, 'landed_costs', 'post') or not public.tenant_writable() then raise exception 'ما عندك صلاحية ترحيل'; end if;
  if l.status <> 'draft' then raise exception 'المستند مرحّل من قبل'; end if;
  if public.dept_allowed(l.company_id) is not null then raise exception 'الكلفة المحمّلة للشركة كلها، مش لموظف فرع'; end if;
  if l.total <= 0 then raise exception 'ما في مصاريف'; end if;
  perform public.landed_check_invoice(l.company_id, li.invoice_id, l.doc_date) from public.landed_cost_invoices li where li.landed_id = p_id;
  perform public.ensure_company_settings(l.company_id);
  select * into st from public.company_settings where company_id = l.company_id;
  select id into fy from public.fiscal_years where company_id = l.company_id and l.doc_date between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ المستند'; end if;
  dr_stock := case when coalesce(st.perpetual_inventory, false) then st.inventory_account_id else st.purchase_account_id end;
  if dr_stock is null then raise exception 'حدّد حساب المخزون/المشتريات بشاشة «حسابات الربط»'; end if;

  delete from public.landed_cost_allocs where landed_id = p_id;
  insert into public.landed_cost_allocs (landed_id, item_id, warehouse_id, qty, base_value, amount, to_stock, to_cogs)
  select p_id, x.item_id, x.warehouse_id, x.qty, x.base_value, x.amount, x.to_stock, x.to_cogs from public.landed_preview(p_id) x where x.amount <> 0;
  if not found then raise exception 'فواتير الشراء ما فيها أصناف مخزنية'; end if;
  select coalesce(sum(to_stock), 0), coalesce(sum(to_cogs), 0) into v_stock, v_cogs from public.landed_cost_allocs where landed_id = p_id;
  if abs(v_stock + v_cogs - l.total) > 0.0005 then raise exception 'التوزيع مش مساوي للمجموع'; end if;
  -- بالجرد الدوري كل المبلغ على المشتريات
  if not coalesce(st.perpetual_inventory, false) then v_stock := v_stock + v_cogs; v_cogs := 0; end if;
  if v_cogs > 0 and st.cogs_account_id is null then raise exception 'حدّد حساب كلفة المبيعات بشاشة «حسابات الربط»'; end if;

  descr := 'كلفة محمّلة رقم ' || l.doc_no || coalesce(' - ' || nullif(l.description, ''), '');
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (l.company_id, fy, 'stock', l.doc_date, descr, 'كلفة محمّلة ' || l.doc_no, 'draft') returning id into eid;
  if v_stock > 0 then n := n + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, n, dr_stock, descr, v_stock, 0); end if;
  if v_cogs > 0 then n := n + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, n, st.cogs_account_id, descr || ' (المباع)', v_cogs, 0); end if;
  for c in select * from public.landed_cost_charges where landed_id = p_id order by line_no loop
    n := n + 1;
    insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
    values (eid, n, c.account_id, c.party_id, coalesce(nullif(c.description, ''), descr), 0, c.amount);
  end loop;
  update public.journal_entries set status = 'posted', total = l.total, posted_by = auth.uid(), posted_at = now() where id = eid;
  -- رفع قيمة المخزون بدون كمية: +1 بالمبلغ ثم −1 بصفر
  for a in select * from public.landed_cost_allocs where landed_id = p_id and to_stock > 0 loop
    insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
    values (l.company_id, a.item_id, a.warehouse_id, l.doc_date, 1, a.to_stock, 'landed_cost', p_id, 'كلفة محمّلة رقم ' || l.doc_no);
    insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
    values (l.company_id, a.item_id, a.warehouse_id, l.doc_date, -1, 0, 'landed_cost', p_id, 'كلفة محمّلة رقم ' || l.doc_no);
  end loop;
  update public.landed_costs set status = 'posted', entry_id = eid, posted_at = now() where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), l.company_id, 'ترحيل', 'landed_costs', p_id::text, jsonb_build_object('no', l.doc_no, 'total', l.total));
  return eid;
end $$;

create or replace function public.landed_cancel(p_id uuid, p_date date) returns void
language plpgsql security definer set search_path = public as $$
declare l public.landed_costs; fy uuid; eid uuid; a record; d date;
begin
  select * into l from public.landed_costs where id = p_id for update;
  if l.id is null then raise exception 'المستند غير موجود'; end if;
  if not public.can(l.company_id, 'landed_costs', 'post') or not public.tenant_writable() then raise exception 'ما عندك صلاحية'; end if;
  if l.status <> 'posted' then raise exception 'بس المستند المرحّل بينلغى'; end if;
  if public.dept_allowed(l.company_id) is not null then raise exception 'الكلفة المحمّلة للشركة كلها، مش لموظف فرع'; end if;
  if exists (select 1 from public.stock_moves m join public.landed_cost_allocs al on al.item_id = m.item_id and al.landed_id = p_id
              where m.company_id = l.company_id and m.qty < 0 and m.source_type <> 'landed_cost' and m.created_at > l.posted_at) then
    raise exception 'انباع أو طلع من هالأصناف بعد ترحيل المستند، فما بينلغى. اعمل مستند كلفة محمّلة ثاني بالفرق أو قيد تسوية';
  end if;
  if exists (select 1 from public.journal_entries where id = l.entry_id and is_frozen) then raise exception 'قيد المستند مجمّد، فك التجميد أول'; end if;
  d := coalesce(p_date, l.doc_date);
  if d < l.doc_date then raise exception 'تاريخ الإلغاء لازم يكون بعد تاريخ المستند'; end if;
  select id into fy from public.fiscal_years where company_id = l.company_id and d between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ الإلغاء'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status, reversal_of)
  values (l.company_id, fy, 'stock', d, 'إلغاء كلفة محمّلة رقم ' || l.doc_no, 'كلفة محمّلة ' || l.doc_no, 'draft', l.entry_id) returning id into eid;
  insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
  select eid, line_no, account_id, party_id, 'إلغاء: ' || coalesce(description, ''), credit, debit from public.journal_lines where entry_id = l.entry_id;
  update public.journal_entries set status = 'posted', total = l.total, posted_by = auth.uid(), posted_at = now() where id = eid;
  update public.journal_entries set status = 'reversed', reversed_by = eid where id = l.entry_id;
  for a in select * from public.landed_cost_allocs where landed_id = p_id and to_stock > 0 loop
    insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
    values (l.company_id, a.item_id, a.warehouse_id, d, 1, 0, 'landed_cost', p_id, 'إلغاء كلفة محمّلة رقم ' || l.doc_no);
    insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
    values (l.company_id, a.item_id, a.warehouse_id, d, -1, a.to_stock, 'landed_cost', p_id, 'إلغاء كلفة محمّلة رقم ' || l.doc_no);
  end loop;
  update public.landed_costs set status = 'cancelled', cancel_entry_id = eid where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), l.company_id, 'إلغاء', 'landed_costs', p_id::text, jsonb_build_object('no', l.doc_no));
end $$;

create or replace function public.landed_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l public.landed_costs;
begin
  select * into l from public.landed_costs where id = p_id for update;
  if l.id is null then raise exception 'المستند غير موجود'; end if;
  if not public.can(l.company_id, 'landed_costs', 'delete') or not public.tenant_writable() then raise exception 'ما عندك صلاحية حذف'; end if;
  if l.status <> 'draft' then raise exception 'المرحّل ما بينحذف، ألغيه'; end if;
  if public.dept_allowed(l.company_id) is not null then raise exception 'الكلفة المحمّلة للشركة كلها، مش لموظف فرع'; end if;
  delete from public.landed_costs where id = p_id;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), l.company_id, 'حذف', 'landed_costs', p_id::text, jsonb_build_object('no', l.doc_no));
end $$;

-- قيد الكلفة المحمّلة ما بينعكس ولا بينلغى ترحيله إلا من «إلغاء» المستند
create or replace function public.ab_landed_entry_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then return new; end if;
  if exists (select 1 from public.landed_costs where entry_id = old.id or cancel_entry_id = old.id) then
    if tg_op = 'DELETE' or new.status is distinct from old.status or new.reversed_by is distinct from old.reversed_by or new.is_frozen is distinct from old.is_frozen then
      raise exception 'هالقيد تابع لمستند كلفة محمّلة، ألغيه من شاشة الكلفة المحمّلة';
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists ab_landed_entry_guard on public.journal_entries;
create trigger ab_landed_entry_guard before update or delete on public.journal_entries
  for each row execute function public.ab_landed_entry_guard();

-- فاتورة الشراء المستعملة بكلفة محمّلة (مسودة أو مرحّلة) ما بينلغى ترحيلها ولا بتنلغى ولا بتنحذف
create or replace function public.ab_landed_invoice_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status and new.stock_posted is not distinct from old.stock_posted then return new; end if;
  select l.doc_no into n from public.landed_cost_invoices li join public.landed_costs l on l.id = li.landed_id
   where li.invoice_id = old.id and l.status in ('draft','posted') limit 1;
  if n is not null then raise exception 'فاتورة الشراء مستعملة بمستند الكلفة المحمّلة رقم %. ألغيه أو شيل الفاتورة منه أول', n; end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists ab_landed_invoice_guard on public.invoices;
create trigger ab_landed_invoice_guard before update of status, stock_posted or delete on public.invoices
  for each row execute function public.ab_landed_invoice_guard();

revoke all on function public.landed_preview(uuid), public.landed_save(jsonb), public.landed_post(uuid), public.landed_cancel(uuid, date), public.landed_delete(uuid) from public, anon;
grant execute on function public.landed_preview(uuid), public.landed_save(jsonb), public.landed_post(uuid), public.landed_cancel(uuid, date), public.landed_delete(uuid) to authenticated;

-- النسخة الاحتياطية: الكلفة المحمّلة بعد حركات المخزون
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
   (12, 'parties', 'company_id = $1', 'code'),
   (13, 'sales_visits', 'company_id = $1', 'started_at'),
   (14, 'item_categories', 'company_id = $1', 'code'),
   (15, 'items', 'company_id = $1', 'code'),
   (16, 'price_list_items', 'list_id in (select id from public.price_lists where company_id = $1)', 'list_id'),
   (17, 'promotions', 'company_id = $1', 'date_from'),
   (18, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (19, 'warehouses', 'company_id = $1', 'code'),
   (20, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (21, 'departments', 'company_id = $1', 'level, code'),
   (22, 'doc_types', 'company_id = $1', 'kind, code'),
   (23, 'boms', 'company_id = $1', 'code'),
   (24, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (25, 'journal_entries', 'company_id = $1', 'created_at'),
   (26, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (27, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (28, 'invoices', 'company_id = $1', 'created_at'),
   (29, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (30, 'invoice_allocations', 'company_id = $1', 'created_at'),
   (31, 'orders', 'company_id = $1', 'created_at'),
   (32, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (33, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (34, 'cheques', 'company_id = $1', 'created_at'),
   (35, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (36, 'supply_requests', 'company_id = $1', 'req_no'),
   (37, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (38, 'stock_docs', 'company_id = $1', 'created_at'),
   (39, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (40, 'stock_moves', 'company_id = $1', 'created_at'),
   (41, 'landed_costs', 'company_id = $1', 'doc_no'),
   (42, 'landed_cost_invoices', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (43, 'landed_cost_charges', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id, line_no'),
   (44, 'landed_cost_allocs', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (45, 'productions', 'company_id = $1', 'prod_no'),
   (46, 'obligations', 'company_id = $1', 'due_date'),
   (47, 'recurring_entries', 'company_id = $1', 'created_at'),
   (48, 'work_locations', 'company_id = $1', 'name'),
   (49, 'employees', 'company_id = $1', 'code'),
   (50, 'attendance', 'company_id = $1', 'day, employee_id'),
   (51, 'payroll_runs', 'company_id = $1', 'period'),
   (52, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (53, 'employee_loans', 'company_id = $1', 'loan_no'),
   (54, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (55, 'asset_custodians', 'company_id = $1', 'code'),
   (56, 'fixed_assets', 'company_id = $1', 'code'),
   (57, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (58, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (59, 'asset_movements', 'company_id = $1', 'mov_no'),
   (60, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (61, 'custody_docs', 'company_id = $1', 'doc_no'),
   (62, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (63, 'bank_recons', 'company_id = $1', 'created_at'),
   (64, 'bank_cleared', 'company_id = $1', 'line_id'),
   (65, 'message_log', 'company_id = $1', 'sent_at'),
   (66, 'attachments', 'company_id = $1', 'created_at'),
   (67, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
