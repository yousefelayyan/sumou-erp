-- =====================================================================
--  السمو ERP — المرحلة 59: ملف العميل/المورد الإحصائي (360)
--  party_profile(company, party) → jsonb: الرصيد والسقف، المفتوح والمتأخر، المبيعات/المشتريات بآخر 12 شهر،
--  السنة الحالية والسابقة، المرتجعات، متوسط الفاتورة، آخر فاتورة وآخر دفعة، متوسط أيام السداد، أكثر الأصناف،
--  الشيكات، الطلبات المفتوحة، الزيارات، الرسائل. قراءة بس، بصلاحية view على شاشة الطرف، وموظف الفرع بيشوف فرعه بس.
-- =====================================================================
create or replace function public.party_profile(p_company uuid, p_party uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare pa public.parties; dl uuid[]; t_main text; t_ret text; td date := public.local_today(); res jsonb; y0 date; y1 date; op jsonb := '{}'::jsonb;
begin
  select * into pa from public.parties where id = p_party and company_id = p_company;
  if pa.id is null then raise exception 'الطرف مش موجود'; end if;
  if not public.can(p_company, public.party_screen(pa.party_type), 'view') then raise exception 'ما عندك صلاحية'; end if;
  dl := public.dept_allowed(p_company);
  t_main := case when pa.party_type = 'supplier' then 'purchase' else 'sale' end;
  t_ret := t_main || '_return';
  y0 := date_trunc('year', td)::date; y1 := (y0 - interval '1 year')::date;

  -- الفواتير المفتوحة (إذا إله صلاحية السندات أو الفواتير)
  if public.can(p_company, 'receipt_vouchers', 'view') or public.can(p_company, 'payment_vouchers', 'view')
     or public.can(p_company, 'sales_invoices', 'view') or public.can(p_company, 'purchase_invoices', 'view') then
    select jsonb_build_object(
      'open_count', count(*) filter (where o.remaining > 0.0005),
      'open_amount', coalesce(sum(o.remaining) filter (where o.remaining > 0.0005), 0),
      'overdue_amount', coalesce(sum(o.remaining) filter (where o.remaining > 0.0005 and coalesce(o.due_date, o.inv_date) < td), 0),
      'overdue_30', coalesce(sum(o.remaining) filter (where o.remaining > 0.0005 and coalesce(o.due_date, o.inv_date) < td - 30), 0),
      'oldest_open', min(o.inv_date) filter (where o.remaining > 0.0005))
      into op
      from public.party_open_invoices(p_company, p_party, null) o
      join public.invoices i on i.id = o.invoice_id
     where o.inv_type = t_main and (dl is null or i.department_id = any (dl));
  end if;

  with inv as (
    select i.* from public.invoices i
     where i.company_id = p_company and i.party_id = p_party and i.status = 'posted'
       and (dl is null or i.department_id = any (dl))),
  months as (select generate_series(date_trunc('month', td) - interval '11 months', date_trunc('month', td), interval '1 month')::date m),
  pays as (   -- دفعات الطرف (سندات قبض/صرف وشيكات)، مرحّلة ومش معكوسة
    select e.entry_date d, case when pa.party_type = 'supplier' then l.debit - l.credit else l.credit - l.debit end amt
      from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
     where l.party_id = p_party and e.company_id = p_company and e.status = 'posted' and e.reversed_by is null
       and e.entry_type in ('receipt','payment','cheque') and (dl is null or e.department_id = any (dl))),
  alloc as (   -- متوسط أيام السداد من التوزيع على الفواتير
    select avg(e.entry_date - i.inv_date)::numeric d
      from public.invoice_allocations a join inv i on i.id = a.invoice_id join public.journal_entries e on e.id = a.entry_id
     where i.inv_type = t_main and public.alloc_live(a.entry_id))
  select jsonb_build_object(
    'party', jsonb_build_object('id', pa.id, 'code', pa.code, 'name', pa.name, 'type', pa.party_type, 'phone', coalesce(pa.mobile, pa.phone),
             'credit_limit', pa.credit_limit, 'is_active', pa.is_active, 'created_at', pa.created_at),
    'balance', case when dl is null then public.party_balance_fy(p_party, null) end,
    'year_total', coalesce((select sum(case when inv_type = t_main then subtotal else -subtotal end) from inv where inv_type in (t_main, t_ret) and inv_date >= y0), 0),
    'last_year_total', coalesce((select sum(case when inv_type = t_main then subtotal else -subtotal end) from inv where inv_type in (t_main, t_ret) and inv_date >= y1 and inv_date < y0), 0),
    'all_total', coalesce((select sum(case when inv_type = t_main then subtotal else -subtotal end) from inv where inv_type in (t_main, t_ret)), 0),
    'returns_total', coalesce((select sum(subtotal) from inv where inv_type = t_ret), 0),
    'invoice_count', (select count(*) from inv where inv_type = t_main),
    'avg_invoice', (select round(avg(total), 3) from inv where inv_type = t_main),
    'first_invoice', (select min(inv_date) from inv where inv_type = t_main),
    'last_invoice', (select jsonb_build_object('date', inv_date, 'no', coalesce(doc_code, inv_no::text), 'total', total) from inv where inv_type = t_main order by inv_date desc, created_at desc limit 1),
    'last_payment', (select jsonb_build_object('date', d, 'amount', amt) from pays where amt > 0 order by d desc limit 1),
    'payments_year', coalesce((select sum(amt) from pays where d >= y0), 0),
    'avg_pay_days', (select round(d, 0) from alloc),
    'monthly', (select jsonb_agg(jsonb_build_object('m', to_char(m, 'YYYY-MM'),
                   'v', coalesce((select sum(case when inv_type = t_main then subtotal else -subtotal end) from inv
                                   where inv_type in (t_main, t_ret) and date_trunc('month', inv_date) = m), 0),
                   'p', coalesce((select sum(amt) from pays where date_trunc('month', d) = m), 0)) order by m) from months),
    'top_items', (select coalesce(jsonb_agg(x order by x.v desc), '[]'::jsonb) from (
                   select it.id, it.code, it.name, sum(case when i.inv_type = t_main then l.qty else -l.qty end) q,
                          sum(case when i.inv_type = t_main then l.subtotal else -l.subtotal end) v, max(i.inv_date) last
                     from inv i join public.invoice_lines l on l.invoice_id = i.id join public.items it on it.id = l.item_id
                    where i.inv_type in (t_main, t_ret) group by it.id, it.code, it.name order by 5 desc limit 10) x),
    'cheques', jsonb_build_object(
       'portfolio', coalesce((select sum(amount) from public.cheques c where c.party_id = p_party and c.company_id = p_company and c.status in ('portfolio','deposited','issued')), 0),
       'portfolio_count', (select count(*) from public.cheques c where c.party_id = p_party and c.company_id = p_company and c.status in ('portfolio','deposited','issued')),
       'returned_count', (select count(*) from public.cheques c where c.party_id = p_party and c.company_id = p_company and c.status = 'returned'),
       'returned_amount', coalesce((select sum(amount) from public.cheques c where c.party_id = p_party and c.company_id = p_company and c.status = 'returned'), 0)),
    'open_orders', (select count(*) from public.orders o where o.company_id = p_company and o.party_id = p_party and o.status = 'open'),
    'visits_90', (select count(*) from public.sales_visits v where v.company_id = p_company and v.party_id = p_party and v.started_at >= now() - interval '90 days' and v.status <> 'cancelled'),
    'messages', (select count(*) from public.message_log m where m.company_id = p_company and m.party_id = p_party))
  into res;
  res := res || op;
  return res;
end $$;
revoke all on function public.party_profile(uuid, uuid) from public, anon;
grant execute on function public.party_profile(uuid, uuid) to authenticated;
