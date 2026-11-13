-- =====================================================================
--  المرحلة 84: سياسة كلمات السر (لكل مشترك)
--  tenants.settings.password_policy = {min_len 4..32, require_digit, require_letter, require_symbol, require_mixed,
--    expiry_days (0 = بدون انتهاء), force_change (المستخدم بيغيّر كلمة السر اللي حطها المدير أول ما يدخل)}
--  password_check(tenant, pwd) بيرفض المخالف؛ admin_create_user / admin_update_user بيفحصوها،
--  و change_my_password(old, new) لتغيير المستخدم لكلمة سره (بيتأكد من القديمة).
--  profiles.password_changed_at / must_change_password (من النظام بس)، و my_password_status() للواجهة.
-- =====================================================================
alter table public.profiles add column if not exists password_changed_at timestamptz default now();
alter table public.profiles add column if not exists must_change_password boolean not null default false;

create or replace function public.ab_profile_pwd_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() or coalesce(current_setting('sumou.pwd', true) = public.internal_token(), false) then return new; end if;
  if tg_op = 'INSERT' then new.password_changed_at := now(); new.must_change_password := false; return new; end if;
  new.password_changed_at := old.password_changed_at; new.must_change_password := old.must_change_password;
  return new;
end $$;
drop trigger if exists ab_profile_pwd_guard on public.profiles;
create trigger ab_profile_pwd_guard before insert or update on public.profiles for each row execute function public.ab_profile_pwd_guard();

