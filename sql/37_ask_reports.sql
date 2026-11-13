-- =====================================================================
--  السمو ERP — المرحلة 37: «اسأل السمو» (تقارير المبيعات بالكلام) + رصيد الأصناف للتنبيه بالفاتورة
-- =====================================================================

-- الرصيد المتوفر لأصناف بمستودع (لتنبيه «الكمية المطلوبة أكبر من المتوفرة»)
create or replace function public.items_available(p_company uuid, p_warehouse uuid, p_date date, p_items uuid[])
returns table (item_id uuid, code text, name text, available numeric)
language plpgsql stable security definer set search_path = public as $$
declare w uuid := p_warehouse;
begin
  if not (public.can(p_company, 'items', 'view') or public.can(p_company, 'inventory', 'view') or public.can(p_company, 'sales_invoices', 'add') or public.can(p_company, 'sales_invoices', 'edit')) then
    raise exception 'ما عندك صلاحية';
  end if;
  if w is null then select x.id into w from public.warehouses x where x.company_id = p_company and x.is_active order by x.code limit 1; end if;
  if w is null or not exists (select 1 from public.warehouses x where x.id = w and x.company_id = p_company) then return; end if;
  return query
  select i.id, i.code, i.name, public.stock_qty(i.id, w, coalesce(p_date, public.local_today()))
    from public.items i where i.company_id = p_company and i.id = any(p_items) and i.item_type = 'goods' and i.track_stock;
end $$;
revoke execute on function public.items_available(uuid, uuid, date, uuid[]) from public, anon;
grant execute on function public.items_available(uuid, uuid, date, uuid[]) to authenticated;

