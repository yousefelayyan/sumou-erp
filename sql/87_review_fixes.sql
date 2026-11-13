-- =====================================================================
--  المرحلة 87: تصليحات المراجعة على المراحل 81–84
--  81: رقم شيك الضمان من النظام بس. 82: تحميل الأرصدة بدها صلاحية عرض حسب النوع.
--  83: ملخص الكاشير بيحترم الفرع، والنقد المتوقع بينقص منه مرتجعات البيع النقدية. 84: طول كلمة السر بالبايت، وتأخير عند الخطأ.
-- =====================================================================
create or replace function public.ab_guarantee_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare sys boolean := coalesce(current_setting('sumou.guarantee', true) = public.internal_token(), false) or coalesce(public.is_internal(), false);
begin
  if tg_op = 'DELETE' then
    if old.status <> 'held' and not sys and exists (select 1 from public.companies where id = old.company_id) then
      raise exception 'شيك الضمان بعد ما انرجع أو تسيّل ما بينحذف'; end if;
    return old;
  end if;
  new.cheque_no := trim(new.cheque_no);
  if new.party_id is not null and not exists (select 1 from public.parties where id = new.party_id and company_id = new.company_id) then
    raise exception 'الطرف مش من هالشركة'; end if;
  if new.employee_id is not null and not exists (select 1 from public.employees where id = new.employee_id and company_id = new.company_id) then
    raise exception 'الموظف مش من هالشركة'; end if;
  if new.department_id is not null and not exists (select 1 from public.departments where id = new.department_id and company_id = new.company_id) then
    raise exception 'الدائرة مش من هالشركة'; end if;
  if tg_op = 'INSERT' then
    if not sys then
      new.doc_no := null;   -- الرقم من النظام بس (رقم كبير بيوقف الترقيم)
      new.status := 'held'; new.status_date := null; new.status_note := null; new.cheque_id := null;
      new.created_by := auth.uid(); new.created_at := now();
    end if;
    if new.doc_no is null then
      perform pg_advisory_xact_lock(hashtext('gch:' || new.company_id::text));
      select coalesce(max(doc_no), 0) + 1 into new.doc_no from public.guarantee_cheques where company_id = new.company_id;
    end if;
    return new;
  end if;
  new.company_id := old.company_id; new.created_by := old.created_by; new.created_at := old.created_at;
  if not sys then
    new.doc_no := old.doc_no; new.status := old.status; new.status_date := old.status_date; new.status_note := old.status_note; new.cheque_id := old.cheque_id;
    if old.status <> 'held' and (to_jsonb(new) - array['notes','updated_by','updated_at']) is distinct from (to_jsonb(old) - array['notes','updated_by','updated_at']) then
      raise exception 'شيك الضمان بعد ما انرجع أو تسيّل بتتعدّل ملاحظاته بس'; end if;
  end if;
  new.updated_by := auth.uid(); new.updated_at := now();
  return new;
end $$;

create or replace function public.entry_load_balances(p_company uuid, p_fy uuid, p jsonb)
returns table (account_id uuid, party_id uuid, employee_id uuid, balance numeric)
language plpgsql stable security definer set search_path = public as $$
declare al uuid[] := public.dept_allowed(p_company); k text := p ->> 'kind'; d date := coalesce(nullif(p ->> 'to', '')::date, public.local_today());
  accs uuid[]; par uuid := nullif(p ->> 'parent', '')::uuid; typ text := p ->> 'type'; cat uuid := nullif(p ->> 'category_id', '')::uuid;
begin
  if not public.can(p_company, 'journal_entries', 'add') then raise exception 'ما عندك صلاحية على سندات القيد'; end if;
  -- قراءة الأرصدة بدها صلاحية عرض حسب النوع (مش بس إضافة قيد)
  if k = 'employees' and not public.can(p_company, 'payroll', 'view') then raise exception 'أرصدة الموظفين بدها صلاحية عرض الرواتب'; end if;
  if k = 'parties' and typ in ('customer','supplier','expense') and not public.can(p_company, public.party_screen(typ), 'view') then raise exception 'ما عندك صلاحية عرض الأطراف'; end if;
  if k = 'accounts' and not (public.can(p_company, 'reports', 'view') or (al is not null and public.can(p_company, 'branch_reports', 'view'))) then
    raise exception 'أرصدة الحسابات بدها صلاحية التقارير'; end if;
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

