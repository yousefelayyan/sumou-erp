-- =====================================================================
--  المرحلة 96: مراقبة تصوير الشاشة
--  screen_event(company, kind, screen): بتسجّل المحاولة (screen_events + activity_log entity = 'screen')
--  وبترجع عدد محاولات اليوم (توقيت عمّان). بعد warn (10) تحذير للمستخدم، وبعد block (25)
--  بيتوقّف حسابه (profiles.is_active = false) لحد ما المدير يرجّع يفعّله. المدير ومدير المنصة ما بيتوقّفوا.
--  الإعدادات tenants.settings.screen_guard {enabled, warn, block} — set_screen_guard (مدير المشترك).
--  الكشف من المتصفح «أفضل محاولة»: زر برنت سكرين، اختصار أداة القص، الطباعة، نسخ كبير، خروج النافذة مع اختصار.
-- =====================================================================
create table if not exists public.screen_events (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid,
  company_id uuid references public.companies(id) on delete cascade,
  user_id    uuid not null default auth.uid(),
  kind       text not null check (kind in ('printscreen','snip','print','copy','record','devtools','other')),
  screen     text check (length(screen) <= 120),
  created_at timestamptz not null default now()
);
create index if not exists screen_events_user_day on public.screen_events (user_id, created_at);
create index if not exists screen_events_tenant on public.screen_events (tenant_id, created_at);
-- حذف المشترك (التجربة) بيمسح محاولاته
delete from public.screen_events e where e.tenant_id is not null and not exists (select 1 from public.tenants t where t.id = e.tenant_id);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'screen_events_tenant_fk') then
    alter table public.screen_events add constraint screen_events_tenant_fk foreign key (tenant_id) references public.tenants(id) on delete cascade;
  end if;
end $$;
alter table public.screen_events enable row level security;
revoke insert, update, delete on public.screen_events from authenticated, anon;
drop policy if exists screen_events_sel on public.screen_events;
create policy screen_events_sel on public.screen_events for select to authenticated
  using (user_id = auth.uid() or (public.is_admin() and tenant_id = public.my_tenant()) or public.is_super());

