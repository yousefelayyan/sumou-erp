-- =====================================================================
--  السمو ERP — المرحلة 18: الترحيل
--  • الحفظ بيخزّن بس. الترحيل بكبستين منفصلات: «ترحيل للمحاسبة» و«ترحيل للمخزون».
--  • من «الأدوات ← الترحيل»: لكل نوع سند بنختار إذا بيترحّل للمحاسبة و/أو للمخزون.
--  • إلغاء الترحيل بصلاحية خاصة (unpost) لكل شاشة: السند بيرجع مسودة وبينمسح قيده/حركته.
--  الفاتورة: status = حالة المحاسبة (draft/posted/cancelled)، وstock_posted = حالة المخزون.
--  قيد كلفة البضاعة (الجرد المستمر) صار قيد لحاله بالفاتورة: cogs_entry_id.
--  سند المخزون: status = حالة المخزون، وentry_id = قيده المحاسبي (الجرد المستمر بس).
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

alter table public.company_settings add column if not exists posting jsonb not null default '{}'::jsonb;
alter table public.invoices add column if not exists stock_posted boolean not null default false;
alter table public.invoices add column if not exists stock_posted_at timestamptz;
alter table public.invoices add column if not exists cogs_entry_id uuid references public.journal_entries(id) on delete set null;
alter table public.invoices add column if not exists cogs_in_entry boolean not null default false;  -- فواتير قديمة: الكلفة جوّا قيد الفاتورة
alter table public.invoices add column if not exists posting_ready boolean not null default false;

-- الفواتير القديمة: المرحّلة كانت بتترحّل للمخزون مع المحاسبة
do $$
begin
  if exists (select 1 from public.invoices where not posting_ready) then
    perform set_config('sumou.internal', public.internal_token(), true);
    update public.invoices i set
      stock_posted = i.status in ('posted','cancelled'),
      stock_posted_at = case when i.status in ('posted','cancelled') then i.posted_at end,
      cogs_in_entry = i.status in ('posted','cancelled') and exists (
        select 1 from public.journal_lines l where l.entry_id = i.entry_id
          and (l.description like 'كلفة البضاعة - %' or l.description like 'للمخزون - %' or l.description like 'من المخزون - %')),
      posting_ready = true
    where not i.posting_ready;
    perform set_config('sumou.internal', '', true);
  end if;
end $$;
alter table public.invoices alter column posting_ready set default false;  -- إدخال داخلي بدونها = نسخة احتياطية قديمة