-- تجميع المبيعات المرحّلة (البيع ناقص المرتجع) حسب بُعد، مع فلاتر.
-- p_group: customer | item | item_category | customer_category | rep | department | warehouse | month | day | none
-- p_filters: {rep_id, party_id, item_id, item_category_id, party_category_id, department_id}
create or replace function public.ask_sales(p_company uuid, p_from date, p_to date, p_group text, p_filters jsonb default '{}'::jsonb, p_top int default null, p_group2 text default null)
returns table (k1 text, k2 text, label1 text, label2 text, qty numeric, net numeric, tax numeric, invoices bigint)
language plpgsql stable security definer set search_path = public as $$
declare f jsonb := coalesce(p_filters, '{}'::jsonb);
begin
  if not (public.can(p_company, 'sales_invoices', 'view') or public.can(p_company, 'reports', 'view')) then raise exception 'ما عندك صلاحية تقارير المبيعات'; end if;
  if coalesce(p_group, 'none') not in ('customer','item','item_category','customer_category','rep','department','warehouse','month','day','none')
     or coalesce(p_group2, 'none') not in ('customer','item','item_category','customer_category','rep','department','warehouse','month','day','none') then
    raise exception 'نوع التجميع مش معروف';
  end if;
  return query
  with l as (
    select v.id inv_id, v.inv_date, v.party_id, v.party_name, v.sales_rep_id, v.department_id, coalesce(v.warehouse_id, (select w.id from public.warehouses w where w.company_id = v.company_id and w.is_active order by w.code limit 1)) wh,
           il.item_id, il.description,
           case when v.inv_type = 'sale_return' then -1 else 1 end sgn, il.qty, il.subtotal, il.tax_amount
      from public.invoices v join public.invoice_lines il on il.invoice_id = v.id
     where v.company_id = p_company and v.inv_type in ('sale','sale_return') and v.status = 'posted'
       and v.inv_date between p_from and p_to
       and (f ->> 'rep_id' is null or v.sales_rep_id = (f ->> 'rep_id')::uuid)
       and (f ->> 'party_id' is null or v.party_id = (f ->> 'party_id')::uuid)
       and (f ->> 'department_id' is null or v.department_id = (f ->> 'department_id')::uuid)
       and (f ->> 'item_id' is null or il.item_id = (f ->> 'item_id')::uuid)
       and (f ->> 'item_category_id' is null or exists (select 1 from public.items i where i.id = il.item_id and i.category_id = (f ->> 'item_category_id')::uuid))
       and (f ->> 'party_category_id' is null or exists (select 1 from public.parties p where p.id = v.party_id and p.category_id = (f ->> 'party_category_id')::uuid))
  ), d as (
    select l.*, p.name pname, p.code pcode, p.category_id pcat, i.name iname, i.code icode, i.category_id icat
      from l left join public.parties p on p.id = l.party_id left join public.items i on i.id = l.item_id
  ), g as (
    select
      case p_group when 'customer' then coalesce(d.party_id::text, 'cash:' || coalesce(d.party_name, '')) when 'item' then coalesce(d.item_id::text, 'd:' || coalesce(d.description, ''))
        when 'item_category' then coalesce(d.icat::text, '-') when 'customer_category' then coalesce(d.pcat::text, '-') when 'rep' then coalesce(d.sales_rep_id::text, '-')
        when 'department' then coalesce(d.department_id::text, '-') when 'warehouse' then d.wh::text when 'month' then to_char(d.inv_date, 'YYYY-MM') when 'day' then d.inv_date::text else 'all' end a1,
      case p_group2 when 'customer' then coalesce(d.party_id::text, 'cash:' || coalesce(d.party_name, '')) when 'item' then coalesce(d.item_id::text, 'd:' || coalesce(d.description, ''))
        when 'item_category' then coalesce(d.icat::text, '-') when 'customer_category' then coalesce(d.pcat::text, '-') when 'rep' then coalesce(d.sales_rep_id::text, '-')
        when 'department' then coalesce(d.department_id::text, '-') when 'warehouse' then d.wh::text when 'month' then to_char(d.inv_date, 'YYYY-MM') when 'day' then d.inv_date::text else '' end a2,
      d.*
      from d
  ), s as (
    select a1, a2, sum(sgn * g.qty) q, sum(sgn * g.subtotal) n, sum(sgn * g.tax_amount) t, count(distinct inv_id) c from g group by a1, a2
  ), lab as (
    select s.*,
      (select case p_group
          when 'customer' then coalesce((select x.name from public.parties x where x.id::text = s.a1 and x.company_id = p_company), nullif(replace(s.a1, 'cash:', ''), ''), 'زبون نقدي')
          when 'item' then coalesce((select x.code || ' — ' || x.name from public.items x where x.id::text = s.a1 and x.company_id = p_company), nullif(replace(s.a1, 'd:', ''), ''), 'بدون صنف')
          when 'item_category' then coalesce((select x.name from public.item_categories x where x.id::text = s.a1 and x.company_id = p_company), 'بدون فئة')
          when 'customer_category' then coalesce((select x.name from public.party_categories x where x.id::text = s.a1 and x.company_id = p_company), 'بدون فئة')
          when 'rep' then coalesce((select x.name from public.lookups x where x.id::text = s.a1 and x.company_id = p_company), 'بدون مندوب')
          when 'department' then coalesce((select x.name from public.departments x where x.id::text = s.a1 and x.company_id = p_company), 'بدون دائرة')
          when 'warehouse' then coalesce((select x.name from public.warehouses x where x.id::text = s.a1 and x.company_id = p_company), '')
          when 'none' then 'الإجمالي' else s.a1 end) l1,
      (select case p_group2
          when 'customer' then coalesce((select x.name from public.parties x where x.id::text = s.a2 and x.company_id = p_company), nullif(replace(s.a2, 'cash:', ''), ''), 'زبون نقدي')
          when 'item' then coalesce((select x.code || ' — ' || x.name from public.items x where x.id::text = s.a2 and x.company_id = p_company), nullif(replace(s.a2, 'd:', ''), ''), 'بدون صنف')
          when 'item_category' then coalesce((select x.name from public.item_categories x where x.id::text = s.a2 and x.company_id = p_company), 'بدون فئة')
          when 'customer_category' then coalesce((select x.name from public.party_categories x where x.id::text = s.a2 and x.company_id = p_company), 'بدون فئة')
          when 'rep' then coalesce((select x.name from public.lookups x where x.id::text = s.a2 and x.company_id = p_company), 'بدون مندوب')
          when 'department' then coalesce((select x.name from public.departments x where x.id::text = s.a2 and x.company_id = p_company), 'بدون دائرة')
          when 'warehouse' then coalesce((select x.name from public.warehouses x where x.id::text = s.a2 and x.company_id = p_company), '')
          else s.a2 end) l2
      from s
  )
  select a1, a2, l1, l2, round(q, 3), round(n, 3), round(t, 3), c from lab
   order by case when p_group in ('month', 'day') then a1 end, n desc nulls last
   limit coalesce(p_top, 5000);
