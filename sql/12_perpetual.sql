-- =====================================================================
--  السمو ERP — المرحلة 12: الجرد المستمر (قيد كلفة البضاعة تلقائي)
--  اختياري لكل شركة من «حسابات الربط». لما يكون مفعّل:
--   • فاتورة الشراء: البضاعة بتروح لحساب المخزون بدل المشتريات
--   • فاتورة البيع: قيد كلفة البضاعة المباعة / المخزون بمتوسط الكلفة
--   • المرتجعات بالعكس، وسندات المخزون والجرد بتعمل قيد بقيمتها
-- =====================================================================

alter table public.company_settings add column if not exists perpetual_inventory boolean not null default false;
alter table public.company_settings add column if not exists inventory_account_id uuid references public.accounts(id) on delete set null;
alter table public.company_settings add column if not exists cogs_account_id uuid references public.accounts(id) on delete set null;
alter table public.stock_docs add column if not exists account_id uuid references public.accounts(id) on delete set null;   -- الحساب المقابل
alter table public.stock_docs add column if not exists entry_id uuid references public.journal_entries(id) on delete set null;
alter table public.stock_moves add column if not exists is_cost boolean not null default false;  -- بيدخل بحساب متوسط الكلفة

-- الحركات القديمة: الشراء وسندات الإدخال هي اللي بتحدد الكلفة
update public.stock_moves m set is_cost = true
 where not m.is_cost and m.qty > 0 and m.unit_cost > 0 and (
   (m.source_type = 'invoice' and exists (select 1 from public.invoices i where i.id = m.source_id and i.inv_type = 'purchase'))
   or (m.source_type = 'stock_doc' and exists (select 1 from public.stock_docs d where d.id = m.source_id and d.doc_type = 'in')));
update public.stock_moves m set is_cost = true
 where not m.is_cost and m.source_type = 'invoice_cancel' and m.qty < 0
   and exists (select 1 from public.invoices i where i.id = m.source_id and i.inv_type = 'purchase');

-- متوسط الكلفة المرجّح لصنف لحد تاريخ (وإذا ما في وارد: سعر الشراء بالصنف)
create or replace function public.item_avg_cost(p_company uuid, p_item uuid, p_date date) returns numeric
language sql stable security definer set search_path = public as $$
  select round(coalesce(
    (select case when sum(m.qty) > 0.0005 then sum(m.qty * m.unit_cost) / sum(m.qty) end
       from public.stock_moves m where m.company_id = p_company and m.item_id = p_item and m.is_cost and m.move_date <= p_date),
    (select nullif(purchase_price, 0) from public.items where id = p_item), 0), 3);
$$;

create or replace function public.ensure_company_settings(p_company uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_company(p_company) then raise exception 'ما عندك صلاحية'; end if;
  insert into public.company_settings (company_id) values (p_company) on conflict do nothing;
  update public.company_settings s set
    sales_account_id           = coalesce(s.sales_account_id,           (select id from public.accounts where company_id = p_company and code = '4101' and not is_group)),
    sales_return_account_id    = coalesce(s.sales_return_account_id,    (select id from public.accounts where company_id = p_company and code = '4102' and not is_group)),
    purchase_account_id        = coalesce(s.purchase_account_id,        (select id from public.accounts where company_id = p_company and code = '5101' and not is_group)),
    purchase_return_account_id = coalesce(s.purchase_return_account_id, (select id from public.accounts where company_id = p_company and code = '5102' and not is_group)),
    output_tax_account_id      = coalesce(s.output_tax_account_id,      (select id from public.accounts where company_id = p_company and code = '2103' and not is_group)),
    input_tax_account_id       = coalesce(s.input_tax_account_id,       (select id from public.accounts where company_id = p_company and code = '1108' and not is_group)),
    cash_account_id            = coalesce(s.cash_account_id,            (select id from public.accounts where company_id = p_company and code = '1101' and not is_group)),
    inventory_account_id       = coalesce(s.inventory_account_id,       (select id from public.accounts where company_id = p_company and code = '1105' and not is_group)),
    cogs_account_id            = coalesce(s.cogs_account_id,            (select id from public.accounts where company_id = p_company and code = '5104' and not is_group))
  where s.company_id = p_company;
end $$;

-- سطر قيد داخلي (على قيد مرحّل، والمتغير الداخلي مفعّل من اللي استدعى)
create or replace function public.add_entry_pair(p_entry uuid, p_dr uuid, p_cr uuid, p_amt numeric, p_desc text) returns void
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if p_amt is null or abs(p_amt) < 0.0005 then return; end if;
  if p_amt < 0 then perform public.add_entry_pair(p_entry, p_cr, p_dr, -p_amt, p_desc); return; end if;
  select coalesce(max(line_no), 0) into n from public.journal_lines where entry_id = p_entry;
  insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit)
  values (p_entry, n + 1, p_dr, p_desc, round(p_amt, 3), 0), (p_entry, n + 2, p_cr, p_desc, 0, round(p_amt, 3));
  update public.journal_entries set total = total + round(p_amt, 3) where id = p_entry;