-- ---------------------------------------------------------------------
-- إعدادات الترحيل لكل نوع سند (gl = للمحاسبة، stock = للمخزون)
-- ---------------------------------------------------------------------
create or replace function public.posting_flag(p_company uuid, p_kind text, p_what text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when not public.has_company(p_company) then false
    when p_what = 'stock' and p_kind in ('journal','receipt','payment') then false
    else coalesce(
      (select case when jsonb_typeof(s.posting -> p_kind -> p_what) = 'boolean' then (s.posting -> p_kind ->> p_what)::boolean end
         from public.company_settings s where s.company_id = p_company),
      true) end
$$;
revoke execute on function public.posting_flag(uuid, text, text) from public, anon;
grant execute on function public.posting_flag(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- حماية الفاتورة المرحّلة للمخزون (اسمها ab_ عشان تشتغل قبل invoices_before)
-- ---------------------------------------------------------------------
create or replace function public.ab_invoice_stock_lock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then
    if tg_op = 'DELETE' then return old; end if;
    -- استرجاع نسخة احتياطية قبل المرحلة 18: الفاتورة المرحّلة كانت مرحّلة للمخزون كمان
    if tg_op = 'INSERT' and not new.posting_ready then
      new.stock_posted := new.status in ('posted','cancelled');
      new.stock_posted_at := case when new.stock_posted then new.posted_at end;
      new.cogs_in_entry := new.stock_posted and exists (select 1 from public.journal_lines l where l.entry_id = new.entry_id
          and (l.description like 'كلفة البضاعة - %' or l.description like 'للمخزون - %' or l.description like 'من المخزون - %'));
      new.posting_ready := true;
    end if;
    return new;
  end if;
  if tg_op = 'DELETE' then
    if old.stock_posted then raise exception 'الفاتورة مرحّلة للمخزون، ما بتنحذف. ألغِ ترحيلها أول'; end if;
    return old;
  end if;
  if tg_op = 'INSERT' then
    new.stock_posted := false; new.stock_posted_at := null; new.cogs_entry_id := null; new.cogs_in_entry := false; new.posting_ready := true;
  else
    if old.stock_posted then raise exception 'الفاتورة مرحّلة للمخزون، ما بتنعدّل. ألغِ ترحيلها أول'; end if;
    new.stock_posted := old.stock_posted; new.stock_posted_at := old.stock_posted_at; new.cogs_entry_id := old.cogs_entry_id;
    new.cogs_in_entry := old.cogs_in_entry; new.posting_ready := old.posting_ready;
  end if;
  return new;
end $$;
drop trigger if exists ab_invoice_stock_lock on public.invoices;
create trigger ab_invoice_stock_lock before insert or update or delete on public.invoices
  for each row execute function public.ab_invoice_stock_lock();
revoke execute on function public.ab_invoice_stock_lock() from public, anon, authenticated;

create or replace function public.ab_invoice_lines_lock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_internal() then
    if tg_op = 'UPDATE' and new.invoice_id is distinct from old.invoice_id then raise exception 'السطر ما بينقل لفاتورة ثانية'; end if;
    if exists (select 1 from public.invoices i where i.stock_posted and i.id in (
         case when tg_op = 'INSERT' then null else old.invoice_id end, case when tg_op = 'DELETE' then null else new.invoice_id end)) then
      raise exception 'الفاتورة مرحّلة للمخزون، ما بتنعدّل سطورها';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
drop trigger if exists ab_invoice_lines_lock on public.invoice_lines;
create trigger ab_invoice_lines_lock before insert or update or delete on public.invoice_lines
  for each row execute function public.ab_invoice_lines_lock();
revoke execute on function public.ab_invoice_lines_lock() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- قيد كلفة البضاعة للفاتورة (الجرد المستمر): بينعمل لما تكون مرحّلة للمحاسبة وللمخزون
-- ---------------------------------------------------------------------
create or replace function public.invoice_cogs_sync(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invoices; st public.company_settings; v numeric; r record; descr text; eid uuid; n int;
begin
  select * into i from public.invoices where id = p_id;
  if i.id is null or i.status <> 'posted' or not i.stock_posted or i.cogs_entry_id is not null or i.cogs_in_entry then return; end if;
  select * into st from public.company_settings where company_id = i.company_id;
  if not coalesce(st.perpetual_inventory, false) then return; end if;
  select count(*) into n from public.invoice_lines l join public.items it on it.id = l.item_id
   where l.invoice_id = p_id and it.item_type = 'goods' and it.track_stock;
  if n = 0 then return; end if;
  if st.inventory_account_id is null or st.cogs_account_id is null then
    raise exception 'الجرد المستمر مفعّل: حدّد حساب المخزون وحساب كلفة البضاعة المباعة بشاشة «حسابات الربط»';
  end if;
  descr := case i.inv_type when 'sale' then 'فاتورة بيع ' when 'sale_return' then 'مرتجع بيع ' when 'purchase' then 'فاتورة شراء ' else 'مرتجع شراء ' end || coalesce(i.doc_code, i.inv_no::text);
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (i.company_id, i.fiscal_year_id, 'stock', i.inv_date, case when i.inv_type in ('sale','sale_return') then 'كلفة البضاعة - ' else 'قيمة البضاعة بالمخزون - ' end || descr, i.reference, 'draft') returning id into eid;
  if i.inv_type in ('sale','sale_return') then
    select coalesce(sum(abs(qty) * unit_cost), 0) into v from public.stock_moves where source_type = 'invoice' and source_id = p_id;
    if i.inv_type = 'sale' then perform public.add_entry_pair(eid, st.cogs_account_id, st.inventory_account_id, v, 'كلفة البضاعة - ' || descr);
    else perform public.add_entry_pair(eid, st.inventory_account_id, st.cogs_account_id, v, 'كلفة البضاعة - ' || descr); end if;
  else
    for r in
      select coalesce(case when i.inv_type = 'purchase_return' then coalesce(st.purchase_return_account_id, l.account_id) else l.account_id end, st.purchase_account_id) as acc,
             sum(l.qty * case when l.qty > 0 then round(l.subtotal / l.qty, 3) else 0 end) as amt
      from public.invoice_lines l join public.items it on it.id = l.item_id
      where l.invoice_id = p_id and it.item_type = 'goods' and it.track_stock group by 1
    loop
      if i.inv_type = 'purchase' then perform public.add_entry_pair(eid, st.inventory_account_id, r.acc, r.amt, 'للمخزون - ' || descr);
      else perform public.add_entry_pair(eid, r.acc, st.inventory_account_id, r.amt, 'من المخزون - ' || descr); end if;
    end loop;
  end if;
  if not exists (select 1 from public.journal_lines where entry_id = eid) then
    delete from public.journal_entries where id = eid;
    return;
  end if;
  if i.cost_center_id is not null then
    update public.journal_lines l set cost_center_id = i.cost_center_id
      from public.accounts a where a.id = l.account_id and l.entry_id = eid and a.category in ('revenue','expenses');
  end if;
  update public.journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = eid;
  update public.invoices set cogs_entry_id = eid where id = p_id;
end $$;
revoke execute on function public.invoice_cogs_sync(uuid) from public, anon, authenticated;

-- حركات المخزون من الفاتورة: لما تترحّل للمخزون (ولما تنلغى وهي مرحّلة للمخزون)
create or replace function public.invoice_stock_moves() returns trigger
language plpgsql security definer set search_path = public as $$
declare w uuid; sgn int; descr text;
begin
  if old.status = 'posted' and new.status = 'cancelled' then
    if new.stock_posted then
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description, is_cost)
      select company_id, item_id, warehouse_id, coalesce((select entry_date from public.journal_entries where id = new.cancel_entry_id), current_date),
             -qty, unit_cost, 'invoice_cancel', source_id, 'إلغاء: ' || coalesce(description, ''), is_cost
      from public.stock_moves where source_type = 'invoice' and source_id = new.id;
    end if;
    if new.cogs_entry_id is not null and exists (select 1 from public.journal_entries where id = new.cogs_entry_id and status = 'posted') then
      perform public.reverse_internal(new.cogs_entry_id,
        coalesce((select entry_date from public.journal_entries where id = new.cancel_entry_id), current_date),
        'إلغاء: كلفة البضاعة');
    end if;
    return null;
  end if;
  if old.stock_posted or not new.stock_posted then return null; end if;
  sgn := case when new.inv_type in ('purchase','sale_return') then 1 else -1 end;
  w := coalesce(new.warehouse_id, public.default_warehouse(new.company_id));
  descr := case new.inv_type when 'sale' then 'فاتورة بيع ' when 'sale_return' then 'مرتجع بيع ' when 'purchase' then 'فاتورة شراء ' else 'مرتجع شراء ' end || coalesce(new.doc_code, new.inv_no::text);
  insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description, is_cost)
  select new.company_id, l.item_id, w, new.inv_date, sgn * l.qty,
         case when new.inv_type in ('purchase','purchase_return') then case when l.qty > 0 then round(l.subtotal / l.qty, 3) else 0 end
              else public.item_avg_cost(new.company_id, l.item_id, new.inv_date) end,
         'invoice', new.id, descr, new.inv_type in ('purchase','purchase_return') and l.qty > 0 and l.subtotal > 0
  from public.invoice_lines l join public.items it on it.id = l.item_id
  where l.invoice_id = new.id and it.item_type = 'goods' and it.track_stock;
  return null;
end $$;
drop trigger if exists invoice_stock_moves on public.invoices;
create trigger invoice_stock_moves after update of status, stock_posted on public.invoices
  for each row execute function public.invoice_stock_moves();

-- بعد ترحيل الفاتورة للمحاسبة: نتأكد إنه النوع بيترحّل للمحاسبة، ونعمل قيد الكلفة إذا لازم
create or replace function public.invoice_gl_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'draft' and new.status = 'posted' then
    if not public.posting_flag(new.company_id, new.inv_type, 'gl') then
      raise exception 'هالنوع من الفواتير ما بيترحّل للمحاسبة (من «الأدوات ← الترحيل»)';
    end if;
    perform public.invoice_cogs_sync(new.id);
  end if;
  return null;
end $$;
drop trigger if exists invoice_gl_after on public.invoices;
create trigger invoice_gl_after after update of status on public.invoices
  for each row execute function public.invoice_gl_after();
revoke execute on function public.invoice_gl_after() from public, anon, authenticated;

-- إعادة حساب سطور الفاتورة (نفس حساب الترحيل للمحاسبة)
create or replace function public.invoice_recalc(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invoices; r record; gross numeric; sub numeric; tax numeric; s_sub numeric := 0; s_tax numeric := 0; s_disc numeric := 0;
begin
  select * into i from public.invoices where id = p_id;
  perform set_config('sumou.internal', public.internal_token(), true);
  for r in select * from public.invoice_lines where invoice_id = p_id order by line_no loop
    gross := round(r.qty * r.unit_price - r.discount, 3);
    if gross < 0 then raise exception 'الخصم أكبر من قيمة السطر %', r.line_no; end if;
    if i.prices_include_tax then sub := round(gross / (1 + r.tax_rate / 100), 3); tax := gross - sub;
    else sub := gross; tax := round(sub * r.tax_rate / 100, 3); end if;
    update public.invoice_lines set subtotal = sub, tax_amount = tax, line_total = sub + tax where id = r.id;
    s_sub := s_sub + sub; s_tax := s_tax + tax; s_disc := s_disc + r.discount;
  end loop;
  update public.invoices set subtotal = s_sub, tax_total = s_tax, discount_total = s_disc, total = s_sub + s_tax where id = p_id;
end $$;
revoke execute on function public.invoice_recalc(uuid) from public, anon, authenticated;

-- ترحيل الفاتورة للمخزون
create or replace function public.post_invoice_stock(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invoices; fy public.fiscal_years; r record;
begin
  select * into i from public.invoices where id = p_id for update;
  if i.id is null then raise exception 'الفاتورة غير موجودة'; end if;
  if not public.can(i.company_id, public.invoice_screen(i.inv_type), 'post') then raise exception 'ما عندك صلاحية ترحيل الفواتير'; end if;
  if not public.posting_flag(i.company_id, i.inv_type, 'stock') then raise exception 'هالنوع من الفواتير ما بيترحّل للمخزون (من «الأدوات ← الترحيل»)'; end if;
  if i.stock_posted then raise exception 'الفاتورة مرحّلة للمخزون من قبل'; end if;
  if i.status = 'cancelled' then raise exception 'الفاتورة ملغاة'; end if;
  select * into fy from public.fiscal_years where id = i.fiscal_year_id;
  if fy.is_closed then raise exception 'السنة المالية مغلقة'; end if;
  if not exists (select 1 from public.invoice_lines where invoice_id = p_id) then raise exception 'الفاتورة بدون سطور'; end if;
  if i.status = 'draft' then perform public.invoice_recalc(p_id); end if;
  -- المرتجع: الأصلية لازم تكون مرحّلة للمخزون، والكمية ما بتتجاوزها
  if i.original_invoice_id is not null then
    if not exists (select 1 from public.invoices o where o.id = i.original_invoice_id and o.company_id = i.company_id and o.stock_posted
                   and o.status <> 'cancelled' and o.inv_type = replace(i.inv_type, '_return', '') and o.party_id is not distinct from i.party_id) then
      raise exception 'الفاتورة الأصلية للمرتجع لازم تكون مرحّلة للمخزون ولنفس العميل/المورد';
    end if;
    for r in select l.item_id, sum(l.qty) q, max(it.name) nm from public.invoice_lines l join public.items it on it.id = l.item_id
             where l.invoice_id = p_id group by l.item_id loop
      if r.q + coalesce((select sum(rl.qty) from public.invoice_lines rl join public.invoices ri on ri.id = rl.invoice_id
                         where ri.original_invoice_id = i.original_invoice_id and ri.stock_posted and ri.status <> 'cancelled'
                           and ri.id <> p_id and rl.item_id = r.item_id), 0)
         > coalesce((select sum(o.qty) from public.invoice_lines o where o.invoice_id = i.original_invoice_id and o.item_id = r.item_id), 0) + 0.0005 then
        raise exception 'المرتجع أكثر من الفاتورة الأصلية: «%»', r.nm;
      end if;
    end loop;
  end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.invoices set stock_posted = true, stock_posted_at = now() where id = p_id;
  perform public.invoice_cogs_sync(p_id);
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), i.company_id, 'ترحيل للمخزون', public.invoice_screen(i.inv_type), p_id::text, jsonb_build_object('no', coalesce(i.doc_code, i.inv_no::text)));
end $$;
revoke execute on function public.post_invoice_stock(uuid) from public, anon;
grant execute on function public.post_invoice_stock(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- سندات المخزون: الترحيل للمخزون لحال، وللمحاسبة لحال (الجرد المستمر)
-- ---------------------------------------------------------------------
create or replace function public.post_stock_doc(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d public.stock_docs; r record; n int; diff numeric; descr text; cst numeric; fy public.fiscal_years;
begin
  select * into d from public.stock_docs where id = p_id for update;
  if d.id is null then raise exception 'السند غير موجود'; end if;
  if not public.can(d.company_id, 'inventory', 'post') then raise exception 'ما عندك صلاحية ترحيل سندات المخزون'; end if;
  if not public.posting_flag(d.company_id, 'stock_' || d.doc_type, 'stock') then raise exception 'هالنوع من السندات ما بيترحّل للمخزون (من «الأدوات ← الترحيل»)'; end if;
  if d.status <> 'draft' then raise exception 'السند مرحّل من قبل'; end if;
  select * into fy from public.fiscal_years where company_id = d.company_id and d.doc_date between start_date and end_date order by start_date desc limit 1;
  if fy.is_closed then raise exception 'السنة المالية مغلقة'; end if;
  select count(*) into n from public.stock_doc_lines where doc_id = p_id;
  if n = 0 then raise exception 'السند بدون أصناف'; end if;
  descr := case d.doc_type when 'in' then 'سند إدخال ' when 'out' then 'سند إخراج ' when 'transfer' then 'سند تحويل ' else 'جرد ' end || coalesce(d.doc_code, d.doc_no::text);
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
    else
      if r.counted_qty is null then continue; end if;
      diff := r.counted_qty - public.stock_qty(r.item_id, d.warehouse_id, d.doc_date);
      if abs(diff) > 0.0005 then
        insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
        values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, diff, cst, 'stock_doc', p_id, descr || ' (تسوية)');
      end if;
      update public.stock_doc_lines set qty = diff, unit_cost = cst where id = r.id;
    end if;
  end loop;
  update public.stock_docs set status = 'posted' where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), d.company_id, 'ترحيل للمخزون', 'inventory', p_id::text, jsonb_build_object('doc', descr));