end $$;
revoke execute on function public.ask_sales(uuid, date, date, text, jsonb, int, text) from public, anon;
grant execute on function public.ask_sales(uuid, date, date, text, jsonb, int, text) to authenticated;

-- سجل أسئلة المستخدم (لكل شركة)
create table if not exists public.ask_history (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id    uuid not null default auth.uid(),
  question   text not null check (length(question) <= 500),
  created_at timestamptz not null default now()
);
create index if not exists ask_history_user on public.ask_history (user_id, company_id, created_at desc);
alter table public.ask_history enable row level security;
grant select, insert, delete on public.ask_history to authenticated;
drop policy if exists ah_select on public.ask_history;
create policy ah_select on public.ask_history for select to authenticated using (user_id = auth.uid() and public.has_company(company_id));
drop policy if exists ah_insert on public.ask_history;
create policy ah_insert on public.ask_history for insert to authenticated with check (user_id = auth.uid() and public.has_company(company_id));
drop policy if exists ah_delete on public.ask_history;
create policy ah_delete on public.ask_history for delete to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------------
--  حذف الشركة: مسموح بس إذا ما فيها ولا حركة (قيود، فواتير، سندات مخزون، شيكات، رواتب، أصول، طلبات…)
-- ---------------------------------------------------------------------
create or replace function public.company_activity_raw(p_company uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb := '{}'::jsonb; n bigint; t record;
begin
  for t in select * from (values ('journal_entries', 'قيود وسندات'), ('invoices', 'فواتير'), ('stock_docs', 'سندات مخزون'), ('cheques', 'شيكات'),
             ('payroll_runs', 'مسيّرات رواتب'), ('depreciation_runs', 'دورات استهلاك'), ('orders', 'طلبات بيع/شراء'), ('asset_movements', 'حركات أصول'),
             ('custody_docs', 'مستندات عهد'), ('supply_requests', 'طلبات تزويد'), ('service_tickets', 'بطاقات صيانة'), ('productions', 'أوامر إنتاج'),
             ('stock_moves', 'حركات مخزون')) v(tbl, label) loop
    if to_regclass('public.' || t.tbl) is null then continue; end if;
    execute format('select count(*) from public.%I where company_id = $1', t.tbl) into n using p_company;
    if n > 0 then r := r || jsonb_build_object(t.label, n); end if;
  end loop;
  return r;
end $$;
revoke execute on function public.company_activity_raw(uuid) from public, anon, authenticated;
create or replace function public.company_activity(p_company uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_company(p_company) then raise exception 'ما عندك صلاحية'; end if;
  return public.company_activity_raw(p_company);
end $$;
revoke execute on function public.company_activity(uuid) from public, anon;
grant execute on function public.company_activity(uuid) to authenticated;

create or replace function public.ab_company_delete_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare a jsonb;
begin
  if public.is_internal() then return old; end if;
  a := public.company_activity_raw(old.id);
  if a <> '{}'::jsonb then
    raise exception 'الشركة «%» فيها حركات (%)، ما بتنحذف. أوقفها بدل الحذف', old.name,
      (select string_agg(key || ': ' || value, '، ') from jsonb_each_text(a));
  end if;
  return old;
end $$;
drop trigger if exists ab_company_delete_guard on public.companies;
create trigger ab_company_delete_guard before delete on public.companies for each row execute function public.ab_company_delete_guard();

-- سطر الفاتورة: الصنف لازم من نفس الشركة
create or replace function public.ad_invoice_line_item_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.item_id is not null and (tg_op = 'INSERT' or new.item_id is distinct from old.item_id)
     and not exists (select 1 from public.items i join public.invoices v on v.id = new.invoice_id where i.id = new.item_id and i.company_id = v.company_id) then
    raise exception 'الصنف مش من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists ad_invoice_line_item_check on public.invoice_lines;
create trigger ad_invoice_line_item_check before insert or update on public.invoice_lines for each row execute function public.ad_invoice_line_item_check();
