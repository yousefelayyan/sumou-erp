-- =====================================================================
--  السمو ERP — المرحلة 28: المشتركين (الاشتراكات والتراخيص)
--  كل مكتب/شركة بتشترك = «مشترك» (tenant) بياناته معزولة تماماً.
--  للمشترك: عدد مستخدمين، عدد شركات، الأقسام المفتوحة، وتاريخ انتهاء.
--  بعد الانتهاء: عرض وطباعة بس. الموقوف: ما بيشوف شي.
--  مدير المنصة (is_super) بيدير المشتركين والدفعات من دوال super_*.
--  ملاحظة: هالملف بيعيد تعريف is_active_user/is_admin/has_company/can
--  وسياسات الجداول العامة (profiles, companies, user_groups, user_companies,
--  activity_log). أي ملف بعده بيعدّلهم لازم يحافظ على شرط المشترك.
-- =====================================================================

create table if not exists public.tenants (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique check (code ~ '^[a-z0-9][a-z0-9-]{1,19}$'),
  name          text not null,
  is_default    boolean not null default false,
  status        text not null default 'active' check (status in ('active','suspended')),
  plan          text,
  max_users     int check (max_users is null or max_users > 0),
  max_companies int check (max_companies is null or max_companies > 0),
  modules       text[],                 -- null = كل الأقسام
  expires_at    date,                   -- آخر يوم بالاشتراك؛ null = مفتوح
  contact_name  text,
  phone         text,
  email         text,
  notes         text,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint tenants_reserved_code check (is_default or code <> 'sumou')
);
create unique index if not exists tenants_one_default on public.tenants ((true)) where is_default;

create table if not exists public.tenant_payments (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  paid_at    date not null default current_date,
  amount     numeric(14,3) not null default 0 check (amount >= 0),
  method     text,                      -- كليك، تحويل، نقدي…
  months     int not null default 0 check (months >= 0 and months <= 120),
  reference  text,
  notes      text,
  expires_before date,
  expires_after  date,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists tenant_payments_tenant on public.tenant_payments (tenant_id, paid_at desc);

insert into public.tenants (code, name, is_default)
select 'sumou', 'مؤسسة السمو للمحاسبة والتدريب', true
where not exists (select 1 from public.tenants where is_default);

create or replace function public.default_tenant() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.tenants where is_default limit 1;
$$;

-- الأعمدة الجديدة + تعبئة البيانات الموجودة بالمشترك الافتراضي
alter table public.profiles     add column if not exists tenant_id uuid references public.tenants(id);
alter table public.profiles     add column if not exists is_super  boolean not null default false;
alter table public.profiles     add column if not exists pos_only  boolean not null default false;  -- مستخدم نقطة بيع بس (المرحلة 29)
alter table public.companies    add column if not exists tenant_id uuid references public.tenants(id);
alter table public.user_groups  add column if not exists tenant_id uuid references public.tenants(id);
alter table public.activity_log add column if not exists tenant_id uuid references public.tenants(id) on delete cascade;

do $$
declare dt uuid := public.default_tenant();
begin
  -- التعبئة بدون ما تشتغل triggers الحماية
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.profiles     set tenant_id = dt where tenant_id is null;
  update public.companies    set tenant_id = dt where tenant_id is null;
  update public.user_groups  set tenant_id = dt where tenant_id is null;
  update public.activity_log set tenant_id = dt where tenant_id is null;
  -- مدير المنصة: أول مدير بالمشترك الافتراضي (مرة وحدة بس)
  if not exists (select 1 from public.profiles where is_super) then
    update public.profiles set is_super = true
     where id = (select id from public.profiles where tenant_id = dt and is_admin and is_active order by created_at, id limit 1);
  end if;
  perform set_config('sumou.internal', '', true);
end $$;

-- الرموز وأسماء المستخدمين والمجموعات صارت فريدة جوّا المشترك
alter table public.companies   drop constraint if exists companies_code_key;
create unique index if not exists companies_tenant_code_uq on public.companies (tenant_id, code);
alter table public.user_groups drop constraint if exists user_groups_name_key;
create unique index if not exists user_groups_tenant_name_uq on public.user_groups (tenant_id, name);
drop index if exists public.profiles_username_uq;
create unique index if not exists profiles_tenant_username_uq on public.profiles (tenant_id, lower(username)) where username is not null;
create index if not exists profiles_tenant on public.profiles (tenant_id);
create index if not exists companies_tenant on public.companies (tenant_id);
create index if not exists activity_log_tenant on public.activity_log (tenant_id, created_at desc);

-- =====================================================================
--  الدوال الأساسية
-- =====================================================================
create or replace function public.my_tenant() returns uuid
language sql stable security definer set search_path = public as $$
  select tenant_id from public.profiles where id = auth.uid();
$$;

create or replace function public.is_super() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_super and is_active from public.profiles where id = auth.uid()), false);
$$;