end $$;

-- رقم القيد بسند المخزون بيتعبّى من النظام بس (اسمها ab_ عشان تشتغل قبل stock_docs_before)
create or replace function public.ab_stock_docs_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_internal() then
    if tg_op = 'INSERT' then new.entry_id := null; else new.entry_id := old.entry_id; end if;
  end if;
  return new;
end $$;
drop trigger if exists ab_stock_docs_guard on public.stock_docs;
create trigger ab_stock_docs_guard before insert or update on public.stock_docs
  for each row execute function public.ab_stock_docs_guard();
revoke execute on function public.ab_stock_docs_guard() from public, anon, authenticated;

create or replace function public.post_stock_doc_gl(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare d public.stock_docs; st public.company_settings; v numeric; eid uuid; fy uuid; contra uuid; descr text;
begin
  select * into d from public.stock_docs where id = p_id for update;
  if d.id is null then raise exception 'السند غير موجود'; end if;
  if not public.can(d.company_id, 'inventory', 'post') then raise exception 'ما عندك صلاحية ترحيل سندات المخزون'; end if;
  if not public.posting_flag(d.company_id, 'stock_' || d.doc_type, 'gl') then raise exception 'هالنوع من السندات ما بيترحّل للمحاسبة (من «الأدوات ← الترحيل»)'; end if;
  if d.status <> 'posted' then raise exception 'رحّل السند للمخزون أول، عشان تنحسب قيمته'; end if;
  if d.entry_id is not null then raise exception 'السند مرحّل للمحاسبة من قبل'; end if;
  if d.doc_type = 'transfer' then raise exception 'سند التحويل بين المستودعات ما إله قيد محاسبي'; end if;
  select * into st from public.company_settings where company_id = d.company_id;
  if not coalesce(st.perpetual_inventory, false) then raise exception 'سندات المخزون بتترحّل للمحاسبة بس لما يكون «الجرد المستمر» مفعّل (من «حسابات الربط»)'; end if;
  select coalesce(sum(qty * unit_cost), 0) into v from public.stock_moves where source_type = 'stock_doc' and source_id = p_id;
  if abs(v) < 0.0005 then raise exception 'قيمة السند صفر، ما في قيد'; end if;
  contra := coalesce(d.account_id, st.cogs_account_id);
  if st.inventory_account_id is null or contra is null then raise exception 'حدّد حساب المخزون والحساب المقابل بشاشة «حسابات الربط»'; end if;
  select id into fy from public.fiscal_years where company_id = d.company_id and d.doc_date between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ السند'; end if;
  descr := case d.doc_type when 'in' then 'سند إدخال ' when 'out' then 'سند إخراج ' else 'جرد ' end || coalesce(d.doc_code, d.doc_no::text);
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (d.company_id, fy, 'stock', d.doc_date, descr || coalesce(' - ' || nullif(d.notes, ''), ''), 'مخزون ' || coalesce(d.doc_code, d.doc_no::text), 'draft') returning id into eid;
  perform public.add_entry_pair(eid, st.inventory_account_id, contra, v, descr);
  update public.journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = eid;
  update public.stock_docs set entry_id = eid where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), d.company_id, 'ترحيل للمحاسبة', 'inventory', p_id::text, jsonb_build_object('doc', descr, 'value', v));
  return eid;
