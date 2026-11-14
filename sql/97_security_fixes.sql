-- =====================================================================
--  المرحلة 97: تصليحات مراجعة الأمان
--  - قفل كلمة السر (pwd_ok) صار كمان على has_company و is_super
--  - دوال كانت بتكشف أرقام بدون صلاحية: ضوابط القروض، رصيد الحساب، مجمع الاستهلاك، سجل التتبع
--  - المرفقات: موظف الفرع ما بيشوف مرفقات فرع ثاني، والإرفاق بس لشاشة بتشوفها وبنفس مسار المستند، وأنواع ملفات محددة
--  - سجل النشاط: الإدخال المباشر من المتصفح بينعلّم، وتصوير الشاشة من النظام بس
--  - رسائل السجل، شعار الشركة، والدوال ما بتنفتح للزائر (anon) إلا التسجيل بالتجربة
--  آمن يتشغّل أكثر من مرة
-- =====================================================================

-- 0) قفل كلمة السر على الوصول للشركة ومدير المنصة (change_my_password و my_password_status ما بيستعملوهم)
create or replace function public.has_company(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    join public.tenants t on t.id = p.tenant_id and t.status = 'active'
    join public.companies c on c.id = cid and c.tenant_id = p.tenant_id
    where p.id = auth.uid() and p.is_active
      and (p.is_admin or (c.is_active and exists (
             select 1 from public.user_companies uc where uc.user_id = p.id and uc.company_id = cid)))
      -- قفل كلمة السر (نفس شرط pwd_ok بدون استعلام ثاني)
      and not p.must_change_password
      and not (coalesce((t.settings -> 'password_policy' ->> 'expiry_days')::int, 0) > 0
               and coalesce(p.password_changed_at, '-infinity') < now() - make_interval(days => (t.settings -> 'password_policy' ->> 'expiry_days')::int))
  );
$$;
create or replace function public.is_super() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_super and is_active from public.profiles where id = auth.uid()), false) and public.pwd_ok();
$$;

-- رصيد الحساب بالدفاتر (التسوية البنكية): بصلاحية التسوية أو التقارير
create or replace function public.account_book_balance(p_company uuid, p_account uuid, p_date date) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(l.debit - l.credit), 0) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
  where l.account_id = p_account and e.company_id = p_company and e.status in ('posted','reversed') and e.entry_type <> 'closing'
    and e.entry_date <= p_date
    and (public.can(p_company, 'bank_recon', 'view') or public.can(p_company, 'reports', 'view'))
    and e.fiscal_year_id = (select id from public.fiscal_years where company_id = p_company and p_date between start_date and end_date order by start_date desc limit 1);
$$;

-- مجمع استهلاك الأصل: لصلاحية الأصول أو الرواتب (شاشة الاستهلاك) أو الداخلي
create or replace function public.asset_accum(p_asset uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.fixed_assets f where f.id = p_asset and (public.is_internal()
                or public.can(f.company_id, 'fixed_assets', 'view') or public.can(f.company_id, 'fixed_assets', 'post')
                or public.can(f.company_id, 'payroll', 'view'))) then
    coalesce((select opening_accum from public.fixed_assets where id = p_asset), 0)
       + coalesce((select sum(l.amount) from public.depreciation_lines l join public.depreciation_runs r on r.id = l.run_id
                   where l.asset_id = p_asset and r.status = 'posted'), 0) end;
$$;

-- تعبئة حسابات الرواتب الافتراضية: لمين إله الرواتب أو الأصول أو إعدادات الشركة
create or replace function public.ensure_payroll_settings(p_company uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_internal() or public.can(p_company, 'payroll', 'view') or public.can(p_company, 'fixed_assets', 'view')
          or public.can(p_company, 'companies', 'edit')) then return; end if;
  perform public.ensure_company_settings(p_company);
  update public.company_settings s set
    salaries_account_id         = coalesce(s.salaries_account_id,         (select id from public.accounts where company_id = p_company and code = '5201' and not is_group)),
    ss_expense_account_id       = coalesce(s.ss_expense_account_id,       (select id from public.accounts where company_id = p_company and code = '5202' and not is_group)),
    ss_payable_account_id       = coalesce(s.ss_payable_account_id,       (select id from public.accounts where company_id = p_company and code = '2105' and not is_group)),
    wht_payable_account_id      = coalesce(s.wht_payable_account_id,      (select id from public.accounts where company_id = p_company and code = '2104' and not is_group)),
    salaries_payable_account_id = coalesce(s.salaries_payable_account_id, (select id from public.accounts where company_id = p_company and code = '2106' and not is_group)),
    advances_account_id         = coalesce(s.advances_account_id,         (select id from public.accounts where company_id = p_company and code = '1107' and not is_group)),
    depreciation_account_id     = coalesce(s.depreciation_account_id,     (select id from public.accounts where company_id = p_company and code = '5213' and not is_group)),
    accum_dep_account_id        = coalesce(s.accum_dep_account_id,        (select id from public.accounts where company_id = p_company and code = '1209' and not is_group))
  where s.company_id = p_company;
