-- =====================================================================
--  السمو ERP — المرحلة 72: تقارير تحصيل الفواتير (قراءة بس)
--  rep_open_invoices(company, type): كل الفواتير الآجلة المفتوحة لكل العملاء أو الموردين (من التوزيع، زي party_open_invoices).
--  rep_invoice_collection(company, type, from, to): فواتير الفترة، شو انحصّل منها ومتى (من invoice_allocations)،
--  وأيام التحصيل الموزونة بالمبلغ، وأيام السداد الكامل.
-- =====================================================================
create or replace function public.coll_can(p_company uuid, p_type text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.can(p_company, 'reports', 'view') or public.can(p_company, 'branch_reports', 'view')
      or public.can(p_company, case when p_type = 'supplier' then 'purchase_invoices' else 'sales_invoices' end, 'view')
      or public.can(p_company, case when p_type = 'supplier' then 'payment_vouchers' else 'receipt_vouchers' end, 'view');
$$;
revoke execute on function public.coll_can(uuid, text) from public, anon, authenticated;

create or replace function public.rep_open_invoices(p_company uuid, p_type text default 'customer')
returns table (party_id uuid, invoice_id uuid, doc_code text, inv_no int, inv_date date, due_date date, total numeric, returned numeric, allocated numeric, remaining numeric, sales_rep_id uuid)
language plpgsql stable security definer set search_path = public as $$
begin
  if p_type not in ('customer','supplier') then raise exception 'النوع غلط'; end if;
  if not public.coll_can(p_company, p_type) then raise exception 'ما عندك صلاحية'; end if;
  return query
  select * from (
    select i.party_id, i.id, i.doc_code, i.inv_no, i.inv_date, coalesce(i.due_date, (i.inv_date + coalesce(p.payment_terms_days, 0))::date),
           i.total - coalesce(sp.amt, 0), coalesce(r.amt, 0), coalesce(a.amt, 0),
           round(i.total - coalesce(sp.amt, 0) - coalesce(r.amt, 0) - coalesce(a.amt, 0), 3) rem, i.sales_rep_id
      from public.invoices i join public.parties p on p.id = i.party_id
      left join lateral (select sum(x.total) amt from public.invoices x where x.original_invoice_id = i.id and x.status = 'posted' and x.payment_type = 'credit') r on true
      left join lateral (select sum(s.amount) amt from public.invoice_party_splits s where s.invoice_id = i.id) sp on true
      left join lateral (select sum(al.amount) amt from public.invoice_allocations al where al.invoice_id = i.id and public.alloc_live(al.entry_id)) a on true
     where i.company_id = p_company and i.status = 'posted' and i.payment_type = 'credit'
       and i.inv_type = case when p_type = 'supplier' then 'purchase' else 'sale' end
       and public.dept_ok(p_company, i.department_id)) z
   where z.rem > 0.0005
   order by 1, 5, 4;
end $$;

create or replace function public.rep_invoice_collection(p_company uuid, p_type text, p_from date, p_to date)
returns table (party_id uuid, invoice_id uuid, doc_code text, inv_no int, inv_date date, due_date date, total numeric, returned numeric,
               collected numeric, remaining numeric, first_pay date, last_pay date, avg_days numeric, full_days int, late_days int, sales_rep_id uuid)
language plpgsql stable security definer set search_path = public as $$
begin
  if p_type not in ('customer','supplier') then raise exception 'النوع غلط'; end if;
  if not public.coll_can(p_company, p_type) then raise exception 'ما عندك صلاحية'; end if;
  return query
  with inv as (
    select i.*, coalesce(i.due_date, (i.inv_date + coalesce(p.payment_terms_days, 0))::date) dd,
           i.total - coalesce((select sum(s.amount) from public.invoice_party_splits s where s.invoice_id = i.id), 0) net,
           coalesce((select sum(x.total) from public.invoices x where x.original_invoice_id = i.id and x.status = 'posted' and x.payment_type = 'credit'), 0) ret
      from public.invoices i join public.parties p on p.id = i.party_id
     where i.company_id = p_company and i.status = 'posted' and i.payment_type = 'credit'
       and i.inv_type = case when p_type = 'supplier' then 'purchase' else 'sale' end
       and i.inv_date between p_from and p_to and public.dept_ok(p_company, i.department_id)),
  al as (
    select a.invoice_id, a.amount, greatest(e.entry_date, inv.inv_date) pd, inv.inv_date
      from public.invoice_allocations a join inv on inv.id = a.invoice_id join public.journal_entries e on e.id = a.entry_id
     where public.alloc_live(a.entry_id)),
  ag as (
    select al.invoice_id, sum(al.amount) amt, min(al.pd) fp, max(al.pd) lp, sum(al.amount * (al.pd - al.inv_date)) wd from al group by al.invoice_id)
  select inv.party_id, inv.id, inv.doc_code, inv.inv_no, inv.inv_date, inv.dd, inv.net, inv.ret, coalesce(ag.amt, 0),
         round(inv.net - inv.ret - coalesce(ag.amt, 0), 3), ag.fp, ag.lp,
         case when coalesce(ag.amt, 0) > 0 then round(ag.wd / ag.amt, 1) end,
         case when round(inv.net - inv.ret - coalesce(ag.amt, 0), 3) <= 0.0005 and ag.lp is not null then (ag.lp - inv.inv_date) end,
         case when round(inv.net - inv.ret - coalesce(ag.amt, 0), 3) <= 0.0005 then greatest(coalesce(ag.lp, inv.inv_date) - inv.dd, 0)
              else greatest(public.local_today() - inv.dd, 0) end,
         inv.sales_rep_id
    from inv left join ag on ag.invoice_id = inv.id
   order by inv.party_id, inv.inv_date, inv.inv_no;
end $$;
revoke execute on function public.rep_open_invoices(uuid, text), public.rep_invoice_collection(uuid, text, date, date) from public, anon;
grant execute on function public.rep_open_invoices(uuid, text), public.rep_invoice_collection(uuid, text, date, date) to authenticated;