end $$;
revoke execute on function public.post_stock_doc_gl(uuid) from public, anon;
grant execute on function public.post_stock_doc_gl(uuid) to authenticated;

-- سند القيد/القبض/الصرف: نتأكد إنه النوع بيترحّل للمحاسبة
create or replace function public.entry_gl_flag_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'draft' and new.status = 'posted' and new.entry_type in ('journal','receipt','payment') and new.reversal_of is null
     and not public.posting_flag(new.company_id, new.entry_type, 'gl') then
    raise exception 'هالنوع من السندات ما بيترحّل للمحاسبة (من «الأدوات ← الترحيل»)';
  end if;
  return null;
end $$;
drop trigger if exists entry_gl_flag_check on public.journal_entries;
create trigger entry_gl_flag_check after update of status on public.journal_entries
  for each row execute function public.entry_gl_flag_check();
revoke execute on function public.entry_gl_flag_check() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- إلغاء الترحيل (صلاحية unpost)
-- ---------------------------------------------------------------------
create or replace function public.unpost_check_entry(p_entry uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries;
begin
  if p_entry is null then return; end if;
  select * into e from public.journal_entries where id = p_entry;
  if e.id is null then return; end if;
  if e.status = 'reversed' or e.reversed_by is not null then raise exception 'القيد انعكس من قبل، ما بينلغى ترحيله'; end if;
  if exists (select 1 from public.fiscal_years where id = e.fiscal_year_id and is_closed) then raise exception 'السنة المالية مغلقة'; end if;
  if exists (select 1 from public.bank_cleared c join public.journal_lines l on l.id = c.line_id where l.entry_id = p_entry) then
    raise exception 'في سطور من القيد معلّمة بالتسوية البنكية، شيل التعليم أول';
  end if;
  if exists (select 1 from public.cheque_events where entry_id = p_entry) then
    raise exception 'القيد مربوط بشيك بمحفظة الشيكات، ما بينلغى ترحيله';
  end if;
end $$;
revoke execute on function public.unpost_check_entry(uuid) from public, anon, authenticated;

create or replace function public.unpost_entry(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries;
begin
  select * into e from public.journal_entries where id = p_id for update;
  if e.id is null then raise exception 'القيد غير موجود'; end if;
  if e.entry_type not in ('journal','receipt','payment') then raise exception 'هالقيد بينعمل من شاشته (فاتورة، شيك، رواتب…)، ألغِ ترحيله من هناك'; end if;
  if not public.can(e.company_id, public.entry_screen(e.entry_type), 'unpost') then raise exception 'ما عندك صلاحية إلغاء الترحيل'; end if;
  if e.status <> 'posted' then raise exception 'القيد مش مرحّل'; end if;
  if e.reversal_of is not null then raise exception 'هاد قيد عكسي، ما بينلغى ترحيله'; end if;
  perform public.unpost_check_entry(p_id);
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.journal_entries set status = 'draft', posted_by = null, posted_at = null where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), e.company_id, 'إلغاء ترحيل', public.entry_screen(e.entry_type), p_id::text, jsonb_build_object('no', coalesce(e.doc_code, e.entry_no::text)));
end $$;