end $$;

create or replace function public.bom_has_lines(p_bom uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bom_lines l join public.boms b on b.id = l.bom_id where l.bom_id = p_bom and public.has_company(b.company_id))
$$;

-- سجل التتبع: كل سطر بيبيّن بس إذا المستخدم بيشوف شاشة المستند (وفرعه)
create or replace function public.doc_hist_ok(p_company uuid, p_entity text, p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    -- المستند المحذوف: سجله للمدير أو لصلاحية التقارير
    when p_entity in ('journal_entries','receipt_vouchers','payment_vouchers') then
      case when exists (select 1 from public.journal_entries e where e.id = p_id) then public.can_entry(p_id, 'view')
           else public.is_admin() or public.can(p_company, 'reports', 'view') end
    when p_entity in ('invoices','sales_invoices','purchase_invoices') then
      case when exists (select 1 from public.invoices i where i.id = p_id) then public.can_invoice(p_id, 'view')
           else public.is_admin() or public.can(p_company, 'reports', 'view') end
    when p_entity = 'orders' then exists (select 1 from public.orders o where o.id = p_id
                     and public.can(o.company_id, case when o.order_type = 'purchase_order' then 'purchase_orders' else 'sales_orders' end, 'view'))
                     or (not exists (select 1 from public.orders o where o.id = p_id) and public.is_admin())
    when p_entity in ('cheques','guarantee_cheques') then public.can(p_company, 'cheques', 'view')
    when p_entity = 'party_notes' then public.can(p_company, 'customer_notes', 'view') or public.can(p_company, 'supplier_notes', 'view')
    when p_entity = 'contracts' then public.can(p_company, 'contracts', 'view')
    when p_entity in ('items','item_categories') then public.can(p_company, 'items', 'view')
    when p_entity in ('stock_docs','inventory') then exists (select 1 from public.stock_docs d where d.id = p_id
                     and public.can(d.company_id, 'inventory', 'view') and public.dept_ok(d.company_id, d.department_id))
                     or (not exists (select 1 from public.stock_docs d where d.id = p_id) and public.can(p_company, 'inventory', 'view'))
    when p_entity in ('employees','payroll_runs','payroll','loan','leaves','attendance') then public.can(p_company, 'payroll', 'view')
    when p_entity in ('fixed_assets','asset_movements','depreciation_runs') then public.can(p_company, 'fixed_assets', 'view')
    when p_entity = 'custody_docs' then public.can(p_company, 'asset_custody', 'view')
    when p_entity = 'parties' then exists (select 1 from public.parties pa where pa.id = p_id and public.can(pa.company_id, public.party_screen(pa.party_type), 'view'))
    when p_entity in ('users','tenants','screen') then public.is_admin()
    else public.has_company(p_company) end;
$$;
revoke execute on function public.doc_hist_ok(uuid, text, uuid) from public, anon, authenticated;

create or replace function public.doc_history(p_id uuid)
returns table (created_at timestamptz, user_name text, action text, entity text, details jsonb)
language sql stable security definer set search_path = public as $$
  select l.created_at, coalesce(nullif(p.full_name, ''), nullif(p.username, ''), split_part(p.email, '@', 1)), l.action, l.entity, l.details
  from public.activity_log l left join public.profiles p on p.id = l.user_id
  where l.entity_id = p_id::text and l.company_id is not null and public.has_company(l.company_id)
    and public.doc_hist_ok(l.company_id, l.entity, p_id)
  order by l.created_at desc, l.id desc limit 500;
$$;
revoke execute on function public.doc_history(uuid) from public, anon;
grant execute on function public.doc_history(uuid) to authenticated;

-- 1) ضوابط القروض: ما بتكشف الراتب لغير المخوّل
create or replace function public.loan_rule_issues(p_loan uuid) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare l public.employee_loans; e public.employees; r jsonb; sal numeric; inst numeric; n int; out text[] := '{}';
begin
  select * into l from public.employee_loans where id = p_loan;
  if l.id is null then return out; end if;
  -- بس الداخلي أو صلاحية الرواتب أو الموظف صاحب القرض
  if not (public.is_internal() or public.can(l.company_id, 'payroll', 'view') or public.can(l.company_id, 'payroll', 'post')
          or l.employee_id is not distinct from coalesce(public.my_employee(l.company_id), '00000000-0000-0000-0000-000000000000'::uuid)) then return out; end if;
  select * into e from public.employees where id = l.employee_id;
  r := coalesce((select loan_rules from public.company_settings where company_id = l.company_id), '{}'::jsonb);
  sal := coalesce(e.basic_salary, 0) + coalesce(e.allowances, 0);
  inst := l.amount / greatest(l.installments, 1);
  if r ? 'max_multiple' and sal > 0 and l.kind = 'loan' and l.amount > sal * (r ->> 'max_multiple')::numeric + 0.0005 then
    out := out || format('المبلغ أكثر من %s ضعف الراتب (%s)', r ->> 'max_multiple', round(sal * (r ->> 'max_multiple')::numeric, 3)); end if;
  if r ? 'max_inst_pct' and sal > 0 and l.kind = 'loan' and inst > sal * (r ->> 'max_inst_pct')::numeric / 100 + 0.0005 then
    out := out || format('القسط (%s) أكثر من %s%% من الراتب', round(inst, 3), r ->> 'max_inst_pct'); end if;
  if r ? 'advance_max_pct' and sal > 0 and l.kind = 'advance' and l.amount > sal * (r ->> 'advance_max_pct')::numeric / 100 + 0.0005 then
    out := out || format('السلفة أكثر من %s%% من الراتب (%s)', r ->> 'advance_max_pct', round(sal * (r ->> 'advance_max_pct')::numeric / 100, 3)); end if;
  if r ? 'max_installments' and l.installments > (r ->> 'max_installments')::numeric then
    out := out || format('عدد الأقساط أكثر من %s', r ->> 'max_installments'); end if;
  if r ? 'max_open' then
    select count(*) into n from public.employee_loans x where x.employee_id = l.employee_id and x.id <> l.id
       and (x.status = 'pending' or (x.status = 'approved' and exists (select 1 from public.loan_installments i where i.loan_id = x.id and i.status = 'pending')));
    if n >= (r ->> 'max_open')::numeric then out := out || format('عنده %s قرض/سلفة مفتوحة (الحد %s)', n, r ->> 'max_open'); end if;
  end if;
  if r ? 'min_service_months' and e.hire_date is not null
     and e.hire_date + make_interval(months => (r ->> 'min_service_months')::int) > l.request_date then
    out := out || format('مدة خدمته أقل من %s شهر', r ->> 'min_service_months'); end if;
  return out;
