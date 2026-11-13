-- =====================================================================
--  المرحلة 88: لغة الواجهة لكل مستخدم (ar | en) — المستخدم بيغيّرها لحاله
-- =====================================================================
alter table public.profiles add column if not exists lang text;
alter table public.profiles drop constraint if exists profiles_lang_chk;
alter table public.profiles add constraint profiles_lang_chk check (lang is null or lang in ('ar', 'en'));
