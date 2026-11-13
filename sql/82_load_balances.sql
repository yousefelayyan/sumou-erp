-- =====================================================================
--  المرحلة 82: تحميل أرصدة على سند قيد
--  entry_load_balances(company, fy, p jsonb) → سطور (حساب، طرف، موظف، الرصيد مدين−دائن) لحد تاريخ
--    p.kind = accounts (p.parent = حساب رئيسي → كل فروعه، أو p.accounts[] ، أو p.category)
--           | parties (p.type customer/supplier/expense، p.category_id اختياري)
--           | employees (p.account = حساب ذمم/سلف الموظفين)
--    p.to = لحد تاريخ، p.nonzero افتراضي true
--  بصلاحية إضافة سندات القيد، المرحّل بس (بدون الإقفال)، وموظف الفرع بياخذ دوائره بس.
-- =====================================================================
create or replace function public.entry_load_balances(p_company uuid, p_fy uuid, p jsonb)
returns table (account_id uuid, party_id uuid, employee_id uuid, balance numeric)
language plpgsql stable security definer set search_path = public as $$
declare al uuid[] := public.dept_allowed(p_company); k text := p ->> 'kind'; d date := coalesce(nullif(p ->> 'to', '')::date, public.local_today());
  accs uuid[]; par uuid := nullif(p ->> 'parent', '')::uuid; typ text := p ->> 'type'; cat uuid := nullif(p ->> 'category_id', '')::uuid;
begin
  if not public.can(p_company, 'journal_entries', 'add') then raise exception 'ما عندك صلاحية على سندات القيد'; end if;
  if not exists (select 1 from public.fiscal_years where id = p_fy and company_id = p_company) then raise exception 'السنة مش لهالشركة'; end if;
  if k = 'accounts' then
    if par is not null then
      with recursive t as (select id from public.accounts where id = par and company_id = p_company
                           union all select a.id from public.accounts a join t on a.parent_id = t.id)
      select array_agg(id) into accs from t;
    elsif p ? 'accounts' then
      select array_agg(x::uuid) into accs from jsonb_array_elements_text(p -> 'accounts') x;
    elsif nullif(p ->> 'category', '') is not null then
      select array_agg(id) into accs from public.accounts where company_id = p_company and category = p ->> 'category';
    else raise exception 'اختار الحسابات'; end if;
  elsif k = 'employees' then
    if nullif(p ->> 'account', '') is null then raise exception 'اختار حساب الموظفين'; end if;
  elsif k = 'parties' then
    if typ not in ('customer','supplier','expense') then raise exception 'نوع الطرف غلط'; end if;
  else raise exception 'نوع التحميل غلط'; end if;

  return query
  with l as (
    select jl.account_id, jl.party_id, jl.employee_id, jl.debit - jl.credit amt
    from public.journal_lines jl join public.journal_entries e on e.id = jl.entry_id
    where e.company_id = p_company and e.fiscal_year_id = p_fy and e.status in ('posted','reversed')
      and e.entry_type <> 'closing' and e.entry_date <= d
      and (al is null or e.department_id = any (al))
  ), f as (
    select x.account_id aid,
           case when k = 'accounts' and not coalesce((p ->> 'by_party')::boolean, false) then null else x.party_id end pid,
           case when k = 'accounts' and not coalesce((p ->> 'by_party')::boolean, false) then null else x.employee_id end eid, x.amt
    from l x left join public.parties pa on pa.id = x.party_id
    where case k
      when 'accounts' then x.account_id = any (accs)
      when 'employees' then x.account_id = (p ->> 'account')::uuid and x.employee_id is not null
      else pa.party_type = typ and (cat is null or pa.category_id = cat) end
  )
  select f.aid, f.pid, f.eid, round(sum(f.amt), 3)
  from f group by f.aid, f.pid, f.eid
  having not coalesce((p ->> 'nonzero')::boolean, true) or round(sum(f.amt), 3) <> 0
  order by 1, 2, 3;
end $$;
revoke execute on function public.entry_load_balances(uuid, uuid, jsonb) from public, anon;
grant execute on function public.entry_load_balances(uuid, uuid, jsonb) to authenticated;
