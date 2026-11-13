-- =====================================================================
--  المرحلة 93: موقع العميل الجغرافي والتحقق من مكان الزيارة
--  parties.geo_lat/geo_lng/geo_radius (نصف القطر بالمتر؛ الفاضي = إعداد الشركة)
--  company_settings.rep_geo = {mode none|warn|block, radius (افتراضي 300م), learn (أول زيارة بتحفظ موقع العميل إذا فاضي)}
--  visit_start انعادت تعريفها: بتحسب بُعد المندوب عن العميل (distance_m) وبتعلّم geo_ok،
--  وبوضع block بترفض الزيارة إذا بعيد أو بدون موقع (المشرف rep_visits edit مستثنى).
-- =====================================================================
alter table public.parties add column if not exists geo_lat numeric(10,6);
alter table public.parties add column if not exists geo_lng numeric(10,6);
alter table public.parties add column if not exists geo_radius int;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'parties_geo_chk') then
    alter table public.parties add constraint parties_geo_chk check (
      (geo_lat is null) = (geo_lng is null) and (geo_lat is null or (geo_lat between -90 and 90 and geo_lng between -180 and 180))
      and (geo_radius is null or geo_radius between 10 and 50000));
  end if;
end $$;
alter table public.company_settings add column if not exists rep_geo jsonb not null default '{}'::jsonb;
alter table public.sales_visits add column if not exists distance_m int;
alter table public.sales_visits add column if not exists geo_ok boolean;

-- المسافة: geo_dist_m من المرحلة 47