create or replace function public.unpost_invoice(p_id uuid, p_what text) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invoices;
begin
  select * into i from public.invoices where id = p_id for update;
  if i.id is null then raise exception 'الفاتورة غير موجودة'; end if;
  if not public.can(i.company_id, public.invoice_screen(i.inv_type), 'unpost') then raise exception 'ما عندك صلاحية إلغاء الترحيل'; end if;
  if i.status = 'cancelled' then raise exception 'الفاتورة ملغاة، ما بينلغى ترحيلها'; end if;
  if exists (select 1 from public.fiscal_years where id = i.fiscal_year_id and is_closed) then raise exception 'السنة المالية مغلقة'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  if p_what = 'gl' then
    if i.status <> 'posted' then raise exception 'الفاتورة مش مرحّلة للمحاسبة'; end if;
    if exists (select 1 from public.invoices r where r.original_invoice_id = p_id and r.status = 'posted') then
      raise exception 'في مرتجع مرحّل على هالفاتورة، ألغِ ترحيله أول';
    end if;
    if exists (select 1 from public.journal_entries where id = i.entry_id and (company_id <> i.company_id or entry_type <> 'invoice'))
       or exists (select 1 from public.journal_entries where id = i.cogs_entry_id and (company_id <> i.company_id or entry_type <> 'stock')) then
      raise exception 'قيد الفاتورة مش صحيح';
    end if;
    perform public.unpost_check_entry(i.entry_id);
    perform public.unpost_check_entry(i.cogs_entry_id);
    delete from public.journal_entries where id in (i.entry_id, i.cogs_entry_id);
    update public.invoices set status = 'draft', entry_id = null, cogs_entry_id = null, cogs_in_entry = false, posted_at = null where id = p_id;
  elsif p_what = 'stock' then
    if not i.stock_posted then raise exception 'الفاتورة مش مرحّلة للمخزون'; end if;
    if i.cogs_in_entry and i.status = 'posted' then
      raise exception 'كلفة البضاعة لهالفاتورة جوّا قيدها المحاسبي: ألغِ ترحيل المحاسبة أول';
    end if;
    if exists (select 1 from public.invoices r where r.original_invoice_id = p_id and r.stock_posted and r.status <> 'cancelled') then
      raise exception 'في مرتجع مرحّل للمخزون على هالفاتورة، ألغِ ترحيله أول';
    end if;
    if exists (select 1 from public.journal_entries where id = i.cogs_entry_id and (company_id <> i.company_id or entry_type <> 'stock')) then
      raise exception 'قيد الكلفة مش صحيح';
    end if;
    perform public.unpost_check_entry(i.cogs_entry_id);
    delete from public.journal_entries where id = i.cogs_entry_id;
    delete from public.stock_moves where source_type = 'invoice' and source_id = p_id;
    update public.invoices set stock_posted = false, stock_posted_at = null, cogs_entry_id = null, cogs_in_entry = false where id = p_id;
  else
    raise exception 'نوع الإلغاء غلط';
  end if;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), i.company_id, case when p_what = 'gl' then 'إلغاء ترحيل محاسبة' else 'إلغاء ترحيل مخزون' end,
          public.invoice_screen(i.inv_type), p_id::text, jsonb_build_object('no', coalesce(i.doc_code, i.inv_no::text)));