-- المستخدم مفعّل ومشتركه شغّال (مش موقوف)
create or replace function public.is_active_user() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.is_active and t.status = 'active'
                   from public.profiles p join public.tenants t on t.id = p.tenant_id
                   where p.id = auth.uid()), false);
$$;

-- مدير المشترك (مش مدير المنصة)
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.is_admin and p.is_active and t.status = 'active'
                   from public.profiles p join public.tenants t on t.id = p.tenant_id
                   where p.id = auth.uid()), false);
$$;

-- الاشتراك ساري (مش منتهي ولا موقوف) = مسموح الإدخال والتعديل
create or replace function public.tenant_writable() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select t.status = 'active' and (t.expires_at is null or t.expires_at >= current_date)
                   from public.profiles p join public.tenants t on t.id = p.tenant_id
                   where p.id = auth.uid()), false);
$$;

-- كل شاشة تابعة لأي قسم
create or replace function public.screen_module(s text) returns text
language sql immutable as $$
  select case
    when s in ('customers','sales_invoices','sales_orders','pos')   then 'sales'
    when s in ('suppliers','purchase_invoices','purchase_orders')   then 'purchases'
    when s = 'inventory'                                            then 'inventory'
    when s in ('cheques','bank_recon')                              then 'banking'
    when s = 'payroll'                                              then 'payroll'
    when s = 'fixed_assets'                                         then 'assets'
    when s = 'marketing'                                            then 'marketing'
    when s = 'manufacturing'                                        then 'manufacturing'
    when s = 'maintenance'                                          then 'maintenance'
    when s = 'obligations'                                          then 'office'
    else 'core' end;
$$;

create or replace function public.has_company(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    join public.tenants t on t.id = p.tenant_id and t.status = 'active'
    join public.companies c on c.id = cid and c.tenant_id = p.tenant_id
    where p.id = auth.uid() and p.is_active
      and (p.is_admin or (c.is_active and exists (
             select 1 from public.user_companies uc where uc.user_id = p.id and uc.company_id = cid)))
  );
$$;

-- الصلاحية: الشركة من مشترك المستخدم، والقسم مفتوح، والاشتراك ساري (إلا العرض والطباعة)،
-- وبعدين: مدير المشترك أو صلاحية المستخدم/مجموعته
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
          and ((case jsonb_typeof(p.permissions -> screen)
                  when 'boolean' then (p.permissions ->> screen)::boolean
                  when 'object'  then coalesce((p.permissions -> screen ->> act)::boolean, false)
                  else false end)
               or coalesce((g.permissions -> screen ->> act)::boolean, false))))
  );
$$;

create or replace function public.same_tenant_user(u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = u and tenant_id = public.my_tenant());
$$;

create or replace function public.tenant_email_domain(t uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when is_default then 'sumou.local' else code || '.sumou.local' end from public.tenants where id = t;
$$;

revoke execute on function public.default_tenant(), public.tenant_email_domain(uuid) from public, anon, authenticated;
grant execute on function public.my_tenant(), public.is_super(), public.is_active_user(), public.is_admin(),
  public.tenant_writable(), public.screen_module(text), public.has_company(uuid), public.can(uuid, text, text),
  public.same_tenant_user(uuid) to authenticated;
revoke execute on function public.my_tenant(), public.is_super(), public.tenant_writable(), public.same_tenant_user(uuid) from anon;

-- =====================================================================
--  الملفات الشخصية
-- =====================================================================
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare first_user boolean;
begin
  -- الإيميلات الداخلية بتنعمل من البرنامج بس (مش تسجيل ذاتي بالمفتاح العام)
  if lower(coalesce(new.email, '')) like '%sumou.local' and not public.is_internal() then
    raise exception 'التسجيل بهالإيميل مش مسموح';
  end if;
  select not exists (select 1 from public.profiles) into first_user;
  -- أول مستخدم = مدير المنصة ومدير المشترك الافتراضي. غيره (تسجيل ذاتي) بيستنى موافقة
  insert into public.profiles (id, email, full_name, is_admin, is_active, tenant_id, is_super)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
          first_user, first_user, public.default_tenant(), first_user)
  on conflict (id) do nothing;
  return new;
