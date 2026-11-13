-- =====================================================================
--  المرحلة 89: أداة الأرصدة الافتتاحية
--  - journal_lines.asset_id: سطر القيد الافتتاحي بيعرف أصله (كلفة/مجمع استهلاك لكل أصل)
--  - opening_source(company, from_fy, kind[, type]): أرصدة نهاية سنة سابقة للنسخ
--      kind = accounts | parties (type customer/supplier/expense) | employees | assets
--  - تدوير الأرصدة بإغلاق السنة صار بيحافظ على الموظف بالسطر
-- =====================================================================

alter table public.journal_lines add column if not exists asset_id uuid;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'journal_lines_asset_fk') then
    alter table public.journal_lines add constraint journal_lines_asset_fk foreign key (asset_id)
      references public.fixed_assets(id) on delete set null deferrable initially deferred;
  end if;
end $$;
create index if not exists journal_lines_asset_idx on public.journal_lines(asset_id) where asset_id is not null;

-- الأصل لازم من نفس الشركة، وما بيجتمع مع طرف أو موظف
create or replace function public.ad_jl_asset_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.asset_id is null or public.is_internal() then return new; end if;   -- الاسترجاع: الأصول بترجع بعد القيود (FK مؤجّل)
  if tg_op = 'UPDATE' and new.asset_id is not distinct from old.asset_id then return new; end if;
  if new.party_id is not null or new.employee_id is not null then raise exception 'سطر الأصل ما بيكون عليه عميل/مورد أو موظف'; end if;
  if not exists (select 1 from public.fixed_assets f join public.journal_entries e on e.company_id = f.company_id
                 where f.id = new.asset_id and e.id = new.entry_id) then
    raise exception 'الأصل مش من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists ad_jl_asset_check on public.journal_lines;
create trigger ad_jl_asset_check before insert or update on public.journal_lines for each row execute function public.ad_jl_asset_check();
revoke execute on function public.ad_jl_asset_check() from public, anon, authenticated;

-- أرصدة نهاية سنة سابقة (المرحّل، مع الإقفال) عشان تنسخ كأرصدة افتتاحية
--   accounts : حسابات الميزانية بدون الطرف/الموظف + سطر «نتيجة السنة» (account_id فاضي) إذا السنة مش مقفلة
--   parties  : لكل طرف من النوع
--   employees: لكل (حساب، موظف)
--   assets   : لكل أصل موجود بنهاية السنة: amount = الكلفة، amount2 = مجمع الاستهلاك لحد نهايتها
create or replace function public.opening_source(p_company uuid, p_from_fy uuid, p_kind text, p_type text default null)
returns table (account_id uuid, party_id uuid, employee_id uuid, asset_id uuid, amount numeric, amount2 numeric)
language plpgsql stable security definer set search_path = public as $$
declare fy public.fiscal_years;
begin
  if not (public.can(p_company, 'opening_balances', 'add') or public.can(p_company, 'opening_balances', 'edit')) then
    raise exception 'ما عندك صلاحية على الأرصدة الافتتاحية';
  end if;
  if public.dept_allowed(p_company) is not null then raise exception 'نسخ الأرصدة لموظفي الإدارة بس، مش موظف الفرع'; end if;
  select * into fy from public.fiscal_years where id = p_from_fy and company_id = p_company;
  if fy.id is null then raise exception 'السنة مش لهالشركة'; end if;

  if p_kind = 'assets' then
    return query
    select null::uuid, null::uuid, null::uuid, f.id, f.cost,
           round(f.opening_accum + coalesce((select sum(l.amount) from public.depreciation_lines l join public.depreciation_runs r on r.id = l.run_id
                                             where l.asset_id = f.id and r.status = 'posted' and l.to_date <= fy.end_date), 0), 3)
    from public.fixed_assets f
    where f.company_id = p_company and f.purchase_date <= fy.end_date
      and (f.status = 'active' or f.disposed_date is null or f.disposed_date > fy.end_date)
    order by f.code;
    return;
  end if;
  if p_kind not in ('accounts','parties','employees') then raise exception 'نوع الأرصدة غلط'; end if;
  if p_kind = 'parties' and coalesce(p_type, '') not in ('customer','supplier','expense') then raise exception 'نوع الطرف غلط'; end if;

  return query
  with l as (
    select jl.account_id aid, jl.party_id pid, jl.employee_id eid, jl.debit - jl.credit amt, a.category cat
    from public.journal_lines jl join public.journal_entries e on e.id = jl.entry_id join public.accounts a on a.id = jl.account_id
    where e.company_id = p_company and e.fiscal_year_id = p_from_fy and e.status in ('posted','reversed')
  )
  select x.aid, x.pid, x.eid, null::uuid, round(sum(x.amt), 3), null::numeric from (
    select case when p_kind = 'parties' then null else l.aid end aid,
           case when p_kind = 'parties' then l.pid end pid,
           case when p_kind = 'employees' then l.eid end eid, l.amt
    from l left join public.parties pa on pa.id = l.pid
    where case p_kind
      when 'accounts'  then l.cat in ('assets','liabilities','equity') and l.pid is null and l.eid is null
      when 'employees' then l.cat in ('assets','liabilities','equity') and l.eid is not null
      else l.cat in ('assets','liabilities','equity') and l.pid is not null and pa.party_type = p_type end
  ) x group by x.aid, x.pid, x.eid
  having round(sum(x.amt), 3) <> 0
  union all
  -- نتيجة السنة (إيرادات − مصاريف) إذا ما انقفلت: بتروح على حساب الأرباح المدورة اللي بيختاره المستخدم
  select null::uuid, null::uuid, null::uuid, null::uuid, round(sum(l.amt), 3), null::numeric
  from l where p_kind = 'accounts' and l.cat in ('revenue','expenses')
  having round(sum(l.amt), 3) <> 0;