end $$;

create or replace function public.unpost_stock_doc(p_id uuid, p_what text) returns void
language plpgsql security definer set search_path = public as $$
declare d public.stock_docs;
begin
  select * into d from public.stock_docs where id = p_id for update;
  if d.id is null then raise exception 'السند غير موجود'; end if;
  if not public.can(d.company_id, 'inventory', 'unpost') then raise exception 'ما عندك صلاحية إلغاء الترحيل'; end if;
  if exists (select 1 from public.fiscal_years where company_id = d.company_id and d.doc_date between start_date and end_date and is_closed) then
    raise exception 'السنة المالية مغلقة';
  end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  if p_what = 'gl' then
    if d.entry_id is null then raise exception 'السند مش مرحّل للمحاسبة'; end if;
    if d.status <> 'posted' or not exists (select 1 from public.journal_entries where id = d.entry_id and company_id = d.company_id and entry_type = 'stock') then
      raise exception 'قيد السند مش صحيح';
    end if;
    perform public.unpost_check_entry(d.entry_id);
    delete from public.journal_entries where id = d.entry_id;
    update public.stock_docs set entry_id = null where id = p_id;
  elsif p_what = 'stock' then
    if d.status <> 'posted' then raise exception 'السند مش مرحّل للمخزون'; end if;
    if d.entry_id is not null then raise exception 'السند مرحّل للمحاسبة: ألغِ ترحيل المحاسبة أول'; end if;
    delete from public.stock_moves where source_type = 'stock_doc' and source_id = p_id;
    update public.stock_docs set status = 'draft' where id = p_id;
  else
    raise exception 'نوع الإلغاء غلط';
  end if;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), d.company_id, case when p_what = 'gl' then 'إلغاء ترحيل محاسبة' else 'إلغاء ترحيل مخزون' end,
          'inventory', p_id::text, jsonb_build_object('no', coalesce(d.doc_code, d.doc_no::text)));
