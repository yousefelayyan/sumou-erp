-- =====================================================================
--  السمو ERP — المرحلة 63: سجل أسعار الصنف للعميل/المورد
--  party_last_prices(company, party, kind): آخر سعر لكل صنف بفواتير الطرف المرحّلة (sale أو purchase)،
--    مع عدد المرات وأقل وأعلى سعر. party_price_history(company, party, item, kind, limit): كل الفواتير.
--  السعر الصافي = (الكمية × السعر − الخصم) ÷ الكمية، قبل الضريبة (الفاتورة الشاملة بتتحوّل لقبل الضريبة).
--  قراءة بس، بصلاحية view على شاشة الفواتير، وموظف الفرع بيشوف فرعه بس.
--  company_settings.use_last_price: الفاتورة بتاخذ آخر سعر للطرف عند اختيار الصنف (قائمة الأسعار أولى).
-- =====================================================================
alter table public.company_settings add column if not exists use_last_price boolean not null default false;

create or replace function public.price_hist_rows(p_company uuid, p_party uuid, p_item uuid, p_kind text)
returns table (invoice_id uuid, inv_date date, doc_no text, item_id uuid, qty numeric, unit_price numeric, discount numeric,
               net_price numeric, tax_rate numeric, include_tax boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare dl uuid[];
begin
  if p_kind not in ('sale', 'purchase') then raise exception 'نوع غير معروف'; end if;
  if not public.can(p_company, case p_kind when 'sale' then 'sales_invoices' else 'purchase_invoices' end, 'view') then
    raise exception 'ما عندك صلاحية'; end if;
  dl := public.dept_allowed(p_company);
  return query
    select i.id, i.inv_date, coalesce(i.doc_code, i.inv_no::text), l.item_id, l.qty, l.unit_price, l.discount,
           round(case when i.prices_include_tax then (l.qty * l.unit_price - l.discount) / (1 + l.tax_rate / 100)
                      else l.qty * l.unit_price - l.discount end / l.qty, 3),
           l.tax_rate, i.prices_include_tax, i.created_at
      from public.invoices i join public.invoice_lines l on l.invoice_id = i.id
     where i.company_id = p_company and i.party_id = p_party and i.inv_type = p_kind and i.status = 'posted'
       and l.item_id is not null and (p_item is null or l.item_id = p_item)
       and (dl is null or i.department_id = any (dl));
end $$;
revoke execute on function public.price_hist_rows(uuid, uuid, uuid, text) from public, anon, authenticated;

create or replace function public.party_last_prices(p_company uuid, p_party uuid, p_kind text default 'sale')
returns table (item_id uuid, last_date date, last_price numeric, last_unit_price numeric, last_qty numeric, doc_no text,
               invoice_id uuid, times int, min_price numeric, max_price numeric)
language sql stable security definer set search_path = public as $$
  with h as (select * from public.price_hist_rows(p_company, p_party, null, p_kind)),
  last as (select distinct on (h.item_id) h.* from h order by h.item_id, h.inv_date desc, h.created_at desc)
  select l.item_id, l.inv_date, l.net_price, l.unit_price, l.qty, l.doc_no, l.invoice_id,
         (select count(distinct x.invoice_id)::int from h x where x.item_id = l.item_id),
         (select min(x.net_price) from h x where x.item_id = l.item_id),
         (select max(x.net_price) from h x where x.item_id = l.item_id)
    from last l;
$$;
revoke execute on function public.party_last_prices(uuid, uuid, text) from public, anon;
grant execute on function public.party_last_prices(uuid, uuid, text) to authenticated;

create or replace function public.party_price_history(p_company uuid, p_party uuid, p_item uuid, p_kind text default 'sale', p_limit int default 50)
returns table (invoice_id uuid, inv_date date, doc_no text, qty numeric, unit_price numeric, discount numeric,
               net_price numeric, tax_rate numeric, include_tax boolean)
language sql stable security definer set search_path = public as $$
  select h.invoice_id, h.inv_date, h.doc_no, h.qty, h.unit_price, h.discount, h.net_price, h.tax_rate, h.include_tax
    from public.price_hist_rows(p_company, p_party, p_item, p_kind) h
   where p_item is not null
   order by h.inv_date desc, h.created_at desc
   limit least(greatest(coalesce(p_limit, 50), 1), 500);
$$;
revoke execute on function public.party_price_history(uuid, uuid, uuid, text, int) from public, anon;
grant execute on function public.party_price_history(uuid, uuid, uuid, text, int) to authenticated;

create index if not exists invoices_party_type_idx on public.invoices (company_id, party_id, inv_type, status);