create or replace function public.visit_start(p_company uuid, p_party uuid, p_lat numeric default null, p_lng numeric default null, p_purpose text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare vid uuid; pa public.parties; cfg jsonb; mode text; rad int; d int; ok boolean; sup boolean; prev text := current_setting('sumou.internal', true);
begin
  if not public.can(p_company, 'rep_visits', 'add') then raise exception 'ما عندك صلاحية تسجيل زيارات'; end if;
  select * into pa from public.parties where id = p_party and company_id = p_company and party_type = 'customer' and is_active;
  if pa.id is null then raise exception 'العميل مش موجود'; end if;
  if exists (select 1 from public.sales_visits where company_id = p_company and user_id = auth.uid() and status = 'open') then
    raise exception 'عندك زيارة مفتوحة، أنهيها أول';
  end if;
  if (p_lat is null) <> (p_lng is null) or (p_lat is not null and (p_lat not between -90 and 90 or p_lng not between -180 and 180)) then raise exception 'الموقع مش صحيح'; end if;
  select coalesce(rep_geo, '{}'::jsonb) into cfg from public.company_settings where company_id = p_company;
  mode := coalesce(cfg ->> 'mode', 'none'); rad := coalesce(pa.geo_radius, nullif(cfg ->> 'radius', '')::int, 300);
  sup := public.can(p_company, 'rep_visits', 'edit');
  d := public.geo_dist_m(p_lat, p_lng, pa.geo_lat, pa.geo_lng);
  ok := case when d is null then null else d <= rad end;
  if mode = 'block' and not sup then
    if p_lat is null then raise exception 'لازم تسمح بالموقع عشان تبلّش الزيارة'; end if;
    if ok is false then raise exception 'إنت بعيد عن موقع العميل (% متر، والمسموح % متر)', d, rad; end if;
  end if;
  insert into public.sales_visits (company_id, party_id, rep_id, start_lat, start_lng, purpose, distance_m, geo_ok)
  values (p_company, p_party, pa.sales_rep_id, p_lat, p_lng, nullif(trim(p_purpose), ''), d, ok) returning id into vid;
  -- أول زيارة بتحفظ موقع العميل إذا ما إله موقع (إعداد learn)
  -- بس المشرف بيحفظ موقع العميل (عشان المندوب ما يثبّت موقع غلط ويتحقق منه بعدين)
  if pa.geo_lat is null and p_lat is not null and sup and coalesce((cfg ->> 'learn')::boolean, false) then
    perform set_config('sumou.internal', public.internal_token(), true);
    update public.parties set geo_lat = p_lat, geo_lng = p_lng where id = p_party;
    perform set_config('sumou.internal', coalesce(prev, ''), true);
  end if;
  return vid;
exception when unique_violation then raise exception 'عندك زيارة مفتوحة، أنهيها أول';
end $$;

-- إعداد التحقق من الموقع (من شاشة المندوب للمشرف)
create or replace function public.rep_geo_save(p_company uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (public.can(p_company, 'rep_visits', 'edit') or public.can(p_company, 'companies', 'edit')) or not public.tenant_writable() then raise exception 'ما عندك صلاحية'; end if;
  -- سعر الكيلو بس لمين إله تعديل الشركات؛ غيره بيضل القديم
  if not public.can(p_company, 'companies', 'edit') then
    p := p || jsonb_build_object('km_rate', coalesce((select rep_geo ->> 'km_rate' from public.company_settings where company_id = p_company), '0'));
  end if;
  if coalesce(p ->> 'mode', 'none') not in ('none','warn','block') then raise exception 'نوع التحقق غلط'; end if;
  if coalesce((p ->> 'radius')::int, 300) not between 10 and 50000 then raise exception 'نصف القطر لازم بين 10 و 50000 متر'; end if;
  perform public.ensure_company_settings(p_company);
  update public.company_settings set rep_geo = jsonb_build_object('mode', coalesce(p ->> 'mode', 'none'), 'radius', coalesce((p ->> 'radius')::int, 300),
    'learn', coalesce((p ->> 'learn')::boolean, false), 'km_rate', greatest(0, least(5, coalesce((p ->> 'km_rate')::numeric, 0))))
   where company_id = p_company;
end $$;
revoke execute on function public.rep_geo_save(uuid, jsonb) from public, anon;
grant execute on function public.rep_geo_save(uuid, jsonb) to authenticated;

-- =====================================================================
--  مسافات المندوبين وبدل المواصلات: لكل مستخدم ويوم مجموع المسافة بين مواقع
--  بداية الزيارات بالترتيب (بخط مستقيم) × km_rate من إعداد rep_geo.
--  المشرف (rep_visits edit) بيشوف الكل، والمندوب حاله بس.
-- =====================================================================
create or replace function public.rep_km_report(p_company uuid, p_from date, p_to date)
returns table (user_id uuid, day date, visits bigint, located bigint, km numeric, allowance numeric, taxi numeric, parking numeric, far_visits bigint)
language plpgsql stable security definer set search_path = public as $$
declare sup boolean := public.can(p_company, 'rep_visits', 'edit'); rate numeric;
begin
  if not (sup or public.can(p_company, 'rep_visits', 'view')) then raise exception 'ما عندك صلاحية'; end if;
  if p_to - p_from > 370 then raise exception 'الفترة طويلة (سنة كحد أقصى)'; end if;
  select coalesce(nullif(rep_geo ->> 'km_rate', '')::numeric, 0) into rate from public.company_settings where company_id = p_company;
  return query
  with v as (
    select s.user_id u, (s.started_at at time zone 'Asia/Amman')::date d, s.started_at, s.start_lat, s.start_lng, s.taxi_fee, s.parking_fee, s.geo_ok,
           lag(s.start_lat) over w plat, lag(s.start_lng) over w plng
      from public.sales_visits s
     where s.company_id = p_company and s.status <> 'cancelled'
       and (s.started_at at time zone 'Asia/Amman')::date between p_from and p_to
       and (sup or s.user_id = auth.uid())
     window w as (partition by s.user_id, (s.started_at at time zone 'Asia/Amman')::date order by s.started_at)
  )
  select v.u, v.d, count(*), count(*) filter (where v.start_lat is not null),
         round(coalesce(sum(public.geo_dist_m(v.plat, v.plng, v.start_lat, v.start_lng)), 0) / 1000.0, 2),
         round(coalesce(sum(public.geo_dist_m(v.plat, v.plng, v.start_lat, v.start_lng)), 0) / 1000.0 * coalesce(rate, 0), 3),
         sum(v.taxi_fee), sum(v.parking_fee), count(*) filter (where v.geo_ok is false)
    from v group by v.u, v.d order by v.d, v.u;
end $$;
revoke execute on function public.rep_km_report(uuid, date, date) from public, anon;
grant execute on function public.rep_km_report(uuid, date, date) to authenticated;

-- =====================================================================
--  تطبيق المندوب بدون إنترنت: كل عملية من الطابور إلها client_ref،
--  فإعادة الإرسال ما بتكرّر الدفعة. offline_sync(company, ref, op, payload).
--  op: payment (mobile_payment) | visit_end (بوقت النهاية من الجهاز بين البداية والآن)
-- =====================================================================
create table if not exists public.offline_refs (
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id    uuid not null default auth.uid(),
  ref        text not null check (length(ref) between 8 and 64),
  op         text not null,
  result     jsonb,
  created_at timestamptz not null default now(),
  primary key (company_id, user_id, ref)
);
alter table public.offline_refs enable row level security;
revoke all on public.offline_refs from authenticated, anon;

create or replace function public.offline_sync(p_company uuid, p_ref text, p_op text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb; v public.sales_visits; at timestamptz;
begin
  if not public.can(p_company, 'rep_visits', 'add') and not public.can(p_company, 'receipt_vouchers', 'add') then raise exception 'ما عندك صلاحية'; end if;
  if p_ref is null or length(p_ref) not between 8 and 64 then raise exception 'رقم العملية غلط'; end if;
  perform pg_advisory_xact_lock(hashtext('offline:' || auth.uid()::text || p_ref));
  select result into r from public.offline_refs where company_id = p_company and user_id = auth.uid() and ref = p_ref;
  if found then return coalesce(r, '{}'::jsonb) || jsonb_build_object('duplicate', true); end if;
  if p_op = 'payment' then
    if (p ->> 'company_id')::uuid is distinct from p_company then raise exception 'الشركة غلط'; end if;
    r := public.mobile_payment(p);
  elsif p_op = 'visit_end' then
    select * into v from public.sales_visits where id = (p ->> 'visit_id')::uuid and company_id = p_company;
    if v.id is null then raise exception 'الزيارة مش موجودة'; end if;
    perform public.visit_end(v.id, nullif(p ->> 'lat', '')::numeric, nullif(p ->> 'lng', '')::numeric, p ->> 'notes', p ->> 'outcome',
      coalesce(nullif(p ->> 'taxi', '')::numeric, 0), coalesce(nullif(p ->> 'parking', '')::numeric, 0));
    at := nullif(p ->> 'ended_at', '')::timestamptz;
    if at is not null then
      at := least(greatest(at, v.started_at), now());
      update public.sales_visits set ended_at = at where id = v.id;
    end if;
    r := jsonb_build_object('ok', true);
  else raise exception 'عملية مش معروفة';
  end if;
  insert into public.offline_refs (company_id, user_id, ref, op, result) values (p_company, auth.uid(), p_ref, p_op, r);
  delete from public.offline_refs where user_id = auth.uid() and created_at < now() - interval '120 days';
  return r;
end $$;
revoke execute on function public.offline_sync(uuid, text, text, jsonb) from public, anon;
grant execute on function public.offline_sync(uuid, text, text, jsonb) to authenticated;