end $$;
-- 2) طلب/رفض التأجيل: الاشتراك ساري
create or replace function public.loan_defer_request(p_inst uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare x public.loan_installments; l public.employee_loans;
begin
  select * into x from public.loan_installments where id = p_inst for update;
  select * into l from public.employee_loans where id = x.loan_id;
  if l.id is null then raise exception 'القسط مش موجود'; end if;
  if not public.tenant_writable() or not public.pwd_ok() then raise exception 'ما عندك صلاحية'; end if;
  if l.employee_id is distinct from public.my_employee(l.company_id) then raise exception 'بتقدر تطلب تأجيل أقساطك بس'; end if;
  if x.status <> 'pending' or l.status <> 'approved' then raise exception 'القسط مدفوع أو القرض مش فعّال'; end if;
  if x.defer_request is not null then raise exception 'في طلب تأجيل لهالقسط بالانتظار'; end if;
  update public.loan_installments set defer_request = coalesce(nullif(left(trim(p_note), 300), ''), 'طلب تأجيل'), defer_requested_at = now() where id = p_inst;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), l.company_id, 'طلب تأجيل', 'loan', l.id::text, jsonb_build_object('no', l.loan_no, 'seq', x.seq, 'month', x.due_month));
end $$;
create or replace function public.loan_defer_reject(p_inst uuid) returns void
language plpgsql security definer set search_path = public as $$
declare x public.loan_installments; l public.employee_loans;
begin
  select * into x from public.loan_installments where id = p_inst for update;
  select * into l from public.employee_loans where id = x.loan_id;
  if l.id is null or not public.can(l.company_id, 'payroll', 'post') or not public.tenant_writable() then raise exception 'ما عندك صلاحية'; end if;
  update public.loan_installments set defer_request = null, defer_requested_at = null where id = p_inst;