end $$;
revoke execute on function public.add_entry_pair(uuid, uuid, uuid, numeric, text) from public, anon, authenticated;

-- حركات المخزون من الفاتورة (+ قيد الكلفة إذا الجرد المستمر مفعّل)
create or replace function public.invoice_stock_moves() returns trigger
language plpgsql security definer set search_path = public as $$
declare w uuid; sgn int; st public.company_settings; v numeric; r record; descr text;
begin
  if not (old.status = 'draft' and new.status = 'posted') and not (old.status = 'posted' and new.status = 'cancelled') then return null; end if;
  sgn := case when new.inv_type in ('purchase','sale_return') then 1 else -1 end;
  if new.status = 'cancelled' then   -- قيد الإلغاء العكسي بيعكس سطور الكلفة كمان لأنها بنفس قيد الفاتورة
    insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description, is_cost)
    select company_id, item_id, warehouse_id, current_date, -qty, unit_cost, 'invoice_cancel', source_id, 'إلغاء: ' || coalesce(description, ''), is_cost
    from public.stock_moves where source_type = 'invoice' and source_id = new.id;
    return null;
  end if;
  w := coalesce(new.warehouse_id, public.default_warehouse(new.company_id));
  descr := case new.inv_type when 'sale' then 'فاتورة بيع ' when 'sale_return' then 'مرتجع بيع ' when 'purchase' then 'فاتورة شراء ' else 'مرتجع شراء ' end || new.inv_no;
  -- الشراء بكلفته، والباقي بمتوسط الكلفة قبل الحركة
  insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description, is_cost)
  select new.company_id, l.item_id, w, new.inv_date, sgn * l.qty,
         case when new.inv_type = 'purchase' then case when l.qty > 0 then round(l.subtotal / l.qty, 3) else 0 end
              else public.item_avg_cost(new.company_id, l.item_id, new.inv_date) end,
         'invoice', new.id, descr, new.inv_type = 'purchase' and l.qty > 0 and l.subtotal > 0
  from public.invoice_lines l join public.items it on it.id = l.item_id
  where l.invoice_id = new.id and it.item_type = 'goods' and it.track_stock;

  select * into st from public.company_settings where company_id = new.company_id;
  if not coalesce(st.perpetual_inventory, false) or new.entry_id is null then return null; end if;
  if st.inventory_account_id is null or st.cogs_account_id is null then
    raise exception 'الجرد المستمر مفعّل: حدّد حساب المخزون وحساب كلفة البضاعة المباعة بشاشة «حسابات الربط»';
  end if;
  if new.inv_type in ('sale','sale_return') then
    select coalesce(sum(abs(qty) * unit_cost), 0) into v from public.stock_moves where source_type = 'invoice' and source_id = new.id;
    if new.inv_type = 'sale' then perform public.add_entry_pair(new.entry_id, st.cogs_account_id, st.inventory_account_id, v, 'كلفة البضاعة - ' || descr);
    else perform public.add_entry_pair(new.entry_id, st.inventory_account_id, st.cogs_account_id, v, 'كلفة البضاعة - ' || descr); end if;
  else
    -- إعادة تصنيف قيمة البضاعة من المشتريات/مردوداتها للمخزون
    for r in
      select coalesce(case when new.inv_type = 'purchase_return' then coalesce(st.purchase_return_account_id, l.account_id) else l.account_id end, st.purchase_account_id) as acc,
             sum(l.subtotal) as amt
      from public.invoice_lines l join public.items it on it.id = l.item_id
      where l.invoice_id = new.id and it.item_type = 'goods' and it.track_stock group by 1
    loop
      if new.inv_type = 'purchase' then perform public.add_entry_pair(new.entry_id, st.inventory_account_id, r.acc, r.amt, 'للمخزون - ' || descr);
      else perform public.add_entry_pair(new.entry_id, r.acc, st.inventory_account_id, r.amt, 'من المخزون - ' || descr); end if;
    end loop;
  end if;
  return null;
end $$;