end $$;

create or replace function public.protect_profile_fields() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then return new; end if;
  new.tenant_id := old.tenant_id;
  new.is_super  := old.is_super;
  -- مدير المنصة ما حدا بيوقفه أو بيغيّر صلاحياته غيره
  if old.is_super and old.id is distinct from auth.uid() then
    new.is_admin := old.is_admin; new.is_active := old.is_active; new.email := old.email;
    new.username := old.username; new.permissions := old.permissions; new.pos_only := old.pos_only;
  end if;
  if not public.is_admin() or old.tenant_id is distinct from public.my_tenant() then
    new.is_admin    := old.is_admin;
    new.is_active   := old.is_active;
    new.email       := old.email;
    new.username    := old.username;
    new.permissions := old.permissions;
    new.pos_only    := old.pos_only;
  end if;
  if old.id = auth.uid() then new.pos_only := old.pos_only; end if;   -- ما حدا بيقفل/بيفك نقطة البيع على حاله
  if new.is_active and not old.is_active then perform public.tenant_user_slot_check(old.tenant_id, old.id); end if;
  return new;
end $$;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or (public.is_admin() and tenant_id = public.my_tenant()));
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid() or (public.is_admin() and tenant_id = public.my_tenant() and public.tenant_writable()))
  with check (id = auth.uid() or (public.is_admin() and tenant_id = public.my_tenant() and public.tenant_writable()));
drop policy if exists profiles_delete on public.profiles;
create policy profiles_delete on public.profiles for delete to authenticated
  using (public.is_admin() and id <> auth.uid() and not is_super and tenant_id = public.my_tenant() and public.tenant_writable());

-- =====================================================================
--  الشركات
-- =====================================================================
create or replace function public.company_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare t public.tenants; n int;
begin
  if tg_op = 'UPDATE' then new.tenant_id := coalesce(old.tenant_id, new.tenant_id); return new; end if;
  -- الشركة دايماً بمشترك اللي عملها (حتى بالاسترجاع)
  new.tenant_id := coalesce(public.my_tenant(), new.tenant_id, public.default_tenant());
  select * into t from public.tenants where id = new.tenant_id for update;
  if t.max_companies is not null then
    select count(*) into n from public.companies where tenant_id = new.tenant_id;
    if n >= t.max_companies then
      raise exception 'وصلت الحد المسموح من الشركات باشتراكك (%). تواصل معنا لزيادته', t.max_companies;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists aa_company_tenant on public.companies;
create trigger aa_company_tenant before insert or update on public.companies
  for each row execute function public.company_tenant();

drop policy if exists companies_insert on public.companies;
create policy companies_insert on public.companies for insert to authenticated
  with check (public.is_admin() and public.tenant_writable());
drop policy if exists companies_delete on public.companies;
create policy companies_delete on public.companies for delete to authenticated
  using (public.is_admin() and public.has_company(id) and public.tenant_writable());

-- =====================================================================
--  المجموعات وربط المستخدمين بالشركات
-- =====================================================================
create or replace function public.user_group_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then new.tenant_id := coalesce(old.tenant_id, new.tenant_id); return new; end if;
  if public.is_internal() then new.tenant_id := coalesce(new.tenant_id, public.my_tenant(), public.default_tenant());
  else new.tenant_id := coalesce(public.my_tenant(), new.tenant_id, public.default_tenant()); end if;
  return new;
end $$;
drop trigger if exists aa_user_group_tenant on public.user_groups;
create trigger aa_user_group_tenant before insert or update on public.user_groups
  for each row execute function public.user_group_tenant();

drop policy if exists groups_select on public.user_groups;
create policy groups_select on public.user_groups for select to authenticated
  using (public.is_active_user() and tenant_id = public.my_tenant());
