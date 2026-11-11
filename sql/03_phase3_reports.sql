-- =====================================================================
--  نظام السمو ERP — المرحلة 3: التقارير المالية
--  كشف الحساب، اليومية العامة، ميزان المراجعة (وعليه قائمة الدخل والميزانية)
--  التقارير بتقرأ القيود المرحّلة فقط، وبتحتاج صلاحية «التقارير المالية ← عرض»
--  لازم ملفات المرحلة 1 و2 يكونوا مشغّلين قبله. آمن للتشغيل أكثر من مرة.
-- =====================================================================

-- كشف حساب: حركات حساب (أو حساب رئيسي مع كل فروعه) بفترة جوّا سنة مالية
drop function if exists public.rep_ledger(uuid, uuid, uuid, date, date);
create or replace function public.rep_ledger(p_company uuid, p_fy uuid, p_account uuid, p_from date, p_to date)
returns table (entry_id uuid, entry_type text, entry_no int, entry_date date, description text,
               line_description text, reference text, account_code text, account_name text, debit numeric, credit numeric, doc_code text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  with recursive tree as (
    select a.id from public.accounts a where a.id = p_account and a.company_id = p_company
    union all
    select c.id from public.accounts c join tree t on c.parent_id = t.id
  )
  select e.id, e.entry_type, e.entry_no, e.entry_date, e.description, l.description, e.reference,
         a.code, a.name, l.debit, l.credit, e.doc_code
  from public.journal_lines l
  join public.journal_entries e on e.id = l.entry_id
  join public.accounts a on a.id = l.account_id
  where l.account_id in (select id from tree)
    and e.company_id = p_company and e.fiscal_year_id = p_fy
    and e.status in ('posted','reversed')
    and e.entry_date between p_from and p_to
  order by e.entry_date, case e.entry_type when 'opening' then 0 else 1 end, e.created_at, l.line_no;
end $$;

-- الرصيد قبل تاريخ معيّن (جوّا نفس السنة المالية، شامل القيد الافتتاحي)
create or replace function public.rep_balance_before(p_company uuid, p_fy uuid, p_account uuid, p_date date)
returns numeric
language plpgsql stable security definer set search_path = public as $$
declare r numeric;
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  with recursive tree as (
    select a.id from public.accounts a where a.id = p_account and a.company_id = p_company
    union all
    select c.id from public.accounts c join tree t on c.parent_id = t.id
  )
  select coalesce(sum(l.debit - l.credit), 0) into r
  from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
  where l.account_id in (select id from tree)
    and e.company_id = p_company and e.fiscal_year_id = p_fy and e.status in ('posted','reversed')
    and e.entry_date < p_date;
  return r;
end $$;

-- ميزان المراجعة: لكل حساب فرعي: رصيد أول المدة، حركة الفترة، (الإقفال بيتحسب بالواجهة)
create or replace function public.rep_trial_balance(p_company uuid, p_fy uuid, p_from date, p_to date)
returns table (account_id uuid, open_debit numeric, open_credit numeric, period_debit numeric, period_credit numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  select l.account_id,
         coalesce(sum(l.debit)  filter (where e.entry_date < p_from or e.entry_type = 'opening'), 0),
         coalesce(sum(l.credit) filter (where e.entry_date < p_from or e.entry_type = 'opening'), 0),
         coalesce(sum(l.debit)  filter (where e.entry_date >= p_from and e.entry_type <> 'opening'), 0),
         coalesce(sum(l.credit) filter (where e.entry_date >= p_from and e.entry_type <> 'opening'), 0)
  from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
  where e.company_id = p_company and e.fiscal_year_id = p_fy and e.status in ('posted','reversed')
    and e.entry_date <= p_to
    and e.entry_type <> 'closing'      -- قيد الإقفال ما بيدخل بالميزان (القوائم بتحسب الربح لحالها)
  group by l.account_id;
end $$;

-- اليومية العامة: كل القيود المرحّلة بالفترة مع سطورها
drop function if exists public.rep_journal(uuid, uuid, date, date, text);
create or replace function public.rep_journal(p_company uuid, p_fy uuid, p_from date, p_to date, p_type text default null)
returns table (entry_id uuid, entry_type text, entry_no int, entry_date date, description text, reference text, party_name text,
               status text, line_no int, account_code text, account_name text, line_description text, debit numeric, credit numeric, doc_code text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  select e.id, e.entry_type, e.entry_no, e.entry_date, e.description, e.reference, e.party_name, e.status,
         l.line_no, a.code, a.name, l.description, l.debit, l.credit, e.doc_code
  from public.journal_entries e
  join public.journal_lines l on l.entry_id = e.id
  join public.accounts a on a.id = l.account_id
  where e.company_id = p_company and e.fiscal_year_id = p_fy and e.status in ('posted','reversed')
    and e.entry_date between p_from and p_to and (p_type is null or e.entry_type = p_type)
  order by e.entry_date, case e.entry_type when 'opening' then 0 else 1 end, e.entry_type, e.entry_no, l.line_no;
end $$;

grant execute on function public.rep_ledger(uuid, uuid, uuid, date, date), public.rep_balance_before(uuid, uuid, uuid, date),
  public.rep_trial_balance(uuid, uuid, date, date), public.rep_journal(uuid, uuid, date, date, text) to authenticated;
revoke execute on function public.rep_ledger(uuid, uuid, uuid, date, date), public.rep_balance_before(uuid, uuid, uuid, date),
  public.rep_trial_balance(uuid, uuid, date, date), public.rep_journal(uuid, uuid, date, date, text) from anon;

-- صلاحية التقارير للمجموعات الجاهزة
update public.user_groups set permissions = permissions || '{"reports":{"view":true,"print":true}}'::jsonb
 where name in ('محاسب', 'مشاهد') and not (permissions ? 'reports');

-- انتهى ✅