end $$;
-- 3) كلمة السر من مدير المنصة بتمشي على سياسة المشترك
create or replace function public.super_set_user(p_user uuid, p_password text, p_is_active boolean)
returns void language plpgsql security definer set search_path = public, extensions, auth as $$
declare pr public.profiles; prev text := current_setting('sumou.internal', true);
begin
  if not public.is_super() then raise exception 'هالعملية لمدير المنصة بس'; end if;
  select * into pr from public.profiles where id = p_user;
  if pr.id is null then raise exception 'المستخدم مش موجود'; end if;
  if pr.id = auth.uid() and p_is_active is false then raise exception 'ما بتقدر توقف حالك'; end if;
  if coalesce(p_password, '') <> '' then
    perform public.password_check(pr.tenant_id, p_password);
    update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now() where id = p_user;
  end if;
  if p_is_active is not null and p_is_active <> pr.is_active then
    if p_is_active then perform public.tenant_user_slot_check(pr.tenant_id, p_user); end if;
    perform set_config('sumou.internal', public.internal_token(), true);
    update public.profiles set is_active = p_is_active where id = p_user;
    perform set_config('sumou.internal', coalesce(prev, ''), true);
  end if;
  insert into public.activity_log (user_id, action, entity, entity_id, details, tenant_id)
  values (auth.uid(), 'تعديل', 'users', p_user, jsonb_build_object('by_super', true, 'password_changed', coalesce(p_password, '') <> '', 'is_active', p_is_active), pr.tenant_id);
end $$;
-- 4) التجربة المجانية: عنوان الجهاز ما بينزوّر
create or replace function public.trial_signup(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions, auth as $$
declare nm text := nullif(trim(p ->> 'name'), ''); co text := nullif(trim(p ->> 'company'), '');
  ph text := regexp_replace(coalesce(p ->> 'phone', ''), '[^0-9+]', '', 'g'); un text := lower(trim(coalesce(p ->> 'username', '')));
  pw text := coalesce(p ->> 'password', ''); em text := nullif(lower(trim(p ->> 'email')), '');
  c text; tid uuid; uid uuid; i int := 0; ip text; prev text := current_setting('sumou.internal', true);
begin
  if not exists (select 1 from public.demo_template where id = 1) then raise exception 'التجربة المجانية مش متاحة هسا'; end if;
  if nm is null or length(nm) > 80 then raise exception 'اكتب اسمك'; end if;
  if co is null or length(co) > 100 then raise exception 'اكتب اسم الشركة أو النشاط'; end if;
  if ph !~ '^\+?[0-9]{9,15}$' then raise exception 'رقم الموبايل مش صحيح'; end if;
  if em is not null and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'الإيميل مش صحيح'; end if;
  if un !~ '^[a-z0-9._-]{3,30}$' then raise exception 'اسم المستخدم لازم يكون أحرف إنجليزي أو أرقام (3 لـ 30)'; end if;
  if length(pw) < 6 or length(pw) > 72 then raise exception 'كلمة السر لازم تكون 6 أحرف على الأقل'; end if;
  -- حدود: نفس الرقم مرة وحدة بالشهر، وعدد التسجيلات بالساعة واليوم
  perform pg_advisory_xact_lock(hashtext('trial_signup'));
  if exists (select 1 from public.tenants where is_trial and phone = ph and created_at > now() - interval '30 days') then
    raise exception 'هالرقم إله تجربة من قبل. تواصل معنا لتمديدها أو للاشتراك';
  end if;
  -- عنوان الجهاز من Cloudflare (ما بيتزوّر)، وإلا أول عنوان مثل قبل
  ip := coalesce(nullif(trim(current_setting('request.headers', true)::json ->> 'cf-connecting-ip'), ''),
                nullif(trim(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1)), ''));
  if ip is not null and (select count(*) from public.tenants where is_trial and signup_ip = ip and created_at > now() - interval '1 day') >= 3 then
    raise exception 'سجّلت تجارب كثير من نفس الجهاز اليوم. تواصل معنا';
  end if;
  if (select count(*) from public.tenants where is_trial and created_at > now() - interval '1 hour') >= 30
     or (select count(*) from public.tenants where is_trial and created_at > now() - interval '1 day') >= 150 then
    raise exception 'في ضغط على التسجيل هسا، جرّب بعد شوي';
  end if;
  loop
    c := 'd' || lpad((floor(random() * 100000))::int::text, 5, '0');
    exit when not exists (select 1 from public.tenants where code = c);
    i := i + 1; if i > 30 then raise exception 'جرّب مرة ثانية'; end if;
  end loop;
  insert into public.tenants (code, name, status, plan, max_users, max_companies, max_docs, modules, expires_at, contact_name, phone, email, notes, is_trial, signup_ip)
  values (c, co, 'active', 'تجربة مجانية', 2, 1, 300, null, public.local_today() + 13, nm, ph, em, 'تسجيل ذاتي', true, ip)
  returning id into tid;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.user_groups (name, description, permissions, tenant_id)
  select g.name, g.description, g.permissions, tid from public.user_groups g
   where g.tenant_id = public.default_tenant() and g.name in ('محاسب', 'مدخل بيانات', 'مشاهد', 'كاشير');
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  uid := public.create_tenant_user(tid, un, nm, pw, '{}'::jsonb, '{}', true);
  insert into public.activity_log (user_id, action, entity, entity_id, details, tenant_id)
  values (uid, 'إضافة', 'tenants', tid, jsonb_build_object('trial', true, 'phone', ph, 'company', co), tid);
  return jsonb_build_object('code', c, 'username', un, 'expires_at', public.local_today() + 13);