drop policy if exists groups_write on public.user_groups;
drop policy if exists groups_insert on public.user_groups;
create policy groups_insert on public.user_groups for insert to authenticated
  with check (public.is_admin() and public.tenant_writable());
drop policy if exists groups_update on public.user_groups;
create policy groups_update on public.user_groups for update to authenticated
  using (public.is_admin() and tenant_id = public.my_tenant() and public.tenant_writable())
  with check (public.is_admin() and tenant_id = public.my_tenant());
drop policy if exists groups_delete on public.user_groups;
create policy groups_delete on public.user_groups for delete to authenticated
  using (public.is_admin() and tenant_id = public.my_tenant() and public.tenant_writable());

create or replace function public.user_group_ok(g uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select g is null or exists (select 1 from public.user_groups where id = g and tenant_id = public.my_tenant());
$$;
grant execute on function public.user_group_ok(uuid) to authenticated;

drop policy if exists uc_select on public.user_companies;
create policy uc_select on public.user_companies for select to authenticated
  using (user_id = auth.uid() or (public.is_admin() and public.has_company(company_id)));
drop policy if exists uc_write on public.user_companies;
create policy uc_write on public.user_companies for all to authenticated
  using (public.is_admin() and public.has_company(company_id) and public.tenant_writable())
  with check (public.is_admin() and public.has_company(company_id) and public.tenant_writable()
              and public.same_tenant_user(user_id) and public.user_group_ok(group_id));

-- =====================================================================
--  سجل النشاط
-- =====================================================================
create or replace function public.activity_log_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.tenant_id := coalesce((select tenant_id from public.companies where id = new.company_id),
                            case when public.is_super() then new.tenant_id end,
                            public.my_tenant(),
                            (select tenant_id from public.profiles where id = new.user_id),
                            public.default_tenant());
  return new;
end $$;
drop trigger if exists aa_activity_log_tenant on public.activity_log;
create trigger aa_activity_log_tenant before insert on public.activity_log
  for each row execute function public.activity_log_tenant();

drop policy if exists log_select on public.activity_log;
create policy log_select on public.activity_log for select to authenticated
  using (public.is_admin() and tenant_id = public.my_tenant());

create or replace function public.user_names(p_ids uuid[]) returns table (id uuid, name text)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(nullif(p.full_name, ''), nullif(p.username, ''), split_part(p.email, '@', 1))
  from public.profiles p
  where public.is_active_user() and p.id = any(p_ids) and p.tenant_id = public.my_tenant();
$$;
revoke execute on function public.user_names(uuid[]) from public, anon;
grant execute on function public.user_names(uuid[]) to authenticated;

-- =====================================================================
--  المرفقات والنسخ الاحتياطي بالتخزين
-- =====================================================================
-- مسار الملف لازم يبدأ برمز نفس الشركة (عشان سطر ما يأشّر على ملف شركة ثانية)
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'attachments_path_company') then
    alter table public.attachments add constraint attachments_path_company
      check (split_part(path, '/', 1) = company_id::text) not valid;
  end if;
end $$;
drop policy if exists att_insert on public.attachments;
create policy att_insert on public.attachments for insert to authenticated
  with check (public.has_company(company_id) and public.tenant_writable());
drop policy if exists att_delete on public.attachments;
create policy att_delete on public.attachments for delete to authenticated
  using (public.has_company(company_id) and public.tenant_writable() and (created_by = auth.uid() or public.is_admin()));

do $$
begin
  if to_regclass('storage.objects') is not null then
    execute 'drop policy if exists sumou_att_insert on storage.objects';
    execute 'drop policy if exists sumou_att_select on storage.objects';
    execute $p$create policy sumou_att_select on storage.objects for select to authenticated
      using (bucket_id = 'attachments' and exists (select 1 from public.attachments a where a.path = name
             and split_part(name, '/', 1) = a.company_id::text and public.attachment_visible(a.company_id, a.entity)))$p$;
    execute 'drop policy if exists sumou_att_delete on storage.objects';
    execute 'drop policy if exists sumou_bak_all on storage.objects';
    execute $p$create policy sumou_att_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'attachments' and public.has_company(((storage.foldername(name))[1])::uuid) and public.tenant_writable())$p$;
    execute $p$create policy sumou_att_delete on storage.objects for delete to authenticated
      using (bucket_id = 'attachments' and public.has_company(((storage.foldername(name))[1])::uuid) and public.tenant_writable()
             and not exists (select 1 from public.attachments a where a.path = name and not (a.created_by = auth.uid() or public.is_admin())))$p$;
    execute $p$create policy sumou_bak_all on storage.objects for all to authenticated
      using (bucket_id = 'backups' and public.is_admin() and public.has_company(((storage.foldername(name))[1])::uuid))
      with check (bucket_id = 'backups' and public.is_admin() and public.has_company(((storage.foldername(name))[1])::uuid))$p$;
  end if;
