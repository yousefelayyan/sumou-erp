-- =====================================================================
--  السمو ERP — المرحلة 29: نقاط البيع (الكاشير)
--  شاشة لمس: فئات وأصناف بالصور، سلة، دفع نقدي/بطاقة، حفظ = فاتورة بيع نقدية
--  مرحّلة للمحاسبة وللمخزون بنفس العملية، ووصل على طابعة الرول.
--  profiles.pos_only (بالمرحلة 28) = المستخدم بيشوف نقطة البيع بس.
--  صلاحيتها شاشة pos (قسم المبيعات). الكاشير ما بيحتاج صلاحية إضافة/ترحيل فواتير:
--  pos_checkout (security definer) بيرحّل عن طريق السر sumou.pos (pos_ok).
-- =====================================================================

alter table public.items add column if not exists image text;   -- صورة مصغّرة (data:image/jpeg;base64…)
do $$ begin
  if exists (select 1 from pg_constraint where conname = 'items_image_chk' and pg_get_constraintdef(oid) not like '%150000%') then
    alter table public.items drop constraint items_image_chk;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'items_image_chk') then
    alter table public.items add constraint items_image_chk
      check (image is null or (length(image) <= 150000 and image ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$'));
  end if;
end $$;

alter table public.company_settings add column if not exists pos jsonb not null default '{}'::jsonb;
alter table public.invoices add column if not exists pos boolean not null default false;
alter table public.invoices add column if not exists pos_paid numeric(18,3);
alter table public.invoices add column if not exists pos_method text;          -- اسم وسيلة الدفع وقت البيع
alter table public.invoices drop constraint if exists invoices_pos_method_check;
alter table public.invoices add column if not exists pos_method_id uuid references public.lookups(id) on delete set null;

-- وسائل الدفع: اسم ظاهر بنقطة البيع، ووين بتظهر (فواتير المبيعات / المشتريات / نقطة البيع)
alter table public.lookups add column if not exists pos_label text;
alter table public.lookups add column if not exists use_sales boolean not null default true;
alter table public.lookups add column if not exists use_purchases boolean not null default true;
alter table public.lookups add column if not exists use_pos boolean not null default false;

-- مجموعة «كاشير» جاهزة لكل مشترك (بدون إضافة/ترحيل فواتير مباشرة)
do $$
declare t record; prev text := current_setting('sumou.internal', true);
begin
  perform set_config('sumou.internal', public.internal_token(), true);
  for t in select id from public.tenants loop
    insert into public.user_groups (name, description, permissions, tenant_id)
    select 'كاشير', 'نقطة البيع: بيع نقدي وطباعة الوصل',
      '{"pos":{"view":true,"add":true,"print":true},"sales_invoices":{"view":true,"print":true},"items":{"view":true},"customers":{"view":true}}'::jsonb, t.id
    where not exists (select 1 from public.user_groups g where g.tenant_id = t.id and g.name = 'كاشير');
  end loop;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
end $$;

-- السر اللي بيسمح لـ post_invoice/post_invoice_stock يرحّلوا فاتورة نقطة البيع
create or replace function public.pos_ok(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(current_setting('sumou.pos', true), '') = public.internal_token() || ':' || cid::text;
$$;
revoke execute on function public.pos_ok(uuid) from public, anon, authenticated;

-- حماية: حقول نقطة البيع بتنكتب من pos_checkout بس، والمستودع لازم من نفس الشركة
create or replace function public.invoice_pos_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then return old; end if;
  if not public.is_internal() and not public.pos_ok(new.company_id) then
    if tg_op = 'INSERT' then new.pos := false; new.pos_paid := null; new.pos_method := null; new.pos_method_id := null;
    else new.pos := old.pos; new.pos_paid := old.pos_paid; new.pos_method := old.pos_method; new.pos_method_id := old.pos_method_id; end if;
  end if;
  if new.warehouse_id is not null and (tg_op = 'INSERT' or new.warehouse_id is distinct from old.warehouse_id)
     and not exists (select 1 from public.warehouses w where w.id = new.warehouse_id and w.company_id = new.company_id) then
    raise exception 'المستودع مش من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists ab_invoice_pos_guard on public.invoices;
create trigger ab_invoice_pos_guard before insert or update on public.invoices
  for each row execute function public.invoice_pos_guard();

-- اليوم بتوقيت الأردن (قاعدة البيانات على UTC)
create or replace function public.local_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Amman')::date; $$;

-- البيع من نقطة البيع: فاتورة نقدية + ترحيل للمحاسبة والمخزون بعملية وحدة
create or replace function public.pos_checkout(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cid uuid; fy uuid; d date := public.local_today();
  st public.company_settings; cfg jsonb; iid uuid; l jsonb; it public.items; n int := 0;
  qty numeric; price numeric; disc numeric; rate numeric; gross numeric; sub numeric; tax numeric; paid numeric;
  s_sub numeric := 0; s_tax numeric := 0; s_disc numeric := 0; incl boolean; meth text; acc uuid; wh uuid; inv public.invoices;
  can_edit boolean; can_disc boolean; inv_disc numeric := 0; tot_g numeric; share numeric; left_d numeric; xl record; k int;
  pty public.parties; pay_type text := 'cash'; rep_id uuid; pm public.lookups; is_cash boolean; mname text; prev text := current_setting('sumou.pos', true); lines jsonb;
begin
  begin
    cid := (p ->> 'company_id')::uuid; fy := (p ->> 'fiscal_year_id')::uuid; paid := nullif(p ->> 'paid', '')::numeric;
  exception when others then raise exception 'بيانات البيع مش صحيحة';
  end;
  if cid is null or not public.can(cid, 'pos', 'add') then raise exception 'ما عندك صلاحية البيع من نقطة البيع'; end if;
  if coalesce(jsonb_typeof(p -> 'lines'), '') <> 'array' or jsonb_array_length(p -> 'lines') = 0 then raise exception 'السلة فاضية'; end if;
  if jsonb_array_length(p -> 'lines') > 300 then raise exception 'السلة كبيرة كثير'; end if;
  if not exists (select 1 from public.fiscal_years where id = fy and company_id = cid and not is_closed and d between start_date and end_date) then
    raise exception 'لازم تكون على السنة المالية المفتوحة اللي فيها تاريخ اليوم';
  end if;
  can_edit := public.can(cid, 'sales_invoices', 'edit');
  can_disc := can_edit or public.can(cid, 'pos', 'edit');   -- الخصم: صلاحية «تعديل» على نقطة البيع
  begin inv_disc := round(greatest(coalesce(nullif(p ->> 'discount', '')::numeric, 0), 0), 3);
  exception when others then raise exception 'الخصم مش صحيح'; end;
  if inv_disc > 0 and not can_disc then raise exception 'ما عندك صلاحية تعمل خصم'; end if;
  -- مندوب المبيعات (اختياري)
  if nullif(p ->> 'sales_rep_id', '') is not null then
    begin rep_id := (p ->> 'sales_rep_id')::uuid; exception when invalid_text_representation then raise exception 'المندوب مش صحيح'; end;
    if not exists (select 1 from public.lookups r where r.id = rep_id and r.company_id = cid and r.kind = 'sales_rep' and r.is_active) then raise exception 'المندوب مش موجود'; end if;
  end if;
  -- الزبون (بطاقة عميل) اختياري للنقدي، ولازم للآجل
  if nullif(p ->> 'party_id', '') is not null then
    begin select * into pty from public.parties where id = (p ->> 'party_id')::uuid;
    exception when invalid_text_representation then raise exception 'الزبون مش صحيح'; end;
    if pty.id is null or pty.company_id <> cid or pty.party_type <> 'customer' or not pty.is_active then raise exception 'الزبون مش موجود'; end if;
  end if;
  perform public.ensure_company_settings(cid);
  select * into st from public.company_settings where company_id = cid;
  cfg := coalesce(st.pos, '{}'::jsonb);
  incl := coalesce((cfg ->> 'prices_include_tax')::boolean, true);
  if p ->> 'method' = 'credit' then
    -- آجل: على حساب الزبون
    if pty.id is null then raise exception 'البيع الآجل لازم تختار الزبون'; end if;
    if coalesce((cfg ->> 'allow_credit')::boolean, true) is false then raise exception 'البيع الآجل مسكّر بإعدادات نقطة البيع'; end if;
    meth := 'credit'; pay_type := 'credit'; acc := null; mname := 'آجل';
  elsif nullif(p ->> 'method_id', '') is not null then
    -- وسيلة دفع من «إعداد ← وسائل الدفع» (مأشّر عليها «نقطة البيع»)، وحسابها هو الطرف المدين
    begin select * into pm from public.lookups where id = (p ->> 'method_id')::uuid;
    exception when invalid_text_representation then raise exception 'وسيلة الدفع مش صحيحة'; end;
    if pm.id is null or pm.company_id <> cid or pm.kind <> 'payment_method' or not pm.is_active or not pm.use_pos or pm.account_id is null then
      raise exception 'وسيلة الدفع مش متاحة بنقطة البيع';
    end if;
    acc := pm.account_id; mname := coalesce(nullif(pm.pos_label, ''), pm.name); meth := 'method';
    if not exists (select 1 from public.accounts a where a.id = acc and a.company_id = cid and not a.is_group and a.is_active) then
      raise exception 'حساب وسيلة الدفع «%» لازم يكون حساب فرعي فعّال من نفس الشركة', mname;
    end if;
  else
    meth := coalesce(nullif(p ->> 'method', ''), 'cash');
    if meth not in ('cash', 'card') then raise exception 'طريقة الدفع مش صحيحة'; end if;
    acc := case when meth = 'card' then coalesce(nullif(cfg ->> 'card_account_id', '')::uuid, nullif(cfg ->> 'cash_account_id', '')::uuid, st.cash_account_id)
                else coalesce(nullif(cfg ->> 'cash_account_id', '')::uuid, st.cash_account_id) end;
    mname := case meth when 'card' then 'بطاقة' else 'نقدي' end;
    if acc is null then raise exception 'حدد صندوق نقطة البيع من «إعدادات نقطة البيع»'; end if;
    if not exists (select 1 from public.accounts a where a.id = acc and a.company_id = cid and not a.is_group and a.is_active and a.account_type in ('cash', 'bank')) then
      raise exception 'حساب الصندوق/البطاقات بإعدادات نقطة البيع لازم يكون حساب صندوق أو بنك فرعي من نفس الشركة';
    end if;
  end if;
  -- الباقي بس للوسائل اللي حسابها صندوق نقدي
  is_cash := meth <> 'credit' and (exists (select 1 from public.accounts a where a.id = acc and a.account_type = 'cash') or meth = 'cash');
  wh := nullif(cfg ->> 'warehouse_id', '')::uuid;
  if wh is not null and not exists (select 1 from public.warehouses w where w.id = wh and w.company_id = cid) then
    raise exception 'مستودع نقطة البيع مش من نفس الشركة';
  end if;

  perform set_config('sumou.pos', public.internal_token() || ':' || cid::text, true);
  insert into public.invoices (company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id, party_name, cash_account_id,
                               prices_include_tax, warehouse_id, notes, reference, pos, pos_method, sales_rep_id)
  values (cid, fy, 'sale', d, pay_type, pty.id, case when pay_type = 'cash' then coalesce(left(nullif(trim(p ->> 'party_name'), ''), 120), pty.name) end, acc,
          incl, wh, left(nullif(trim(p ->> 'notes'), ''), 500), 'نقطة بيع', true, mname, rep_id)
  returning id into iid;

  for l in select * from jsonb_array_elements(p -> 'lines') loop
    n := n + 1;
    begin
      select * into it from public.items where id = (l ->> 'item_id')::uuid and company_id = cid and is_active;
      qty := round(coalesce((l ->> 'qty')::numeric, 0), 3);
      price := round(coalesce((l ->> 'price')::numeric, it.sale_price), 3);
      disc := round(greatest(coalesce((l ->> 'discount')::numeric, 0), 0), 3);
    exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'سطر % مش صحيح', n;
    end;
    if it.id is null then raise exception 'صنف مش موجود أو موقوف (سطر %)', n; end if;
    if qty <= 0 or qty > 100000 then raise exception 'الكمية مش منطقية (%)', it.name; end if;
    -- السعر والخصم من الصنف إلا إذا معه صلاحية تعديل الفواتير
    if not can_edit then price := it.sale_price; end if;
    if not can_disc then disc := 0; end if;
    if price < 0 then raise exception 'السعر سالب (%)', it.name; end if;
    rate := it.tax_rate;
    gross := round(qty * price - disc, 3);
    if gross < 0 then raise exception 'الخصم أكبر من قيمة السطر (%)', it.name; end if;
    if incl then sub := round(gross / (1 + rate / 100), 3); tax := gross - sub; else sub := gross; tax := round(sub * rate / 100, 3); end if;
    insert into public.invoice_lines (invoice_id, line_no, item_id, description, qty, unit_price, discount, tax_rate, account_id, subtotal, tax_amount, line_total)
    values (iid, n, it.id, it.name, qty, price, disc, rate, it.sales_account_id, sub, tax, sub + tax);
    s_sub := s_sub + sub; s_tax := s_tax + tax; s_disc := s_disc + disc;
  end loop;
  -- خصم على الفاتورة كلها: بيتوزّع على السطور حسب قيمتها
  if inv_disc > 0 then
    select sum(round(x.qty * x.unit_price - x.discount, 3)) into tot_g from public.invoice_lines x where x.invoice_id = iid;
    if inv_disc > tot_g then raise exception 'الخصم (%) أكبر من مجموع الفاتورة (%)', inv_disc, tot_g; end if;
    left_d := inv_disc; k := 0; s_sub := 0; s_tax := 0; s_disc := 0;
    for xl in select * from public.invoice_lines x where x.invoice_id = iid order by x.line_no loop
      k := k + 1;
      gross := round(xl.qty * xl.unit_price - xl.discount, 3);
      share := case when k = n then left_d else least(left_d, round(inv_disc * gross / nullif(tot_g, 0), 3)) end;
      share := least(share, gross); left_d := left_d - share;
      gross := gross - share;
      if incl then sub := round(gross / (1 + xl.tax_rate / 100), 3); tax := gross - sub; else sub := gross; tax := round(sub * xl.tax_rate / 100, 3); end if;
      update public.invoice_lines set discount = xl.discount + share, subtotal = sub, tax_amount = tax, line_total = sub + tax where id = xl.id;
      s_sub := s_sub + sub; s_tax := s_tax + tax; s_disc := s_disc + xl.discount + share;
    end loop;
  end if;
  update public.invoices set pos_method_id = pm.id where id = iid and pm.id is not null;
  if is_cash then
    paid := coalesce(paid, s_sub + s_tax);
    if paid + 0.0005 < s_sub + s_tax then raise exception 'المدفوع (%) أقل من المطلوب (%)', paid, s_sub + s_tax; end if;
  elsif meth = 'credit' then paid := 0;
  else paid := s_sub + s_tax; end if;
  update public.invoices set subtotal = s_sub, tax_total = s_tax, discount_total = s_disc, total = s_sub + s_tax, pos_paid = paid where id = iid;

  perform public.post_invoice(iid);
  if public.posting_flag(cid, 'sale', 'stock') then perform public.post_invoice_stock(iid); end if;
  perform set_config('sumou.pos', coalesce(prev, ''), true);
  select * into inv from public.invoices where id = iid;
  select jsonb_agg(jsonb_build_object('name', x.description, 'qty', x.qty, 'price', x.unit_price, 'discount', x.discount, 'total', round(x.qty * x.unit_price - x.discount, 3)) order by x.line_no)
    into lines from public.invoice_lines x where x.invoice_id = iid;
  return jsonb_build_object('id', inv.id, 'no', inv.inv_no, 'doc_code', inv.doc_code, 'total', inv.total, 'subtotal', inv.subtotal,
    'tax', inv.tax_total, 'discount', inv.discount_total, 'paid', inv.pos_paid, 'change', inv.pos_paid - inv.total,
    'stock_posted', inv.stock_posted, 'method', inv.pos_method, 'customer', pty.name, 'customer_phone', coalesce(pty.mobile, pty.phone), 'created_at', inv.created_at, 'lines', lines);
end $$;
revoke execute on function public.pos_checkout(jsonb) from public, anon;
grant execute on function public.pos_checkout(jsonb) to authenticated;
