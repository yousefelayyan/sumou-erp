-- =====================================================================
--  السمو ERP — المرحلة 41: التجربة المجانية (تسجيل ذاتي بمشترك تجريبي)
--  أي حدا بيسجّل من شاشة الدخول: بينعمله مشترك تجريبي لحاله (14 يوم، حد حركات، مستخدمين اثنين، شركة وحدة)
--  وبعد أول دخول بتنعمله نسخة من «شركة القالب» اللي بيختارها مدير المنصة (بأرقام جديدة، منفصلة تماماً).
-- =====================================================================
alter table public.tenants add column if not exists is_trial boolean not null default false;
alter table public.tenants add column if not exists max_docs int check (max_docs is null or max_docs > 0);
alter table public.tenants add column if not exists signup_ip text;
create index if not exists tenants_trial_created on public.tenants (created_at) where is_trial;

-- قالب التجربة: نسخة احتياطية من شركة بيختارها مدير المنصة
create table if not exists public.demo_template (
  id           int primary key default 1 check (id = 1),
  company_name text,
  data         jsonb not null,
  updated_at   timestamptz not null default now(),
  updated_by   uuid
);
alter table public.demo_template enable row level security;
revoke all on public.demo_template from anon, authenticated;

create or replace function public.super_set_demo_template(p_company uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d jsonb; nm text;
begin
  if not public.is_super() or not public.has_company(p_company) then raise exception 'هالعملية لمدير المنصة بس'; end if;
  select name into nm from public.companies where id = p_company;
  -- حماية: القالب لازم يكون شركة تجريبية (اسمها فيه «تجريب» أو «عرض» أو demo)، مش شركة زبون حقيقي
  if nm !~* '(تجريب|عرض|ديمو|demo)' then raise exception 'القالب لازم يكون شركة تجريبية: سمّيها مثلاً «شركة العرض» أو «شركة تجريبية»'; end if;
  d := public.backup_company(p_company);
  -- بدون مرفقات وزيارات (مواقع) ومتابعة إقرارات
  d := jsonb_set(d, '{tables,attachments}', '[]'::jsonb);
  d := jsonb_set(d, '{tables,sales_visits}', '[]'::jsonb);
  d := jsonb_set(d, '{tables,obligations}', '[]'::jsonb);
  d := jsonb_set(d, '{tables,journal_entries}', coalesce((select jsonb_agg(x - 'visit_id') from jsonb_array_elements(d -> 'tables' -> 'journal_entries') x), '[]'::jsonb));
  d := jsonb_set(d, '{tables,cheques}', coalesce((select jsonb_agg(x - 'visit_id') from jsonb_array_elements(d -> 'tables' -> 'cheques') x), '[]'::jsonb));
  insert into public.demo_template (id, company_name, data, updated_at, updated_by) values (1, nm, d, now(), auth.uid())
  on conflict (id) do update set company_name = excluded.company_name, data = excluded.data, updated_at = now(), updated_by = auth.uid();
end $$;

create or replace function public.super_demo_template_info() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_super() then raise exception 'هالعملية لمدير المنصة بس'; end if;
  return (select jsonb_build_object('company_name', company_name, 'updated_at', updated_at, 'company_id', data ->> 'company_id') from public.demo_template where id = 1);
end $$;

-- التسجيل الذاتي (من شاشة الدخول بدون حساب). حدود عشان ما ينضرب بالتسجيل المتكرر
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
  ip := nullif(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1), '');
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

-- بعد أول دخول: نسخة من شركة القالب بأرقام (معرّفات) جديدة
create or replace function public.trial_setup() returns uuid
language plpgsql security definer set search_path = public as $$
declare t public.tenants; d jsonb; txt text; ids text[]; re text := '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
  cid uuid; tb text;