end $$;

-- =====================================================================
--  إدارة المستخدمين (جوّا المشترك)
-- =====================================================================
create or replace function public.tenant_user_slot_check(p_tenant uuid, p_exclude uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare mx int; n int;
begin
  select max_users into mx from public.tenants where id = p_tenant for update;
  if mx is null then return; end if;
  select count(*) into n from public.profiles where tenant_id = p_tenant and is_active and id is distinct from p_exclude;
  if n >= mx then raise exception 'وصلت الحد المسموح من المستخدمين باشتراكك (%). وقّف مستخدم أو تواصل معنا لزيادة العدد', mx; end if;
end $$;
revoke execute on function public.tenant_user_slot_check(uuid, uuid) from public, anon, authenticated;

-- الإنشاء الفعلي (داخلي — ما إله صلاحية مباشرة)
create or replace function public.create_tenant_user(p_tenant uuid, p_username text, p_full_name text, p_password text,
  p_permissions jsonb, p_companies uuid[], p_is_admin boolean)
returns uuid language plpgsql security definer set search_path = public, extensions, auth as $$
declare uid uuid := gen_random_uuid(); em text; c uuid; prev text := current_setting('sumou.internal', true);
begin
  p_username := lower(trim(coalesce(p_username, '')));
  if p_username !~ '^[a-z0-9._-]{2,30}$' then raise exception 'اسم المستخدم لازم يكون أحرف إنجليزي أو أرقام (بدون فراغات)'; end if;
  if coalesce(length(p_password), 0) < 4 then raise exception 'كلمة السر لازم تكون 4 أحرف على الأقل'; end if;
  if not exists (select 1 from public.tenants where id = p_tenant) then raise exception 'المشترك مش موجود'; end if;
  perform public.tenant_user_slot_check(p_tenant);
  em := p_username || '@' || public.tenant_email_domain(p_tenant);
  if exists (select 1 from auth.users where lower(email) = em)
     or exists (select 1 from public.profiles where tenant_id = p_tenant and lower(username) = p_username) then
    raise exception 'اسم المستخدم «%» موجود من قبل', p_username;
  end if;
  foreach c in array coalesce(p_companies, '{}') loop
    if not exists (select 1 from public.companies where id = c and tenant_id = p_tenant) then raise exception 'شركة مش من نفس المشترك'; end if;
  end loop;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em,
    extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', coalesce(nullif(trim(p_full_name), ''), p_username)),
    now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text, jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true), 'email', now(), now(), now());
  update public.profiles set username = p_username, full_name = coalesce(nullif(trim(p_full_name), ''), p_username),
         is_active = true, is_admin = coalesce(p_is_admin, false), permissions = coalesce(p_permissions, '{}'::jsonb),
         tenant_id = p_tenant, is_super = false
   where id = uid;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  foreach c in array coalesce(p_companies, '{}') loop
    insert into public.user_companies (user_id, company_id) values (uid, c) on conflict do nothing;
  end loop;
  insert into public.activity_log (user_id, action, entity, entity_id, details, tenant_id)
  values (auth.uid(), 'إضافة', 'users', uid, jsonb_build_object('username', p_username), p_tenant);
  return uid;
end $$;
revoke execute on function public.create_tenant_user(uuid, text, text, text, jsonb, uuid[], boolean) from public, anon, authenticated;

create or replace function public.admin_create_user(p_username text, p_full_name text, p_password text,
  p_permissions jsonb default '{}'::jsonb, p_companies uuid[] default '{}', p_is_admin boolean default false)