create or replace function public.tenant_password_policy(p_tenant uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('min_len', 4, 'require_digit', false, 'require_letter', false, 'require_symbol', false, 'require_mixed', false,
           'expiry_days', 0, 'force_change', false)
      || coalesce((select settings -> 'password_policy' from public.tenants where id = p_tenant), '{}'::jsonb)
$$;

create or replace function public.password_check(p_tenant uuid, p_pwd text) returns void
language plpgsql stable security definer set search_path = public as $$
declare pol jsonb := public.tenant_password_policy(p_tenant); n int := coalesce((pol ->> 'min_len')::int, 4);
begin
  if coalesce(length(p_pwd), 0) < greatest(n, 4) then raise exception 'كلمة السر لازم تكون % أحرف على الأقل', greatest(n, 4); end if;
  if length(p_pwd) > 72 then raise exception 'كلمة السر طويلة كثير'; end if;
  if coalesce((pol ->> 'require_digit')::boolean, false) and p_pwd !~ '[0-9]' then raise exception 'كلمة السر لازم يكون فيها رقم'; end if;
  if coalesce((pol ->> 'require_letter')::boolean, false) and p_pwd !~ '[A-Za-z]' then raise exception 'كلمة السر لازم يكون فيها حرف إنجليزي'; end if;
  if coalesce((pol ->> 'require_mixed')::boolean, false) and (p_pwd !~ '[A-Z]' or p_pwd !~ '[a-z]') then raise exception 'كلمة السر لازم يكون فيها حرف كبير وحرف صغير'; end if;
  if coalesce((pol ->> 'require_symbol')::boolean, false) and p_pwd !~ '[^A-Za-z0-9]' then raise exception 'كلمة السر لازم يكون فيها رمز (مثل @ # !)'; end if;
end $$;

create or replace function public.password_policy() returns jsonb
language sql stable security definer set search_path = public as $$
  select public.tenant_password_policy(public.my_tenant())
$$;

create or replace function public.set_password_policy(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid := public.my_tenant(); pol jsonb;
begin
  if not public.is_admin() or not public.tenant_writable() then raise exception 'سياسة كلمات السر لمدير النظام'; end if;
  pol := jsonb_build_object(
    'min_len', least(greatest(coalesce((p ->> 'min_len')::int, 4), 4), 32),
    'require_digit', coalesce((p ->> 'require_digit')::boolean, false), 'require_letter', coalesce((p ->> 'require_letter')::boolean, false),
    'require_symbol', coalesce((p ->> 'require_symbol')::boolean, false), 'require_mixed', coalesce((p ->> 'require_mixed')::boolean, false),
    'expiry_days', least(greatest(coalesce((p ->> 'expiry_days')::int, 0), 0), 730), 'force_change', coalesce((p ->> 'force_change')::boolean, false));
  update public.tenants set settings = coalesce(settings, '{}'::jsonb) || jsonb_build_object('password_policy', pol) where id = t;
  return pol;
end $$;

create or replace function public.my_password_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('policy', pol, 'changed_at', p.password_changed_at, 'must_change', p.must_change_password,
    'expired', (pol ->> 'expiry_days')::int > 0 and coalesce(p.password_changed_at, '-infinity') < now() - make_interval(days => (pol ->> 'expiry_days')::int),
    'days_left', case when (pol ->> 'expiry_days')::int > 0 then ((pol ->> 'expiry_days')::int - extract(day from now() - coalesce(p.password_changed_at, now())))::int end)
  from public.profiles p, lateral (select public.tenant_password_policy(p.tenant_id) pol) x
  where p.id = auth.uid()
$$;

create or replace function public.change_my_password(p_old text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
declare u uuid := auth.uid(); pr public.profiles; h text;
begin
  select * into pr from public.profiles where id = u;
  if pr.id is null or not pr.is_active then raise exception 'المستخدم مش فعّال'; end if;
  select encrypted_password into h from auth.users where id = u;
  if h is null or extensions.crypt(coalesce(p_old, ''), h) <> h then raise exception 'كلمة السر الحالية مش صحيحة'; end if;
  if p_new = p_old then raise exception 'كلمة السر الجديدة لازم تختلف عن القديمة'; end if;
  perform public.password_check(pr.tenant_id, p_new);
  update auth.users set encrypted_password = extensions.crypt(p_new, extensions.gen_salt('bf')), updated_at = now() where id = u;
  perform set_config('sumou.pwd', public.internal_token(), true);
  update public.profiles set password_changed_at = now(), must_change_password = false where id = u;
  perform set_config('sumou.pwd', '', true);
  insert into public.activity_log (user_id, action, entity, entity_id, details) values (u, 'تعديل', 'users', u, jsonb_build_object('password_changed', true, 'self', true));
end $$;

-- المدير بيجبر مستخدم يغيّر كلمة سره بالدخول الجاي
create or replace function public.admin_force_password_change(p_user uuid, p_on boolean default true) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() or not exists (select 1 from public.profiles where id = p_user and tenant_id = public.my_tenant() and not is_super) then raise exception 'ما عندك صلاحية'; end if;
  perform set_config('sumou.pwd', public.internal_token(), true);
  update public.profiles set must_change_password = coalesce(p_on, true) where id = p_user;
  perform set_config('sumou.pwd', '', true);
end $$;

create or replace function public.admin_create_user(p_username text, p_full_name text, p_password text,
  p_permissions jsonb default '{}'::jsonb, p_companies uuid[] default '{}', p_is_admin boolean default false)
returns uuid language plpgsql security definer set search_path = public, extensions, auth as $$
declare uid uuid; t uuid := public.my_tenant();
begin
  if not public.is_admin() then raise exception 'بس مدير النظام بيقدر يضيف مستخدمين'; end if;
  if not public.tenant_writable() then raise exception 'الاشتراك منتهي. البرنامج للعرض والطباعة بس'; end if;
  perform public.password_check(t, p_password);
  uid := public.create_tenant_user(t, p_username, p_full_name, p_password, p_permissions, p_companies, p_is_admin);
  if coalesce((public.tenant_password_policy(t) ->> 'force_change')::boolean, false) then
    perform set_config('sumou.pwd', public.internal_token(), true);
    update public.profiles set must_change_password = true where id = uid;
    perform set_config('sumou.pwd', '', true);
  end if;
  return uid;
end $$;

create or replace function public.admin_update_user(p_id uuid, p_username text, p_full_name text, p_password text,
  p_permissions jsonb, p_companies uuid[], p_is_admin boolean, p_is_active boolean)
returns void language plpgsql security definer set search_path = public, extensions, auth as $$
declare em text; c uuid; self boolean := (p_id = auth.uid()); t uuid := public.my_tenant(); pr public.profiles;
begin
  if not public.is_admin() then raise exception 'بس مدير النظام بيقدر يعدّل المستخدمين'; end if;
  if not public.tenant_writable() then raise exception 'الاشتراك منتهي. البرنامج للعرض والطباعة بس'; end if;
  select * into pr from public.profiles where id = p_id;
  if pr.id is null or pr.tenant_id is distinct from t then raise exception 'المستخدم مش موجود'; end if;
  if pr.is_super and not self then raise exception 'ما بتقدر تعدّل حساب مدير المنصة'; end if;
  foreach c in array coalesce(p_companies, '{}') loop
    if not exists (select 1 from public.companies where id = c and tenant_id = t) then raise exception 'شركة مش من نفس المشترك'; end if;
  end loop;
  if not self and coalesce(p_is_active, pr.is_active) and not pr.is_active then
    perform public.tenant_user_slot_check(t, p_id);
  end if;
  p_username := nullif(lower(trim(coalesce(p_username, ''))), '');
  if p_username is not null then
    if p_username !~ '^[a-z0-9._-]{2,30}$' then raise exception 'اسم المستخدم لازم يكون أحرف إنجليزي أو أرقام (بدون فراغات)'; end if;
    if exists (select 1 from public.profiles where tenant_id = t and lower(username) = p_username and id <> p_id) then raise exception 'اسم المستخدم «%» موجود من قبل', p_username; end if;
    -- المستخدمين اللي انعملوا من البرنامج بيتغيّر إيميلهم الداخلي مع الاسم
    if (select email from auth.users where id = p_id) like '%sumou.local' then
      em := p_username || '@' || public.tenant_email_domain(t);
      if exists (select 1 from auth.users where lower(email) = em and id <> p_id) then raise exception 'اسم المستخدم «%» موجود من قبل', p_username; end if;
      update auth.users set email = em, updated_at = now() where id = p_id;
      update auth.identities set identity_data = identity_data || jsonb_build_object('email', em) where user_id = p_id and provider = 'email';
      update public.profiles set email = em where id = p_id;
    end if;
  end if;
  if coalesce(p_password, '') <> '' then
    perform public.password_check(t, p_password);
    update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now() where id = p_id;
    perform set_config('sumou.pwd', public.internal_token(), true);
    update public.profiles set password_changed_at = now(),
      must_change_password = (not self) and coalesce((public.tenant_password_policy(t) ->> 'force_change')::boolean, false) where id = p_id;
    perform set_config('sumou.pwd', '', true);
  end if;
  update public.profiles set username = p_username, full_name = coalesce(nullif(trim(p_full_name), ''), full_name),
         permissions = coalesce(p_permissions, '{}'::jsonb),
         is_admin = case when self then is_admin else coalesce(p_is_admin, is_admin) end,
         is_active = case when self then is_active else coalesce(p_is_active, is_active) end
   where id = p_id;
  delete from public.user_companies where user_id = p_id and not (company_id = any (coalesce(p_companies, '{}')));
  foreach c in array coalesce(p_companies, '{}') loop
    insert into public.user_companies (user_id, company_id) values (p_id, c) on conflict do nothing;
  end loop;
  insert into public.activity_log (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'تعديل', 'users', p_id, jsonb_build_object('username', p_username, 'password_changed', coalesce(p_password, '') <> ''));
end $$;

revoke execute on function public.ab_profile_pwd_guard(), public.tenant_password_policy(uuid), public.password_check(uuid, text) from public, anon, authenticated;
revoke execute on function public.password_policy(), public.set_password_policy(jsonb), public.my_password_status(), public.change_my_password(text, text), public.admin_force_password_change(uuid, boolean) from public, anon;
grant execute on function public.password_policy(), public.set_password_policy(jsonb), public.my_password_status(), public.change_my_password(text, text), public.admin_force_password_change(uuid, boolean) to authenticated;
revoke execute on function public.admin_create_user(text, text, text, jsonb, uuid[], boolean), public.admin_update_user(uuid, text, text, text, jsonb, uuid[], boolean, boolean) from public, anon;
grant execute on function public.admin_create_user(text, text, text, jsonb, uuid[], boolean), public.admin_update_user(uuid, text, text, text, jsonb, uuid[], boolean, boolean) to authenticated;