end $$;
-- 5) المرفقات
-- مرفق المستند بيبيّن لمين بيشوف المستند نفسه (الشاشة والفرع)
create or replace function public.att_doc_ok(p_company uuid, p_entity text, p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case p_entity
    when 'entry'     then exists (select 1 from public.journal_entries e where e.id = p_id and e.company_id = p_company) and public.can_entry(p_id, 'view')
    when 'invoice'   then exists (select 1 from public.invoices i where i.id = p_id and i.company_id = p_company) and public.can_invoice(p_id, 'view')
    when 'stock_doc' then exists (select 1 from public.stock_docs d where d.id = p_id and d.company_id = p_company
                                  and public.can(p_company, 'inventory', 'view') and public.dept_ok(p_company, d.department_id))
    when 'cheque'    then public.can(p_company, 'cheques', 'view')
    when 'guarantee_cheque' then exists (select 1 from public.guarantee_cheques g where g.id = p_id and g.company_id = p_company
                                  and public.can(p_company, 'cheques', 'view') and public.dept_ok(p_company, g.department_id))
    when 'party_doc' then exists (select 1 from public.party_documents d join public.parties pa on pa.id = d.party_id
                                  where d.id = p_id and pa.company_id = p_company and public.can(p_company, public.party_screen(pa.party_type), 'view'))
    else true end;
$$;
revoke execute on function public.att_doc_ok(uuid, text, uuid) from public, anon;
grant execute on function public.att_doc_ok(uuid, text, uuid) to authenticated;

drop policy if exists att_select on public.attachments;
create policy att_select on public.attachments for select to authenticated
  using (public.attachment_visible(company_id, entity) and public.att_doc_ok(company_id, entity, entity_id));
drop policy if exists att_insert on public.attachments;
create policy att_insert on public.attachments for insert to authenticated
  with check (public.has_company(company_id) and public.tenant_writable() and created_by = auth.uid()
              and public.attachment_visible(company_id, entity) and public.att_doc_ok(company_id, entity, entity_id)
              and path like company_id::text || '/' || entity || '/' || entity_id::text || '/%' and path !~ '\.\.');
-- نفس الملف ما بينربط بسطرين
do $$
begin
  if not exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'attachments_path_uq') then
    begin
      create unique index attachments_path_uq on public.attachments (path);
    exception when unique_violation then raise notice 'في مسارات مكررة بالمرفقات، الفهرس الفريد ما انعمل';
    end;
  end if;
end $$;

do $$
begin
  if to_regclass('storage.objects') is not null then
    -- الرفع بس بمجلد شاشة بيشوفها المستخدم
    execute 'drop policy if exists sumou_att_insert on storage.objects';
    execute $p$create policy sumou_att_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'attachments' and public.has_company(((storage.foldername(name))[1])::uuid) and public.tenant_writable()
                  and public.attachment_visible(((storage.foldername(name))[1])::uuid, (storage.foldername(name))[2]))$p$;
  end if;
  if to_regclass('storage.buckets') is not null then
    begin
      update storage.buckets set allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif','image/heic','image/heif',
        'application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'application/vnd.ms-powerpoint','application/vnd.openxmlformats-officedocument.presentationml.presentation',
        'text/plain','text/csv','application/zip'], file_size_limit = 10485760
      where id = 'attachments';
    exception when others then raise notice 'ما قدرت أحدد أنواع ملفات المرفقات: %', sqlerrm;
    end;
  end if;