returns uuid language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if not public.is_admin() then raise exception 'بس مدير النظام بيقدر يضيف مستخدمين'; end if;
  if not public.tenant_writable() then raise exception 'الاشتراك منتهي. البرنامج للعرض والطباعة بس'; end if;
  return public.create_tenant_user(public.my_tenant(), p_username, p_full_name, p_password, p_permissions, p_companies, p_is_admin);
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
    if length(p_password) < 4 then raise exception 'كلمة السر لازم تكون 4 أحرف على الأقل'; end if;
    update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now() where id = p_id;
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

create or replace function public.admin_delete_user(p_id uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'بس مدير النظام بيقدر يحذف المستخدمين'; end if;
  if not public.tenant_writable() then raise exception 'الاشتراك منتهي. البرنامج للعرض والطباعة بس'; end if;
  if p_id = auth.uid() then raise exception 'ما بتقدر تحذف حالك'; end if;
  if not exists (select 1 from public.profiles where id = p_id and tenant_id = public.my_tenant()) then raise exception 'المستخدم مش موجود'; end if;
  if exists (select 1 from public.profiles where id = p_id and is_super) then raise exception 'ما بينحذف مدير المنصة'; end if;
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

-- =====================================================================
--  اشتراكي (للعرض بالبرنامج: التنبيهات والأقسام)
-- =====================================================================
create or replace function public.my_subscription() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'code', t.code, 'name', t.name, 'plan', t.plan, 'status', t.status, 'is_default', t.is_default,
    'expires_at', t.expires_at,
    'days_left', case when t.expires_at is null then null else t.expires_at - current_date end,
    'writable', t.status = 'active' and (t.expires_at is null or t.expires_at >= current_date),
    'modules', to_jsonb(t.modules),
    'max_users', t.max_users, 'max_companies', t.max_companies,
    'users_used', (select count(*) from public.profiles x where x.tenant_id = t.id and x.is_active),
    'companies_used', (select count(*) from public.companies x where x.tenant_id = t.id),
    'is_super', p.is_super)
  from public.profiles p join public.tenants t on t.id = p.tenant_id
  where p.id = auth.uid() and p.is_active;
$$;
revoke execute on function public.my_subscription() from public, anon;
grant execute on function public.my_subscription() to authenticated;

-- =====================================================================
--  لوحة مدير المنصة
-- =====================================================================
alter table public.tenants enable row level security;
alter table public.tenant_payments enable row level security;
drop policy if exists tenants_select on public.tenants;
create policy tenants_select on public.tenants for select to authenticated
  using (public.is_super() or (id = public.my_tenant() and public.is_admin()));
drop policy if exists tenant_payments_select on public.tenant_payments;
create policy tenant_payments_select on public.tenant_payments for select to authenticated
  using (public.is_super() or (tenant_id = public.my_tenant() and public.is_admin()));
revoke all on public.tenants, public.tenant_payments from anon;
grant select on public.tenants, public.tenant_payments to authenticated;
revoke insert, update, delete on public.tenants, public.tenant_payments from authenticated;