begin
  select * into t from public.tenants where id = public.my_tenant() for update;
  if t.id is null or not t.is_trial then raise exception 'هالعملية للتجربة المجانية بس'; end if;
  if not public.is_admin() then raise exception 'بس مدير الحساب'; end if;
  if exists (select 1 from public.companies where tenant_id = t.id) then
    return (select id from public.companies where tenant_id = t.id order by created_at limit 1);
  end if;
  select data into d from public.demo_template where id = 1;
  if d is null then raise exception 'التجربة المجانية مش متاحة هسا'; end if;
  -- كل معرّف سطر بالنسخة بياخذ معرّف جديد، ومعرّفات المستخدمين بتصير المستخدم الحالي
  for tb in select jsonb_object_keys(d -> 'tables') loop
    ids := ids || coalesce((select array_agg(x ->> 'id') from jsonb_array_elements(d -> 'tables' -> tb) x where x ? 'id' and (x ->> 'id') ~ ('^' || re || '$')), '{}');
  end loop;
  create temp table if not exists _trial_map (old text primary key, new text) on commit drop;
  truncate _trial_map;
  insert into _trial_map select distinct u, gen_random_uuid()::text from unnest(ids) u on conflict do nothing;
  insert into _trial_map select p.id::text, auth.uid()::text from public.profiles p
   where p.id::text in (select m[1] from regexp_matches(d::text, '(' || re || ')', 'g') m) on conflict do nothing;
  txt := d::text;
  with parts as (select p, n from regexp_split_to_table(txt, re) with ordinality s(p, n)),
       ms as (select m[1] as u, n from regexp_matches(txt, '(' || re || ')', 'g') with ordinality s(m, n))
  select string_agg(parts.p || coalesce(mp.new, ms.u, ''), '' order by parts.n) into txt
    from parts left join ms on ms.n = parts.n left join _trial_map mp on mp.old = ms.u;
  d := txt::jsonb;
  cid := (d ->> 'company_id')::uuid;
  perform set_config('sumou.trial', public.internal_token(), true);
  perform public.restore_company(d);
  perform set_config('sumou.trial', '', true);
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.companies set name = t.name where id = cid;
  perform set_config('sumou.internal', '', true);
  insert into public.user_companies (user_id, company_id) values (auth.uid(), cid) on conflict do nothing;
  return cid;
end $$;

-- حد الحركات للتجربة: القيود اليدوية (قيد، قبض، صرف، افتتاحي، والعكسية منهم) والفواتير وسندات المخزون والطلبات بعد تاريخ التسجيل
-- (قيود الترحيل التلقائية للفواتير والمخزون والشيكات ما بتنحسب لأنها جزء من مستندها)
create or replace function public.tenant_docs_used(p_tenant uuid) returns bigint
language sql stable security definer set search_path = public as $$
  with t as (select id, created_at from public.tenants where id = p_tenant), cs as (select c.id from public.companies c, t where c.tenant_id = t.id)
  select (select count(*) from public.journal_entries x, t where x.company_id in (select id from cs) and x.created_at >= t.created_at and x.entry_type in ('journal','receipt','payment','opening'))
       + (select count(*) from public.invoices x, t where x.company_id in (select id from cs) and x.created_at >= t.created_at)
       + (select count(*) from public.stock_docs x, t where x.company_id in (select id from cs) and x.created_at >= t.created_at)
       + (select count(*) from public.orders x, t where x.company_id in (select id from cs) and x.created_at >= t.created_at);
$$;
revoke execute on function public.tenant_docs_used(uuid) from public, anon, authenticated;

create or replace function public.ab_tenant_doc_limit() returns trigger
language plpgsql security definer set search_path = public as $$
declare t public.tenants;
begin
  if coalesce(current_setting('sumou.trial', true), '') = public.internal_token() then return new; end if;   -- تجهيز التجربة
  if tg_table_name = 'journal_entries' then
    if (to_jsonb(new) ->> 'entry_type') not in ('journal','receipt','payment','opening') then return new; end if;
  end if;
  select te.* into t from public.tenants te join public.companies c on c.tenant_id = te.id where c.id = new.company_id;
  if t.max_docs is null then return new; end if;
  perform pg_advisory_xact_lock(hashtext('tdocs:' || t.id));
  if public.tenant_docs_used(t.id) >= t.max_docs then
    raise exception 'وصلت حد الحركات بالتجربة المجانية (%). تواصل معنا للاشتراك', t.max_docs;
  end if;
  return new;
end $$;

-- التجربة ما بتسترجع نسخ (عشان حد الحركات وحجم القاعدة) إلا تجهيزها الأول
create or replace function public.ab_trial_restore_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() and coalesce(current_setting('sumou.trial', true), '') <> public.internal_token()
     and exists (select 1 from public.tenants where id = public.my_tenant() and is_trial) then
    raise exception 'الاسترجاع مش متاح بالتجربة المجانية';
  end if;
  return new;
end $$;
drop trigger if exists ab_trial_restore_guard on public.companies;
create trigger ab_trial_restore_guard before insert on public.companies for each row execute function public.ab_trial_restore_guard();

do $$
declare tb text;
begin
  foreach tb in array array['journal_entries', 'invoices', 'stock_docs', 'orders'] loop
    execute format('drop trigger if exists ab_tenant_doc_limit on public.%I', tb);
    execute format('create trigger ab_tenant_doc_limit before insert on public.%I for each row execute function public.ab_tenant_doc_limit()', tb);
  end loop;
