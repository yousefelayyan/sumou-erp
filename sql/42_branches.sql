-- =====================================================================
--  السمو ERP — المرحلة 42: الفروع (الدوائر)
--  1) موظف الفرع بيشوف فرعه بس (user_companies.branch_only) — سياسات RLS مقيّدة على القيود والفواتير وسندات المخزون
--  2) تقارير لكل فرع أو مجمّعة مع استثناء فروع (rep_trial_balance بـ p_depts و p_exclude)، وشاشة صلاحية branch_reports
--  3) كاشير لكل فرع (departments.pos) ومستودع ومركز كلفة الفرع بتنحط تلقائياً على الفاتورة وسند المخزون
--  4) «ماذا لو»: whatif_sales — المبيعات والكلفة والربح لكل صنف/فئة/عميل/فرع
-- =====================================================================
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'user_companies' and column_name = 'branch_only') then
    alter table public.user_companies add column branch_only boolean not null default false;
    -- مرة وحدة: «تقارير الفرع» للمجموعات اللي إلها تقارير
    update public.user_groups set permissions = permissions || '{"branch_reports":{"view":true,"print":true}}'::jsonb
     where permissions ? 'reports' and not (permissions ? 'branch_reports');
  end if;
end $$;
alter table public.departments add column if not exists pos jsonb not null default '{}'::jsonb;

-- الدوائر المسموحة للمستخدم بالشركة: null = كل الشركة؛ وإلا دائرته وكل اللي تحتها
create or replace function public.dept_allowed(p_company uuid) returns uuid[]
language sql stable security definer set search_path = public as $$
  with recursive u as (
    select uc.department_id from public.user_companies uc join public.profiles p on p.id = uc.user_id
     where uc.user_id = auth.uid() and uc.company_id = p_company and uc.branch_only and not p.is_admin
  ), t as (
    select d.id from public.departments d join u on d.id = u.department_id where d.company_id = p_company
    union
    select c.id from public.departments c join t on c.parent_id = t.id where c.company_id = p_company
  )
  select case when not exists (select 1 from u) then null else coalesce((select array_agg(id) from t), '{}'::uuid[]) end;
$$;

-- للسياسات (سريعة): الشركات اللي المستخدم فيها «موظف فرع»، وكل الدوائر المسموحة إله (بكل الشركات)
create or replace function public.branch_companies() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(uc.company_id), '{}') from public.user_companies uc join public.profiles p on p.id = uc.user_id
   where uc.user_id = auth.uid() and uc.branch_only and not p.is_admin;
$$;
create or replace function public.branch_depts() returns uuid[]
language sql stable security definer set search_path = public as $$
  with recursive t as (
    select d.id from public.departments d join public.user_companies uc on uc.department_id = d.id and uc.company_id = d.company_id
      join public.profiles p on p.id = uc.user_id where uc.user_id = auth.uid() and uc.branch_only and not p.is_admin
    union
    select c.id from public.departments c join t on c.parent_id = t.id
  ) select coalesce(array_agg(id), '{}') from t;
