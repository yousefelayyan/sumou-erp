-- =====================================================================
--  السمو ERP — المرحلة 11: إدارة المستخدمين من جوّا البرنامج
--  المدير بيعمل مستخدم باسم مستخدم + كلمة سر، وبيحدد الشاشات المسموحة
-- =====================================================================
create extension if not exists pgcrypto with schema extensions;

alter table public.profiles add column if not exists username text;
alter table public.profiles add column if not exists permissions jsonb not null default '{}'::jsonb;  -- {"sales_invoices": true, ...}
create unique index if not exists profiles_username_uq on public.profiles (lower(username)) where username is not null;

-- الموظف ما بيقدر يغيّر صلاحياته أو اسم المستخدم
create or replace function public.protect_profile_fields() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    new.is_admin    := old.is_admin;
    new.is_active   := old.is_active;
    new.email       := old.email;
    new.username    := old.username;
    new.permissions := old.permissions;
  end if;
  return new;
end $$;

-- الصلاحية: مدير، أو الشاشة مأشّرة للمستخدم (كل العمليات)، أو من مجموعته بالشركة
create or replace function public.can(cid uuid, screen text, act text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or (
    public.is_active_user() and exists (
      select 1 from public.user_companies uc
      left join public.user_groups g on g.id = uc.group_id
      join public.profiles p on p.id = uc.user_id
      where uc.user_id = auth.uid() and uc.company_id = cid
        and (coalesce((p.permissions ->> screen)::boolean, false)
             or coalesce((g.permissions -> screen ->> act)::boolean, false))
    )
  );
$$;

create or replace function public.username_email(p_username text) returns text
language sql immutable as $$ select lower(trim(p_username)) || '@sumou.local' $$;

-- إنشاء مستخدم (للمدير بس)
create or replace function public.admin_create_user(p_username text, p_full_name text, p_password text,
  p_permissions jsonb default '{}'::jsonb, p_companies uuid[] default '{}', p_is_admin boolean default false)
returns uuid language plpgsql security definer set search_path = public, extensions, auth as $$
declare uid uuid := gen_random_uuid(); em text; c uuid;
begin
  if not public.is_admin() then raise exception 'بس مدير النظام بيقدر يضيف مستخدمين'; end if;
  p_username := lower(trim(p_username));
  if p_username !~ '^[a-z0-9._-]{2,30}$' then raise exception 'اسم المستخدم لازم يكون أحرف إنجليزي أو أرقام (بدون فراغات)'; end if;
  if coalesce(length(p_password), 0) < 4 then raise exception 'كلمة السر لازم تكون 4 أحرف على الأقل'; end if;
  em := public.username_email(p_username);
  if exists (select 1 from auth.users where lower(email) = em) or exists (select 1 from public.profiles where lower(username) = p_username) then
    raise exception 'اسم المستخدم «%» موجود من قبل', p_username;
  end if;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em,
    extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', coalesce(nullif(trim(p_full_name), ''), p_username)),
    now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text, jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true), 'email', now(), now(), now());
  -- الملف الشخصي بينعمل من الـ trigger
  update public.profiles set username = p_username, full_name = coalesce(nullif(trim(p_full_name), ''), p_username),
         is_active = true, is_admin = coalesce(p_is_admin, false), permissions = coalesce(p_permissions, '{}'::jsonb)
   where id = uid;
  foreach c in array coalesce(p_companies, '{}') loop
    insert into public.user_companies (user_id, company_id) values (uid, c) on conflict do nothing;
  end loop;
  insert into public.activity_log (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'إضافة', 'users', uid, jsonb_build_object('username', p_username));
  return uid;
end $$;

-- تعديل مستخدم: الاسم، اسم المستخدم، كلمة السر (فاضية = بدون تغيير)، الصلاحيات، الشركات
create or replace function public.admin_update_user(p_id uuid, p_username text, p_full_name text, p_password text,
  p_permissions jsonb, p_companies uuid[], p_is_admin boolean, p_is_active boolean)