end $$;

-- حالة التجربة للواجهة
create or replace function public.trial_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when t.is_trial then jsonb_build_object(
    'is_trial', true, 'code', t.code, 'expires_at', t.expires_at, 'days_left', t.expires_at - public.local_today(),
    'max_docs', t.max_docs,
    'docs_used', public.tenant_docs_used(t.id),
    'has_company', exists (select 1 from public.companies c where c.tenant_id = t.id))
  else jsonb_build_object('is_trial', false) end
  from public.tenants t where t.id = public.my_tenant();
$$;

-- لمدير المنصة: معلومات التجارب، وحذف تجربة خلصت
create or replace function public.super_tenant_extras()
returns table (id uuid, is_trial boolean, max_docs int, docs_used bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_super() then raise exception 'هالشاشة لمدير المنصة بس'; end if;
  return query select t.id, t.is_trial, t.max_docs, public.tenant_docs_used(t.id)
    from public.tenants t;
end $$;

create or replace function public.super_delete_trial(p_tenant uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
declare t public.tenants; cid uuid; r record;
begin
  if not public.is_super() then raise exception 'هالعملية لمدير المنصة بس'; end if;
  select * into t from public.tenants where id = p_tenant for update;
  if t.id is null or not t.is_trial or t.is_default then raise exception 'بس حسابات التجربة بتنحذف من هون'; end if;
  if exists (select 1 from public.tenant_payments where tenant_id = t.id) then raise exception 'هالمشترك إله دفعات، ما بينحذف'; end if;
  -- حذف كامل بدون triggers (بيانات تجربة): كل جدول لحاله بالترتيب العكسي، وبعدين أي جدول فيه company_id
  begin
    perform set_config('session_replication_role', 'replica', true);
  exception when others then raise exception 'الحذف الكامل مش متاح على السيرفر';
  end;
  for cid in select id from public.companies where tenant_id = t.id loop
    for r in select * from public.backup_tables() where tbl <> 'companies' order by ord desc loop
      execute format('delete from public.%I where %s', r.tbl, r.cond) using cid;
    end loop;
    for r in select c.table_name from information_schema.columns c join information_schema.tables x on x.table_schema = c.table_schema and x.table_name = c.table_name
              where c.table_schema = 'public' and c.column_name = 'company_id' and x.table_type = 'BASE TABLE' loop
      execute format('delete from public.%I where company_id = $1', r.table_name) using cid;
    end loop;
    delete from public.companies where id = cid;
  end loop;
  perform set_config('session_replication_role', 'origin', true);
  delete from public.user_companies where user_id in (select id from public.profiles where tenant_id = t.id);
  delete from public.user_groups where tenant_id = t.id;
  delete from public.activity_log where tenant_id = t.id;
  delete from auth.identities where user_id in (select id from public.profiles where tenant_id = t.id);
  delete from auth.users where id in (select id from public.profiles where tenant_id = t.id);
  delete from public.profiles where tenant_id = t.id;
  delete from public.tenant_payments where tenant_id = p_tenant;
  delete from public.tenants where id = p_tenant;
  insert into public.activity_log (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'حذف', 'tenants', p_tenant, jsonb_build_object('trial', true, 'code', t.code, 'name', t.name));
end $$;

-- الدفعة بتحوّل التجربة لاشتراك عادي (بدون حد حركات ولا علامة تجربة)
create or replace function public.ab_trial_convert_on_payment() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.tenants set is_trial = false, max_docs = null, plan = case when plan = 'تجربة مجانية' then null else plan end, updated_at = now()
   where id = new.tenant_id and is_trial;
  return new;
end $$;
drop trigger if exists ab_trial_convert_on_payment on public.tenant_payments;
create trigger ab_trial_convert_on_payment after insert on public.tenant_payments for each row execute function public.ab_trial_convert_on_payment();

revoke execute on function public.super_set_demo_template(uuid), public.super_demo_template_info(), public.trial_setup(), public.trial_status(),
  public.super_tenant_extras(), public.super_delete_trial(uuid) from public, anon;
grant execute on function public.super_set_demo_template(uuid), public.super_demo_template_info(), public.trial_setup(), public.trial_status(),
  public.super_tenant_extras(), public.super_delete_trial(uuid) to authenticated;
revoke execute on function public.trial_signup(jsonb) from public;
grant execute on function public.trial_signup(jsonb) to anon, authenticated;