create or replace function public.screen_guard_cfg(p_tenant uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('enabled', coalesce((s ->> 'enabled')::boolean, true),
                            'warn', greatest(1, coalesce((s ->> 'warn')::int, 10)),
                            'block', greatest(2, coalesce((s ->> 'block')::int, 25)))
    from (select coalesce((select settings -> 'screen_guard' from public.tenants where id = p_tenant), '{}'::jsonb) s) x
$$;
revoke execute on function public.screen_guard_cfg(uuid) from public, anon, authenticated;

create or replace function public.screen_guard() returns jsonb
language sql stable security definer set search_path = public as $$
  select public.screen_guard_cfg(public.my_tenant())
$$;
revoke execute on function public.screen_guard() from public, anon;
grant execute on function public.screen_guard() to authenticated;

create or replace function public.set_screen_guard(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare w int := coalesce((p ->> 'warn')::int, 10); b int := coalesce((p ->> 'block')::int, 25);
begin
  if not public.is_admin() then raise exception 'بس مدير المشترك'; end if;
  if w < 1 or w > 500 or b <= w or b > 1000 then raise exception 'حد التحذير لازم أقل من حد الإيقاف (1 لـ 1000)'; end if;
  update public.tenants set settings = coalesce(settings, '{}'::jsonb) || jsonb_build_object('screen_guard',
    jsonb_build_object('enabled', coalesce((p ->> 'enabled')::boolean, true), 'warn', w, 'block', b))
   where id = public.my_tenant();
end $$;
revoke execute on function public.set_screen_guard(jsonb) from public, anon;
grant execute on function public.set_screen_guard(jsonb) to authenticated;

create or replace function public.screen_event(p_company uuid, p_kind text, p_screen text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.profiles; cfg jsonb; n int; d0 timestamptz; blocked boolean := false; prev text := current_setting('sumou.internal', true);
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or not me.is_active or not public.pwd_ok() then return jsonb_build_object('count', 0); end if;
  if p_company is not null and not public.has_company(p_company) then p_company := null; end if;
  if p_kind not in ('printscreen','snip','print','copy','record','devtools','other') then p_kind := 'other'; end if;
  cfg := public.screen_guard_cfg(me.tenant_id);
  if not (cfg ->> 'enabled')::boolean then return jsonb_build_object('count', 0, 'enabled', false); end if;
  d0 := (date_trunc('day', now() at time zone 'Asia/Amman')) at time zone 'Asia/Amman';
  perform pg_advisory_xact_lock(hashtext('screen:' || me.id::text));
  -- نفس المحاولة مرتين خلال 3 ثواني بتنحسب مرة
  if not exists (select 1 from public.screen_events where user_id = me.id and created_at > now() - interval '3 seconds') then
    insert into public.screen_events (tenant_id, company_id, user_id, kind, screen) values (me.tenant_id, p_company, me.id, p_kind, left(p_screen, 120));
    insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
    values (me.id, p_company, 'تصوير شاشة', 'screen', null, jsonb_build_object('kind', p_kind, 'screen', left(p_screen, 120)));
  end if;
  -- بعد إعادة التفعيل العدّ بيبلّش من جديد (من آخر إيقاف)
  d0 := greatest(d0, coalesce((select max(l.created_at) from public.activity_log l
                               where l.user_id = me.id and l.entity = 'screen' and l.action = 'إيقاف بسبب تصوير الشاشة'), d0));
  -- اللي بينحسب للتحذير والإيقاف: برنت سكرين، اختصار القص، الطباعة، التسجيل. النسخ والتخمين بينسجّلوا بس
  select count(*) into n from public.screen_events where user_id = me.id and created_at > d0
     and kind in ('printscreen','snip','print','record');
  if n >= (cfg ->> 'block')::int and not me.is_admin and not me.is_super then
    perform set_config('sumou.internal', public.internal_token(), true);
    update public.profiles set is_active = false where id = me.id;
    perform set_config('sumou.internal', coalesce(prev, ''), true);
    insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
    values (me.id, p_company, 'إيقاف بسبب تصوير الشاشة', 'screen', me.id::text, jsonb_build_object('count', n));
    blocked := true;
  end if;
  return jsonb_build_object('count', n, 'warn', n >= (cfg ->> 'warn')::int, 'blocked', blocked,
                            'warn_at', (cfg ->> 'warn')::int, 'block_at', (cfg ->> 'block')::int);
end $$;
revoke execute on function public.screen_event(uuid, text, text) from public, anon;
grant execute on function public.screen_event(uuid, text, text) to authenticated;

-- تنبيهات المدير: محاولات اليوم (أو آخر أيام) لكل مستخدم بالمشترك
create or replace function public.screen_alerts(p_days int default 1) returns table (user_id uuid, name text, today int, total int, last_at timestamptz, last_screen text, blocked boolean)
language sql stable security definer set search_path = public as $$
  select e.user_id, coalesce(p.full_name, p.username), 
         count(*) filter (where e.created_at >= (date_trunc('day', now() at time zone 'Asia/Amman')) at time zone 'Asia/Amman')::int,
         count(*)::int, max(e.created_at), (array_agg(e.screen order by e.created_at desc))[1], not p.is_active
    from public.screen_events e join public.profiles p on p.id = e.user_id
   where public.is_admin() and e.tenant_id = public.my_tenant()
     and e.created_at >= now() - make_interval(days => greatest(1, least(coalesce(p_days, 1), 90)))
   group by e.user_id, p.full_name, p.username, p.is_active
   order by 3 desc, 4 desc
$$;
revoke execute on function public.screen_alerts(int) from public, anon;
grant execute on function public.screen_alerts(int) to authenticated;