end $$;
revoke execute on function public.opening_source(uuid, uuid, text, text) from public, anon;
grant execute on function public.opening_source(uuid, uuid, text, text) to authenticated;

-- تدوير الأرصدة: نفس المرحلة 08 بس بيحافظ على الموظف بسطور الافتتاحي
create or replace function public.close_fiscal_year(p_fy uuid, p_next_fy uuid, p_retained uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare fy public.fiscal_years; nfy public.fiscal_years; ra public.accounts; drafts int; cid uuid; nid uuid; oid uuid;
  ln int := 0; net numeric := 0; r record; old_open public.journal_entries; d numeric;
begin
  if not public.is_admin() then raise exception 'إغلاق السنة لمدير النظام بس'; end if;
  select * into fy from public.fiscal_years where id = p_fy;
  if fy.id is not null and (not public.has_company(fy.company_id) or not public.tenant_writable()) then raise exception 'ما عندك صلاحية لهالعملية'; end if;
  select * into nfy from public.fiscal_years where id = p_next_fy;
  if fy.id is null or nfy.id is null or nfy.company_id <> fy.company_id then raise exception 'اختار السنة الجديدة لنفس الشركة'; end if;
  if fy.is_closed then raise exception 'السنة مغلقة من قبل'; end if;
  if nfy.is_closed then raise exception 'السنة الجديدة مغلقة'; end if;
  if nfy.start_date <= fy.end_date then raise exception 'السنة الجديدة لازم تبلّش بعد نهاية السنة اللي بتنغلق'; end if;
  select * into ra from public.accounts where id = p_retained;
  if ra.id is null or ra.company_id <> fy.company_id or ra.is_group or ra.category <> 'equity' then
    raise exception 'حساب الأرباح المدورة لازم يكون حساب فرعي من حقوق الملكية';
  end if;
  select count(*) into drafts from public.journal_entries where fiscal_year_id = p_fy and status = 'draft';
  if drafts > 0 then raise exception 'في % قيد/سند مسودة بهالسنة. رحّلهم أو احذفهم قبل الإغلاق', drafts; end if;
  if to_regclass('public.invoices') is not null then
    select count(*) into drafts from public.invoices where fiscal_year_id = p_fy and status = 'draft';
    if drafts > 0 then raise exception 'في % فاتورة مسودة بهالسنة. رحّلها أو احذفها قبل الإغلاق', drafts; end if;
  end if;

  select * into old_open from public.journal_entries where fiscal_year_id = p_next_fy and entry_type = 'opening' and status <> 'reversed' order by created_at desc limit 1;
  if old_open.id is not null and old_open.status = 'posted' and coalesce(old_open.reference, '') <> 'AUTO-CLOSE' then
    raise exception 'السنة الجديدة إلها أرصدة افتتاحية مرحّلة (مدخلة يدوياً). احذفها أو اعكسها قبل التدوير';
  end if;

  perform set_config('sumou.internal', public.internal_token(), true);
  if old_open.id is not null then delete from public.journal_entries where id = old_open.id; end if;

  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (fy.company_id, p_fy, 'closing', fy.end_date, 'قيد إقفال ' || coalesce(fy.name, fy.code), 'AUTO-CLOSE', 'draft')
  returning id into cid;
  for r in
    select l.account_id, l.party_id, sum(l.debit - l.credit) as bal
    from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
    where e.fiscal_year_id = p_fy and e.status in ('posted','reversed') and e.id <> cid and a.category in ('revenue','expenses')
    group by l.account_id, l.party_id having abs(sum(l.debit - l.credit)) > 0.0005
  loop
    ln := ln + 1; net := net + r.bal;
    insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
    values (cid, ln, r.account_id, r.party_id, 'إقفال', case when r.bal < 0 then -r.bal else 0 end, case when r.bal > 0 then r.bal else 0 end);
  end loop;
  if ln > 0 and abs(net) > 0.0005 then
    ln := ln + 1;
    insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit)
    values (cid, ln, p_retained, case when net > 0 then 'خسارة السنة' else 'ربح السنة' end,
            case when net > 0 then net else 0 end, case when net < 0 then -net else 0 end);
  end if;
  if ln = 0 then delete from public.journal_entries where id = cid; cid := null;
  else
    select coalesce(sum(debit), 0) into d from public.journal_lines where entry_id = cid;
    update public.journal_entries set status = 'posted', total = d, posted_by = auth.uid(), posted_at = now() where id = cid;
  end if;

  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (fy.company_id, p_next_fy, 'opening', nfy.start_date, 'أرصدة مدوّرة من ' || coalesce(fy.name, fy.code), 'AUTO-CLOSE', 'draft')
  returning id into oid;
  ln := 0;
  for r in
    select l.account_id, l.party_id, l.employee_id, sum(l.debit - l.credit) as bal
    from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
    where e.fiscal_year_id = p_fy and e.status in ('posted','reversed') and a.category in ('assets','liabilities','equity')
    group by l.account_id, l.party_id, l.employee_id having abs(sum(l.debit - l.credit)) > 0.0005
    order by 1
  loop
    ln := ln + 1;
    insert into public.journal_lines (entry_id, line_no, account_id, party_id, employee_id, description, debit, credit)
    values (oid, ln, r.account_id, r.party_id, r.employee_id, 'رصيد مدوّر', case when r.bal > 0 then r.bal else 0 end, case when r.bal < 0 then -r.bal else 0 end);
  end loop;
  if ln = 0 then delete from public.journal_entries where id = oid; oid := null;
  else
    select coalesce(sum(debit), 0) into d from public.journal_lines where entry_id = oid;
    if abs(d - (select coalesce(sum(credit), 0) from public.journal_lines where entry_id = oid)) > 0.0005 then
      raise exception 'الأرصدة المدوّرة مش متوازنة. راجع ميزان المراجعة للسنة';
    end if;
    update public.journal_entries set status = 'posted', total = d, posted_by = auth.uid(), posted_at = now() where id = oid;
  end if;

  update public.fiscal_years set is_closed = true where id = p_fy;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), fy.company_id, 'إغلاق السنة', 'fiscal_years', p_fy::text, jsonb_build_object('next', p_next_fy, 'net', -net));
  return jsonb_build_object('closing_entry', cid, 'opening_entry', oid, 'profit', -net);
end $$;