end $$;

-- حذف الملف: ممنوع إذا في سطر مرفق إله لغيرك (حتى لو مش ظاهر إلك)
create or replace function public.att_path_deletable(p_path text) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.attachments a where a.path = p_path and not (a.created_by = auth.uid() or public.is_admin()));
$$;
revoke execute on function public.att_path_deletable(text) from public, anon;
grant execute on function public.att_path_deletable(text) to authenticated;
do $$
begin
  if to_regclass('storage.objects') is not null then
    execute 'drop policy if exists sumou_att_delete on storage.objects';
    execute $p$create policy sumou_att_delete on storage.objects for delete to authenticated
      using (bucket_id = 'attachments' and public.has_company(((storage.foldername(name))[1])::uuid) and public.tenant_writable()
             and public.att_path_deletable(name))$p$;
  end if;
end $$;

-- 6) سجل النشاط: الإدخال المباشر من المتصفح بينعلّم (client)، وتصوير الشاشة والإيقاف من النظام بس
create or replace function public.ab_activity_log_client() returns trigger
language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') then
    if lower(trim(coalesce(new.entity, ''))) = 'screen' or trim(coalesce(new.action, '')) in ('تصوير شاشة', 'إيقاف بسبب تصوير الشاشة') then
      raise exception 'هالسجل بينكتب من النظام بس';
    end if;
    new.details := case when jsonb_typeof(new.details) = 'object' then new.details else jsonb_build_object('value', new.details) end
                   || jsonb_build_object('client', true);
  end if;
  return new;
end $$;
drop trigger if exists ab_activity_log_client on public.activity_log;
create trigger ab_activity_log_client before insert on public.activity_log for each row execute function public.ab_activity_log_client();
-- ما في تعديل أو حذف للسجل من المتصفح
revoke update, delete on public.activity_log from authenticated, anon;

-- 7) سجل الرسائل: الإدخال لمين إله شاشة بتبعت رسائل
create or replace function public.party_of_company(p_party uuid, p_company uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.parties where id = p_party and company_id = p_company);
$$;
revoke execute on function public.party_of_company(uuid, uuid) from public, anon;
grant execute on function public.party_of_company(uuid, uuid) to authenticated;
drop policy if exists ml_insert on public.message_log;
create policy ml_insert on public.message_log for insert to authenticated
  with check (public.has_company(company_id) and public.tenant_writable() and sent_by = auth.uid()
              and (public.can(company_id, 'marketing', 'add') or public.can(company_id, 'sales_invoices', 'view')
                   or public.can(company_id, 'purchase_invoices', 'view') or public.can(company_id, 'receipt_vouchers', 'add')
                   or public.can(company_id, 'customers', 'view') or public.can(company_id, 'suppliers', 'view'))
              and (party_id is null or public.party_of_company(party_id, company_id)));

-- 8) شعار الشركة: رابط http(s) أو صورة مضمّنة بس (مش javascript: أو غيره)
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'companies_logo_url_chk') then
    alter table public.companies add constraint companies_logo_url_chk
      check (logo_url is null or logo_url = '' or logo_url ~ '^https?://[^\s"''<>]+$' or logo_url ~ '^data:image/[a-z0-9.+-]+;base64,[A-Za-z0-9+/=\s]+$') not valid;
  end if;
end $$;

-- 9) الزائر (بدون دخول) ما بيشغّل أي دالة إلا التسجيل بالتجربة.
-- صلاحية public الافتراضية بتنشال؛ والمستخدم المسجّل بياخذها صريحة بس إذا كانت إله أصلاً (الدوال الداخلية بتضل مسكّرة)
do $$
declare r record; auth_had boolean;
begin
  for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
             and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    auth_had := has_function_privilege('authenticated', r.f, 'execute');
    if auth_had then
      execute format('grant execute on function %s to authenticated', r.f);
      if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('grant execute on function %s to service_role', r.f); end if;
    end if;
    execute format('revoke execute on function %s from public, anon', r.f);
  end loop;
end $$;
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon;
grant execute on function public.trial_signup(jsonb) to anon, authenticated;