end $$;

revoke execute on function public.unpost_entry(uuid), public.unpost_invoice(uuid, text), public.unpost_stock_doc(uuid, text) from public, anon;
grant execute on function public.unpost_entry(uuid), public.unpost_invoice(uuid, text), public.unpost_stock_doc(uuid, text) to authenticated;

-- ما بتنقفل السنة وفيها فواتير مرحّلة للمحاسبة ومش للمخزون (أو العكس)، أو سندات مخزون ناقصها قيد بالجرد المستمر
create or replace function public.fy_close_posting_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int; m int;
begin
  if new.is_closed and not old.is_closed then
    select count(*) into n from public.invoices i where i.fiscal_year_id = new.id and i.status <> 'cancelled'
      and ((i.status = 'posted' and not i.stock_posted and public.posting_flag(i.company_id, i.inv_type, 'stock')
            and exists (select 1 from public.invoice_lines l join public.items it on it.id = l.item_id where l.invoice_id = i.id and it.item_type = 'goods' and it.track_stock))
        or (i.stock_posted and i.status = 'draft'));
    select count(*) into m from public.stock_docs d join public.company_settings st on st.company_id = d.company_id
      where d.company_id = new.company_id and d.doc_date between new.start_date and new.end_date and d.doc_type <> 'transfer'
        and d.status = 'posted' and d.entry_id is null and st.perpetual_inventory and public.posting_flag(d.company_id, 'stock_' || d.doc_type, 'gl');
    if n > 0 or m > 0 then
      raise exception 'في % فاتورة و% سند مخزون مرحّلين ترحيل ناقص (محاسبة بدون مخزون أو العكس). كمّل ترحيلهم من «الأدوات ← الترحيل» قبل إغلاق السنة', n, m;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists fy_close_posting_check on public.fiscal_years;
create trigger fy_close_posting_check before update of is_closed on public.fiscal_years
  for each row execute function public.fy_close_posting_check();
revoke execute on function public.fy_close_posting_check() from public, anon, authenticated;