returns void language plpgsql security definer set search_path = public, extensions, auth as $$
declare em text; c uuid; self boolean := (p_id = auth.uid());
begin
  if not public.is_admin() then raise exception 'بس مدير النظام بيقدر يعدّل المستخدمين'; end if;
  if not exists (select 1 from public.profiles where id = p_id) then raise exception 'المستخدم مش موجود'; end if;
  p_username := nullif(lower(trim(coalesce(p_username, ''))), '');
  if p_username is not null then
    if p_username !~ '^[a-z0-9._-]{2,30}$' then raise exception 'اسم المستخدم لازم يكون أحرف إنجليزي أو أرقام (بدون فراغات)'; end if;
    if exists (select 1 from public.profiles where lower(username) = p_username and id <> p_id) then raise exception 'اسم المستخدم «%» موجود من قبل', p_username; end if;
    -- المستخدمين اللي انعملوا من البرنامج بيتغيّر إيميلهم الداخلي مع الاسم
    if (select email from auth.users where id = p_id) like '%@sumou.local' then
      em := public.username_email(p_username);
      if exists (select 1 from auth.users where lower(email) = em and id <> p_id) then raise exception 'اسم المستخدم «%» موجود من قبل', p_username; end if;
      update auth.users set email = em, updated_at = now() where id = p_id;
      update auth.identities set identity_data = identity_data || jsonb_build_object('email', em) where user_id = p_id and provider = 'email';
      update public.profiles set email = em where id = p_id;
    end if;
  end if;
  if coalesce(p_password, '') <> '' then
    if length(p_password) < 4 then raise exception 'كلمة السر لازم تكون 4 أحرف على الأقل'; end if;
    update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now() where id = p_id;
  end if;
  update public.profiles set username = p_username, full_name = coalesce(nullif(trim(p_full_name), ''), full_name),
         permissions = coalesce(p_permissions, '{}'::jsonb),
         is_admin = case when self then is_admin else coalesce(p_is_admin, is_admin) end,
         is_active = case when self then is_active else coalesce(p_is_active, is_active) end
   where id = p_id;
  -- الشركات: نحافظ على مجموعة الشركة الموجودة إذا ضلت مأشّرة
  delete from public.user_companies where user_id = p_id and not (company_id = any (coalesce(p_companies, '{}')));
  foreach c in array coalesce(p_companies, '{}') loop
    insert into public.user_companies (user_id, company_id) values (p_id, c) on conflict do nothing;
  end loop;
  insert into public.activity_log (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'تعديل', 'users', p_id, jsonb_build_object('username', p_username, 'password_changed', coalesce(p_password, '') <> ''));
end $$;

-- حذف مستخدم نهائياً
create or replace function public.admin_delete_user(p_id uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'بس مدير النظام بيقدر يحذف المستخدمين'; end if;
  if p_id = auth.uid() then raise exception 'ما بتقدر تحذف حالك'; end if;
  insert into public.activity_log (user_id, action, entity, entity_id, details)
  select auth.uid(), 'حذف', 'users', p_id, jsonb_build_object('username', username, 'email', email) from public.profiles where id = p_id;
  delete from auth.users where id = p_id;
  delete from public.profiles where id = p_id;
end $$;

revoke execute on function public.admin_create_user(text, text, text, jsonb, uuid[], boolean) from public, anon;
revoke execute on function public.admin_update_user(uuid, text, text, text, jsonb, uuid[], boolean, boolean) from public, anon;
revoke execute on function public.admin_delete_user(uuid) from public, anon;
grant execute on function public.admin_create_user(text, text, text, jsonb, uuid[], boolean) to authenticated;
grant execute on function public.admin_update_user(uuid, text, text, text, jsonb, uuid[], boolean, boolean) to authenticated;
grant execute on function public.admin_delete_user(uuid) to authenticated;