create or replace function public.pos_day_rows(p_company uuid, p_day date, p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with inv as (
    select i.*, a.account_type = 'cash' as is_cash_acc
    from public.invoices i left join public.accounts a on a.id = i.cash_account_id
    where i.company_id = p_company and i.inv_date = p_day and i.pos and i.inv_type = 'sale'
      and (p_user is null or i.created_by = p_user)
      and (public.dept_allowed(p_company) is null or p_user = auth.uid() or i.department_id = any (public.dept_allowed(p_company)))
  ), ret as (
    select r.created_by, count(*) n, sum(r.total) t,
           coalesce(sum(r.total) filter (where r.payment_type = 'cash' and a.account_type = 'cash'), 0) cash_out
    from public.invoices r left join public.accounts a on a.id = r.cash_account_id
    where r.company_id = p_company and r.inv_date = p_day and r.inv_type = 'sale_return' and r.status = 'posted'
      and (p_user is null or r.created_by = p_user)
      and (public.dept_allowed(p_company) is null or p_user = auth.uid() or r.department_id = any (public.dept_allowed(p_company)))
    group by r.created_by
  ), u as (select distinct created_by uid from inv union select created_by from ret)
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', u.uid,
    'name', (select coalesce(nullif(full_name, ''), username) from public.profiles where id = u.uid),
    'invoices', (select count(*) from inv where created_by = u.uid and status = 'posted'),
    'cancelled', (select count(*) from inv where created_by = u.uid and status = 'cancelled'),
    'gross', (select coalesce(sum(subtotal + discount_total), 0) from inv where created_by = u.uid and status = 'posted'),
    'discount', (select coalesce(sum(discount_total), 0) from inv where created_by = u.uid and status = 'posted'),
    'tax', (select coalesce(sum(tax_total), 0) from inv where created_by = u.uid and status = 'posted'),
    'total', (select coalesce(sum(total), 0) from inv where created_by = u.uid and status = 'posted'),
    'credit', (select coalesce(sum(total), 0) from inv where created_by = u.uid and status = 'posted' and payment_type = 'credit'),
    'expected_cash', (select coalesce(sum(total), 0) from inv where created_by = u.uid and status = 'posted' and payment_type = 'cash' and is_cash_acc)
                     - coalesce((select cash_out from ret where created_by = u.uid), 0),
    'returns_cash', (select cash_out from ret where created_by = u.uid),
    'first_at', (select min(created_at) from inv where created_by = u.uid), 'last_at', (select max(created_at) from inv where created_by = u.uid),
    'methods', (select coalesce(jsonb_agg(jsonb_build_object('method', m, 'count', n, 'total', t, 'cash', c) order by t desc), '[]') from (
        select coalesce(case when payment_type = 'credit' then 'آجل' end, nullif(pos_method, ''), 'نقدي') m, count(*) n, sum(total) t, bool_and(coalesce(is_cash_acc, false) and payment_type = 'cash') c
        from inv where created_by = u.uid and status = 'posted' group by 1) x),
    'returns', (select n from ret where created_by = u.uid), 'returns_total', (select t from ret where created_by = u.uid),
    'closing', (select to_jsonb(c) from public.pos_closings c where c.company_id = p_company and c.cashier_id = u.uid and c.day = p_day)
  ) order by 2), '[]')
  from u where u.uid is not null
$$;

drop policy if exists posc_select on public.pos_closings;
create policy posc_select on public.pos_closings for select to authenticated using (
  public.has_company(company_id) and (cashier_id = auth.uid()
    or (public.dept_allowed(company_id) is null and (public.can(company_id, 'pos', 'edit') or public.can(company_id, 'sales_invoices', 'view')))));

create or replace function public.password_check(p_tenant uuid, p_pwd text) returns void
language plpgsql stable security definer set search_path = public as $$
declare pol jsonb := public.tenant_password_policy(p_tenant); n int := coalesce((pol ->> 'min_len')::int, 4);
begin
  if coalesce(length(p_pwd), 0) < greatest(n, 4) then raise exception 'كلمة السر لازم تكون % أحرف على الأقل', greatest(n, 4); end if;
  if octet_length(p_pwd) > 72 then raise exception 'كلمة السر طويلة كثير'; end if;
  if coalesce((pol ->> 'require_digit')::boolean, false) and p_pwd !~ '[0-9]' then raise exception 'كلمة السر لازم يكون فيها رقم'; end if;
  if coalesce((pol ->> 'require_letter')::boolean, false) and p_pwd !~ '[A-Za-z]' then raise exception 'كلمة السر لازم يكون فيها حرف إنجليزي'; end if;
  if coalesce((pol ->> 'require_mixed')::boolean, false) and (p_pwd !~ '[A-Z]' or p_pwd !~ '[a-z]') then raise exception 'كلمة السر لازم يكون فيها حرف كبير وحرف صغير'; end if;
  if coalesce((pol ->> 'require_symbol')::boolean, false) and p_pwd !~ '[^A-Za-z0-9]' then raise exception 'كلمة السر لازم يكون فيها رمز (مثل @ # !)'; end if;
end $$;

create or replace function public.change_my_password(p_old text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
declare u uuid := auth.uid(); pr public.profiles; h text;
begin
  select * into pr from public.profiles where id = u;
  if pr.id is null or not pr.is_active then raise exception 'المستخدم مش فعّال'; end if;
  select encrypted_password into h from auth.users where id = u;
  if h is null or extensions.crypt(coalesce(p_old, ''), h) <> h then perform pg_sleep(2); raise exception 'كلمة السر الحالية مش صحيحة'; end if;   -- تأخير ضد التخمين
  if p_new = p_old then raise exception 'كلمة السر الجديدة لازم تختلف عن القديمة'; end if;
  perform public.password_check(pr.tenant_id, p_new);
  update auth.users set encrypted_password = extensions.crypt(p_new, extensions.gen_salt('bf')), updated_at = now() where id = u;
  perform set_config('sumou.pwd', public.internal_token(), true);
  update public.profiles set password_changed_at = now(), must_change_password = false where id = u;
  perform set_config('sumou.pwd', '', true);
  insert into public.activity_log (user_id, action, entity, entity_id, details) values (u, 'تعديل', 'users', u, jsonb_build_object('password_changed', true, 'self', true));
end $$;

revoke execute on function public.ab_guarantee_guard(), public.pos_day_rows(uuid, date, uuid), public.password_check(uuid, text) from public, anon, authenticated;