$$;
create or replace function public.dept_ok(p_company uuid, p_dept uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not (p_company = any (public.branch_companies())) or coalesce(p_dept = any (public.branch_depts()), false);
$$;
-- حماية الكتابة (حتى من دوال الترحيل الداخلية): موظف الفرع ما بيلمس مستند فرع ثاني
create or replace function public.branch_guard(p_company uuid, p_dept uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.dept_ok(p_company, p_dept) then raise exception 'هالمستند لفرع ثاني'; end if;
end $$;
grant execute on function public.dept_allowed(uuid), public.dept_ok(uuid, uuid), public.branch_companies(), public.branch_depts() to authenticated;
revoke execute on function public.dept_allowed(uuid), public.dept_ok(uuid, uuid), public.branch_companies(), public.branch_depts(), public.branch_guard(uuid, uuid) from anon;

create or replace function public.zz_branch_guard_doc() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op <> 'INSERT' then perform public.branch_guard(old.company_id, old.department_id); end if;
  if tg_op <> 'DELETE' then perform public.branch_guard(new.company_id, new.department_id); end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
create or replace function public.zz_branch_guard_line() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb := to_jsonb(case when tg_op = 'DELETE' then old else new end); c uuid; d uuid;
begin
  if cardinality(public.branch_companies()) = 0 then return case when tg_op = 'DELETE' then old else new end; end if;
  if tg_table_name = 'journal_lines' then select company_id, department_id into c, d from public.journal_entries where id = (r ->> 'entry_id')::uuid;
  elsif tg_table_name = 'invoice_lines' then select company_id, department_id into c, d from public.invoices where id = (r ->> 'invoice_id')::uuid;
  else select company_id, department_id into c, d from public.stock_docs where id = (r ->> 'doc_id')::uuid; end if;
  if c is not null then perform public.branch_guard(c, d); end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

do $$
declare t text;
begin
  foreach t in array array['journal_entries', 'invoices', 'stock_docs'] loop
    execute format('drop policy if exists zz_branch_only on public.%I', t);
    execute format('create policy zz_branch_only on public.%I as restrictive for all to authenticated using (not (company_id = any ((select public.branch_companies())::uuid[])) or department_id = any ((select public.branch_depts())::uuid[])) with check (not (company_id = any ((select public.branch_companies())::uuid[])) or department_id = any ((select public.branch_depts())::uuid[]))', t);
    execute format('drop trigger if exists zz_branch_guard on public.%I', t);
    execute format('create trigger zz_branch_guard before insert or update or delete on public.%I for each row execute function public.zz_branch_guard_doc()', t);
  end loop;
  execute 'drop trigger if exists zz_branch_guard on public.journal_lines';
  execute 'create trigger zz_branch_guard before insert or update or delete on public.journal_lines for each row execute function public.zz_branch_guard_line()';
  execute 'drop trigger if exists zz_branch_guard on public.invoice_lines';
  execute 'create trigger zz_branch_guard before insert or update or delete on public.invoice_lines for each row execute function public.zz_branch_guard_line()';
  execute 'drop trigger if exists zz_branch_guard on public.stock_doc_lines';
  execute 'create trigger zz_branch_guard before insert or update or delete on public.stock_doc_lines for each row execute function public.zz_branch_guard_line()';
end $$;

-- سطور مستندات الفروع الثانية ما بتبيّن (can_entry/can_invoice بيشوفوا دائرة المستند)
create or replace function public.can_entry(eid uuid, act text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.journal_entries e
                 where e.id = eid and public.can(e.company_id, public.entry_screen(e.entry_type), act) and public.dept_ok(e.company_id, e.department_id));
$$;
create or replace function public.can_invoice(iid uuid, act text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.invoices i where i.id = iid and public.can(i.company_id, public.invoice_screen(i.inv_type), act) and public.dept_ok(i.company_id, i.department_id));
$$;

-- can(): موظف الفرع ما إله تقارير الشركة كاملة (بياخذ «تقارير الفرع» branch_reports)
create or replace function public.can(cid uuid, screen text, act text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    join public.tenants t on t.id = p.tenant_id and t.status = 'active'
    join public.companies c on c.id = cid and c.tenant_id = p.tenant_id
    where p.id = auth.uid() and p.is_active
      and (t.modules is null or public.screen_module(screen) = 'core' or public.screen_module(screen) = any (t.modules))
      and (act in ('view', 'print') or t.expires_at is null or t.expires_at >= current_date)
      and (p.is_admin or exists (
        select 1 from public.user_companies uc
        left join public.user_groups g on g.id = uc.group_id
        where uc.user_id = p.id and uc.company_id = cid
          and not (uc.branch_only and screen = 'reports')
          and ((case jsonb_typeof(p.permissions -> screen)
                  when 'boolean' then (p.permissions ->> screen)::boolean
                  when 'object'  then coalesce((p.permissions -> screen ->> act)::boolean, false)
                  else false end)
               or coalesce((g.permissions -> screen ->> act)::boolean, false))))
  );
$$;

-- ميزان المراجعة لفرع/دوائر، أو للشركة باستثناء فروع (أساس قائمة الدخل والميزانية)
drop function if exists public.rep_trial_balance(uuid, uuid, date, date);
create or replace function public.rep_trial_balance(p_company uuid, p_fy uuid, p_from date, p_to date, p_depts uuid[] default null, p_exclude uuid[] default null)
returns table (account_id uuid, open_debit numeric, open_credit numeric, period_debit numeric, period_credit numeric)
language plpgsql stable security definer set search_path = public as $$
declare al uuid[] := public.dept_allowed(p_company); ds uuid[] := p_depts;
begin
  if not (public.can(p_company, 'reports', 'view') or (al is not null and public.can(p_company, 'branch_reports', 'view'))) then
    raise exception 'ما عندك صلاحية على التقارير';
  end if;
  if al is not null then
    ds := case when ds is null then al else (select coalesce(array_agg(x), '{}') from unnest(ds) x where x = any (al)) end;
  end if;
  return query
  select l.account_id,
         coalesce(sum(l.debit)  filter (where e.entry_date < p_from or e.entry_type = 'opening'), 0),
         coalesce(sum(l.credit) filter (where e.entry_date < p_from or e.entry_type = 'opening'), 0),
         coalesce(sum(l.debit)  filter (where e.entry_date >= p_from and e.entry_type <> 'opening'), 0),
         coalesce(sum(l.credit) filter (where e.entry_date >= p_from and e.entry_type <> 'opening'), 0)
  from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
  where e.company_id = p_company and e.fiscal_year_id = p_fy and e.status in ('posted','reversed')
    and e.entry_date <= p_to
    and e.entry_type <> 'closing'
    and (ds is null or e.department_id = any (ds))
    and (p_exclude is null or e.department_id is null or not (e.department_id = any (p_exclude)))
  group by l.account_id;
end $$;
grant execute on function public.rep_trial_balance(uuid, uuid, date, date, uuid[], uuid[]) to authenticated;
revoke execute on function public.rep_trial_balance(uuid, uuid, date, date, uuid[], uuid[]) from anon;

-- إعدادات كاشير الفرع: المستودع والحسابات لازم من نفس الشركة
create or replace function public.ad_department_pos_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare k text;
begin
  if coalesce(new.pos, '{}'::jsonb) = '{}'::jsonb then return new; end if;
  if jsonb_typeof(new.pos) <> 'object' then raise exception 'إعدادات الكاشير مش صحيحة'; end if;
  new.pos := (select coalesce(jsonb_object_agg(key, value), '{}') from jsonb_each(new.pos)
               where key in ('warehouse_id','cash_account_id','card_account_id','header','footer') and value <> 'null'::jsonb and value <> '""'::jsonb);
  if new.pos ? 'warehouse_id' and not exists (select 1 from public.warehouses w where w.id = (new.pos ->> 'warehouse_id')::uuid and w.company_id = new.company_id) then
    raise exception 'مستودع الكاشير مش من نفس الشركة';
  end if;
  foreach k in array array['cash_account_id', 'card_account_id'] loop
    if new.pos ? k and not exists (select 1 from public.accounts a where a.id = (new.pos ->> k)::uuid and a.company_id = new.company_id and not a.is_group and a.account_type in ('cash', 'bank')) then
      raise exception 'حساب الكاشير لازم يكون صندوق أو بنك من نفس الشركة';
    end if;
  end loop;
  if length(coalesce(new.pos ->> 'header', '')) > 500 or length(coalesce(new.pos ->> 'footer', '')) > 500 then raise exception 'نص الوصل طويل'; end if;
  return new;
end $$;
drop trigger if exists ad_department_pos_check on public.departments;
create trigger ad_department_pos_check before insert or update of pos on public.departments for each row execute function public.ad_department_pos_check();

-- مستودع ومركز كلفة الفرع بينحطوا تلقائياً (قبل الترقيم aa_ عشان «تسلسل لكل مركز كلفة» يصير تسلسل لكل فرع)
create or replace function public.a0_dept_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare dep uuid := new.department_id; d public.departments;
begin
  if public.is_internal() then return new; end if;
  if dep is null then
    select uc.department_id into dep from public.user_companies uc where uc.user_id = auth.uid() and uc.company_id = new.company_id;
  end if;
  if dep is null then return new; end if;
  select * into d from public.departments where id = dep and company_id = new.company_id and is_active;
  if d.id is null then return new; end if;
  if tg_table_name = 'invoices' then
    if (to_jsonb(new) ->> 'cost_center_id') is null and d.cost_center_id is not null then new.cost_center_id := d.cost_center_id; end if;
    if (to_jsonb(new) ->> 'warehouse_id') is null and d.warehouse_id is not null then new.warehouse_id := d.warehouse_id; end if;
  end if;
  return new;
end $$;
drop trigger if exists a0_dept_defaults on public.invoices;
create trigger a0_dept_defaults before insert on public.invoices for each row execute function public.a0_dept_defaults();

-- «ماذا لو»: المبيعات المرحّلة (ناقص المرتجع) مع الكلفة الفعلية من حركات المخزون
create or replace function public.whatif_sales(p_company uuid, p_from date, p_to date)
returns table (department_id uuid, item_id uuid, category_id uuid, party_id uuid, party_name text, qty numeric, net numeric, cost numeric)
language plpgsql stable security definer set search_path = public as $$
declare al uuid[] := public.dept_allowed(p_company);
begin
  if not (public.can(p_company, 'reports', 'view') or (al is not null and public.can(p_company, 'branch_reports', 'view'))) then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  with l as (
    select v.id, v.department_id, il.item_id, v.party_id, coalesce(p.name, v.party_name, 'نقدي') pname,
           case when v.inv_type = 'sale_return' then -1 else 1 end sgn, il.qty, il.subtotal
      from public.invoices v join public.invoice_lines il on il.invoice_id = v.id left join public.parties p on p.id = v.party_id
     where v.company_id = p_company and v.inv_type in ('sale','sale_return') and v.status = 'posted'
       and v.inv_date between p_from and p_to and (al is null or v.department_id = any (al))
  ), c as (   -- كلفة كل صنف بكل فاتورة من حركات المخزون
    select m.source_id, m.item_id, sum(-m.qty * m.unit_cost) cst, sum(-m.qty) mq
      from public.stock_moves m where m.company_id = p_company and m.source_type = 'invoice' and m.source_id in (select id from l)
     group by m.source_id, m.item_id
  ), lq as (select l.id, l.item_id, sum(l.qty) tq from l group by l.id, l.item_id)
  select l.department_id, l.item_id, i.category_id, l.party_id, l.pname,
         sum(l.sgn * l.qty), sum(l.sgn * l.subtotal),
         sum(case when lq.tq <> 0 then coalesce(c.cst, 0) * l.qty / lq.tq else 0 end)
    from l join lq on lq.id = l.id and lq.item_id is not distinct from l.item_id
    left join c on c.source_id = l.id and c.item_id = l.item_id
    left join public.items i on i.id = l.item_id
   group by l.department_id, l.item_id, i.category_id, l.party_id, l.pname;
end $$;
grant execute on function public.whatif_sales(uuid, date, date) to authenticated;
revoke execute on function public.whatif_sales(uuid, date, date) from anon;


-- نقطة البيع: كاشير الفرع
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
  -- إعدادات كاشير الفرع (دائرة المستخدم الافتراضية) بتغطي على إعدادات الشركة
  cfg := cfg || coalesce((select d.pos || case when d.pos ? 'warehouse_id' or d.warehouse_id is null then '{}'::jsonb else jsonb_build_object('warehouse_id', d.warehouse_id) end
                           from public.user_companies uc join public.departments d on d.id = uc.department_id and d.company_id = uc.company_id and d.is_active
                           where uc.user_id = auth.uid() and uc.company_id = cid), '{}'::jsonb);
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

-- اسأل السمو: موظف الفرع بيشوف مبيعات فرعه بس
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
       and (public.dept_allowed(p_company) is null or v.department_id = any (public.dept_allowed(p_company)))
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

-- بانتظار الترحيل: موظف الفرع بيشوف مسودات فرعه بس
create or replace function public.pending_posts(p_company uuid)
returns table (kind text, id uuid, doc_type text, doc_no int, doc_date date, description text, amount numeric, created_by uuid, created_at timestamptz, doc_code text)
language plpgsql stable security definer set search_path = public as $$
declare al uuid[] := public.dept_allowed(p_company);
begin
  if not public.has_company(p_company) then raise exception 'ما عندك صلاحية'; end if;
  return query
  select 'entry', e.id, e.entry_type, e.entry_no, e.entry_date, e.description,
         (select coalesce(sum(jl.debit), 0) from public.journal_lines jl where jl.entry_id = e.id), e.created_by, e.created_at, e.doc_code
  from public.journal_entries e where e.company_id = p_company and e.status = 'draft' and public.can(p_company, public.entry_screen(e.entry_type), 'view') and (al is null or e.department_id = any (al))
  union all
  select 'invoice', i.id, i.inv_type, i.inv_no, i.inv_date, coalesce(i.party_name, (select pp.name from public.parties pp where pp.id = i.party_id)), i.total, i.created_by, i.created_at, i.doc_code
  from public.invoices i where i.company_id = p_company and i.status = 'draft' and public.can(p_company, public.invoice_screen(i.inv_type), 'view') and (al is null or i.department_id = any (al))
  union all
  select 'stock', d.id, d.doc_type, d.doc_no, d.doc_date, d.notes, null::numeric, d.created_by, d.created_at, d.doc_code
  from public.stock_docs d where d.company_id = p_company and d.status = 'draft' and public.can(p_company, 'inventory', 'view') and (al is null or d.department_id = any (al))
  order by 9 desc;
end $$;
