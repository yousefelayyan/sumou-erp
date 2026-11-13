-- =====================================================================
--  السمو ERP — المرحلة 31: لون الواجهة لكل مستخدم
--  profiles.theme (المستخدم بيغيّره لحاله)، والمدير بيشغّل/بيطفي الخاصية
--  من الصلاحيات (شاشة theme). أول مرة بس: كل المجموعات بتاخذها مفعّلة.
-- =====================================================================
do $$
declare prev text := current_setting('sumou.internal', true);
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'theme') then
    alter table public.profiles add column theme text;
    perform set_config('sumou.internal', public.internal_token(), true);
    update public.user_groups set permissions = coalesce(permissions, '{}'::jsonb) || '{"theme":{"view":true}}'::jsonb
     where not (coalesce(permissions, '{}'::jsonb) ? 'theme');
    perform set_config('sumou.internal', coalesce(prev, ''), true);
  end if;
end $$;
alter table public.profiles drop constraint if exists profiles_theme_chk;
alter table public.profiles add constraint profiles_theme_chk check (theme is null or theme ~ '^[a-z]{2,20}$');