create or replace function public.super_tenants()
returns table (id uuid, code text, name text, is_default boolean, status text, plan text, max_users int, max_companies int,
               modules text[], expires_at date, contact_name text, phone text, email text, notes text, created_at timestamptz,
               users_active bigint, users_total bigint, companies_count bigint, last_login timestamptz, paid_total numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_super() then raise exception 'هالشاشة لمدير المنصة بس'; end if;
  return query
  select t.id, t.code, t.name, t.is_default, t.status, t.plan, t.max_users, t.max_companies, t.modules, t.expires_at,
         t.contact_name, t.phone, t.email, t.notes, t.created_at,
         (select count(*) from public.profiles p where p.tenant_id = t.id and p.is_active),
         (select count(*) from public.profiles p where p.tenant_id = t.id),
         (select count(*) from public.companies c where c.tenant_id = t.id),
         (select max(l.created_at) from public.activity_log l where l.tenant_id = t.id and l.entity = 'auth'),
         (select coalesce(sum(x.amount), 0) from public.tenant_payments x where x.tenant_id = t.id)
  from public.tenants t order by t.is_default desc, t.created_at;
end $$;

create or replace function public.super_save_tenant(p_id uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare tid uuid := p_id; old public.tenants; mods text[]; c text;
begin
  if not public.is_super() then raise exception 'هالعملية لمدير المنصة بس'; end if;
  if nullif(trim(p ->> 'name'), '') is null then raise exception 'اكتب اسم المشترك'; end if;
  if p ? 'modules' and jsonb_typeof(p -> 'modules') = 'array' then
    select coalesce(array_agg(x), '{}') into mods from jsonb_array_elements_text(p -> 'modules') x
     where x in ('sales','purchases','inventory','banking','payroll','assets','marketing','manufacturing','maintenance','office');
  else mods := null; end if;
  if tid is null then
    c := lower(trim(coalesce(p ->> 'code', '')));
    if c !~ '^[a-z0-9][a-z0-9-]{1,19}$' then raise exception 'رمز المشترك لازم يكون أحرف إنجليزي صغيرة أو أرقام (2 لـ 20)'; end if;
    if c = 'sumou' or exists (select 1 from public.tenants where code = c) then raise exception 'رمز المشترك «%» مستخدم', c; end if;
    insert into public.tenants (code, name, status, plan, max_users, max_companies, modules, expires_at, contact_name, phone, email, notes, created_by)
    values (c, trim(p ->> 'name'), coalesce(nullif(p ->> 'status', ''), 'active'), nullif(p ->> 'plan', ''),
            nullif(p ->> 'max_users', '')::int, nullif(p ->> 'max_companies', '')::int, mods,
            nullif(p ->> 'expires_at', '')::date, nullif(p ->> 'contact_name', ''), nullif(p ->> 'phone', ''),
            nullif(p ->> 'email', ''), nullif(p ->> 'notes', ''), auth.uid())
    returning id into tid;
    -- مجموعات جاهزة للمشترك الجديد
    perform set_config('sumou.internal', public.internal_token(), true);
    insert into public.user_groups (name, description, permissions, tenant_id)
    select g.name, g.description, g.permissions, tid from public.user_groups g
     where g.tenant_id = public.default_tenant() and g.name in ('محاسب', 'مدخل بيانات', 'مشاهد', 'كاشير');
    perform set_config('sumou.internal', '', true);
  else
    select * into old from public.tenants where id = tid;
    if old.id is null then raise exception 'المشترك مش موجود'; end if;
    if old.is_default and coalesce(p ->> 'status', old.status) <> 'active' then raise exception 'ما بتقدر توقف مشتركك الأساسي'; end if;
    update public.tenants set name = trim(p ->> 'name'),
      status = coalesce(nullif(p ->> 'status', ''), status), plan = nullif(p ->> 'plan', ''),
      max_users = nullif(p ->> 'max_users', '')::int, max_companies = nullif(p ->> 'max_companies', '')::int,
      modules = case when old.is_default then null else mods end,
      expires_at = case when old.is_default then null else nullif(p ->> 'expires_at', '')::date end,
      contact_name = nullif(p ->> 'contact_name', ''), phone = nullif(p ->> 'phone', ''),
      email = nullif(p ->> 'email', ''), notes = nullif(p ->> 'notes', ''), updated_at = now()
     where id = tid;
  end if;
  insert into public.activity_log (user_id, action, entity, entity_id, details)
  values (auth.uid(), case when p_id is null then 'إضافة' else 'تعديل' end, 'tenants', tid, p - 'password');
  return tid;
end $$;

create or replace function public.super_create_tenant_admin(p_tenant uuid, p_username text, p_full_name text, p_password text)
returns uuid language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if not public.is_super() then raise exception 'هالعملية لمدير المنصة بس'; end if;
  return public.create_tenant_user(p_tenant, p_username, p_full_name, p_password, '{}'::jsonb, '{}', true);
end $$;

create or replace function public.super_tenant_users(p_tenant uuid)
returns table (id uuid, username text, full_name text, is_admin boolean, is_active boolean, last_login timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_super() then raise exception 'هالشاشة لمدير المنصة بس'; end if;
  return query select p.id, p.username, p.full_name, p.is_admin, p.is_active,
    (select max(l.created_at) from public.activity_log l where l.user_id = p.id and l.entity = 'auth')
    from public.profiles p where p.tenant_id = p_tenant order by p.is_admin desc, p.username;
end $$;

-- تغيير كلمة سر مستخدم عند مشترك (لما ينساها مديرهم) أو تفعيل/إيقاف
create or replace function public.super_set_user(p_user uuid, p_password text, p_is_active boolean)
returns void language plpgsql security definer set search_path = public, extensions, auth as $$
declare pr public.profiles; prev text := current_setting('sumou.internal', true);
begin
  if not public.is_super() then raise exception 'هالعملية لمدير المنصة بس'; end if;
  select * into pr from public.profiles where id = p_user;
  if pr.id is null then raise exception 'المستخدم مش موجود'; end if;
  if pr.id = auth.uid() and p_is_active is false then raise exception 'ما بتقدر توقف حالك'; end if;
  if coalesce(p_password, '') <> '' then
    if length(p_password) < 4 then raise exception 'كلمة السر لازم تكون 4 أحرف على الأقل'; end if;
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

-- تسجيل دفعة وتمديد الاشتراك (من آخر يوم أو من اليوم إذا كان منتهي)
create or replace function public.super_add_payment(p_tenant uuid, p_amount numeric, p_months int, p_method text,
  p_paid_at date default current_date, p_reference text default null, p_notes text default null)
returns date language plpgsql security definer set search_path = public as $$
declare t public.tenants; nexp date;
begin
  if not public.is_super() then raise exception 'هالعملية لمدير المنصة بس'; end if;
  select * into t from public.tenants where id = p_tenant for update;
  if t.id is null then raise exception 'المشترك مش موجود'; end if;
  if coalesce(p_months, 0) < 0 or coalesce(p_months, 0) > 120 then raise exception 'عدد الأشهر مش منطقي'; end if;
  if coalesce(p_amount, 0) < 0 then raise exception 'المبلغ لازم يكون موجب'; end if;
  nexp := t.expires_at;
  if coalesce(p_months, 0) > 0 and not t.is_default then
    nexp := (greatest(coalesce(t.expires_at, current_date - 1), current_date - 1) + make_interval(months => p_months))::date;
    update public.tenants set expires_at = nexp, updated_at = now() where id = p_tenant;
  end if;
  insert into public.tenant_payments (tenant_id, paid_at, amount, method, months, reference, notes, expires_before, expires_after, created_by)
  values (p_tenant, coalesce(p_paid_at, current_date), coalesce(p_amount, 0), nullif(trim(p_method), ''), coalesce(p_months, 0),
          nullif(trim(p_reference), ''), nullif(trim(p_notes), ''), t.expires_at, nexp, auth.uid());
  insert into public.activity_log (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'دفعة', 'tenants', p_tenant, jsonb_build_object('amount', p_amount, 'months', p_months, 'expires_at', nexp));
  return nexp;
end $$;

create or replace function public.super_delete_payment(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare x public.tenant_payments;
begin
  if not public.is_super() then raise exception 'هالعملية لمدير المنصة بس'; end if;
  select * into x from public.tenant_payments where id = p_id;
  if x.id is null then return; end if;
  -- إذا آخر دفعة: بيرجع تاريخ الانتهاء لقبلها
  if x.months > 0 and not exists (select 1 from public.tenant_payments where tenant_id = x.tenant_id and created_at > x.created_at)
     and (select expires_at from public.tenants where id = x.tenant_id) is not distinct from x.expires_after then
    update public.tenants set expires_at = x.expires_before, updated_at = now() where id = x.tenant_id;
  end if;
  delete from public.tenant_payments where id = p_id;
  insert into public.activity_log (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'حذف', 'tenants', x.tenant_id, jsonb_build_object('payment', x.amount, 'months', x.months));
end $$;

revoke execute on function public.super_tenants(), public.super_save_tenant(uuid, jsonb),
  public.super_create_tenant_admin(uuid, text, text, text), public.super_tenant_users(uuid),
  public.super_set_user(uuid, text, boolean),
  public.super_add_payment(uuid, numeric, int, text, date, text, text), public.super_delete_payment(uuid) from public, anon;
grant execute on function public.super_tenants(), public.super_save_tenant(uuid, jsonb),
  public.super_create_tenant_admin(uuid, text, text, text), public.super_tenant_users(uuid),
  public.super_set_user(uuid, text, boolean),
  public.super_add_payment(uuid, numeric, int, text, date, text, text), public.super_delete_payment(uuid) to authenticated;