-- ترحيل سند مخزون (+ قيد بقيمته إذا الجرد المستمر مفعّل)
create or replace function public.post_stock_doc(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d public.stock_docs; r record; n int; diff numeric; descr text; cst numeric; st public.company_settings;
        v numeric; eid uuid; fy uuid; contra uuid;
begin
  select * into d from public.stock_docs where id = p_id for update;
  if d.id is null then raise exception 'السند غير موجود'; end if;
  if not public.can(d.company_id, 'inventory', 'post') then raise exception 'ما عندك صلاحية ترحيل سندات المخزون'; end if;
  if d.status <> 'draft' then raise exception 'السند مرحّل من قبل'; end if;
  select count(*) into n from public.stock_doc_lines where doc_id = p_id;
  if n = 0 then raise exception 'السند بدون أصناف'; end if;
  descr := case d.doc_type when 'in' then 'سند إدخال ' when 'out' then 'سند إخراج ' when 'transfer' then 'سند تحويل ' else 'جرد ' end || d.doc_no;
  perform set_config('sumou.internal', public.internal_token(), true);
  for r in select * from public.stock_doc_lines where doc_id = p_id order by line_no loop
    cst := public.item_avg_cost(d.company_id, r.item_id, d.doc_date);
    if d.doc_type = 'in' then
      if r.qty <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
      cst := coalesce(nullif(r.unit_cost, 0), cst);
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description, is_cost)
      values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, r.qty, cst, 'stock_doc', p_id, descr, cst > 0);
    elsif d.doc_type = 'out' then
      if r.qty <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
      values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, -r.qty, cst, 'stock_doc', p_id, descr);
    elsif d.doc_type = 'transfer' then
      if r.qty <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
      values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, -r.qty, cst, 'stock_doc', p_id, descr),
             (d.company_id, r.item_id, d.to_warehouse_id, d.doc_date, r.qty, cst, 'stock_doc', p_id, descr);
    else   -- جرد: الفرق بين الفعلي والدفتري، بمتوسط الكلفة
      if r.counted_qty is null then continue; end if;
      diff := r.counted_qty - public.stock_qty(r.item_id, d.warehouse_id, d.doc_date);
      if abs(diff) > 0.0005 then
        insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
        values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, diff, cst, 'stock_doc', p_id, descr || ' (تسوية)');
      end if;
      update public.stock_doc_lines set qty = diff, unit_cost = cst where id = r.id;
    end if;
  end loop;

  -- القيد المحاسبي
  select * into st from public.company_settings where company_id = d.company_id;
  if coalesce(st.perpetual_inventory, false) and d.doc_type <> 'transfer' then
    select coalesce(sum(qty * unit_cost), 0) into v from public.stock_moves where source_type = 'stock_doc' and source_id = p_id;
    if abs(v) >= 0.0005 then
      contra := coalesce(d.account_id, st.cogs_account_id);
      if st.inventory_account_id is null or contra is null then raise exception 'حدّد حساب المخزون والحساب المقابل بشاشة «حسابات الربط»'; end if;
      select id into fy from public.fiscal_years where company_id = d.company_id and d.doc_date between start_date and end_date and not is_closed order by start_date desc limit 1;
      if fy is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ السند'; end if;
      insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
      values (d.company_id, fy, 'stock', d.doc_date, descr || coalesce(' - ' || nullif(d.notes, ''), ''), 'مخزون ' || d.doc_no, 'draft') returning id into eid;
      perform public.add_entry_pair(eid, st.inventory_account_id, contra, v, descr);
      update public.journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = eid;
    end if;
  end if;
  update public.stock_docs set status = 'posted', entry_id = eid where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), d.company_id, 'ترحيل', 'inventory', p_id::text, jsonb_build_object('doc', descr, 'value', v));
end $$;

-- رصيد المخزون: الكمية ومتوسط الكلفة والقيمة
create or replace function public.rep_stock_balance(p_company uuid, p_date date, p_wh uuid default null)
returns table (item_id uuid, warehouse_id uuid, qty numeric, avg_cost numeric, value numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'inventory', 'view') then raise exception 'ما عندك صلاحية على المخزون'; end if;
  return query
  select m.item_id, m.warehouse_id, sum(m.qty), public.item_avg_cost(p_company, m.item_id, p_date),
         round(sum(m.qty) * public.item_avg_cost(p_company, m.item_id, p_date), 3)
  from public.stock_moves m
  where m.company_id = p_company and m.move_date <= p_date and (p_wh is null or m.warehouse_id = p_wh)
  group by m.item_id, m.warehouse_id having abs(sum(m.qty)) > 0.0005;
end $$;

grant execute on function public.item_avg_cost(uuid, uuid, date) to authenticated;
