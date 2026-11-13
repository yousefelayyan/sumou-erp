-- =====================================================================
--  السمو ERP — المرحلة 73: بوابة الرسائل القصيرة (SMS)
--  sms_settings: رابط الإرسال من شركة الرسائل (فيه اسم المستخدم وكلمة السر) — ما إله أي سياسة قراءة،
--  وبيتقرا بس من دوال security definer؛ الواجهة بتشوف نسخة مخفية (sms_config_get).
--  الإرسال من قاعدة البيانات بالـ pg_net (net.http_get) عن طريق sms_send؛ الحالة بتتحدّث من net._http_response (sms_refresh).
--  كلمات الرابط: {phone} (962…)، {msg} (النص مرمّز)، {msg_hex} (UTF-16 hex للبوابات اللي بدها يونيكود)، {sender}.
-- =====================================================================
do $$ begin
  begin create extension if not exists pg_net; exception when others then raise notice 'pg_net مش متوفر هون (عادي بالاختبار المحلي)'; end;
  -- المستخدمين ما إلهم وصول مباشر لـ pg_net (الإرسال بس من sms_send)
  if to_regnamespace('net') is not null then
    begin
      execute 'revoke usage on schema net from anon, authenticated';
      execute 'revoke all on all tables in schema net from anon, authenticated';
      execute 'revoke execute on all functions in schema net from anon, authenticated';
    exception when others then raise notice 'ما قدرت أسحب صلاحيات net: %', sqlerrm; end;
  end if;
end $$;

create table if not exists public.sms_settings (
  company_id   uuid primary key references public.companies(id) on delete cascade,
  enabled      boolean not null default false,
  url_template text check (url_template is null or (length(url_template) <= 2000 and url_template ~* '^https://')),
  sender       text check (sender is null or length(sender) <= 30),
  test_mode    boolean not null default true,
  test_phone   text,
  daily_limit  int not null default 500 check (daily_limit between 1 and 20000),
  allow_intl   boolean not null default false,
  updated_by   uuid,
  updated_at   timestamptz not null default now()
);
alter table public.sms_settings enable row level security;
revoke all on public.sms_settings from anon, authenticated;

alter table public.message_log add column if not exists status text;
alter table public.message_log add column if not exists request_id bigint;
alter table public.message_log add column if not exists error text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'message_log_status_chk') then
    alter table public.message_log add constraint message_log_status_chk check (status is null or status in ('queued','sent','failed','test'));
  end if;
end $$;
alter table public.sms_settings add column if not exists allow_intl boolean not null default false;
create index if not exists message_log_req on public.message_log (request_id) where request_id is not null;

-- حالة الرسالة ورقم الطلب من النظام بس
create or replace function public.ab_message_log_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('sumou.sms', true), '') = public.internal_token() then return new; end if;
  new.request_id := null; new.error := null;
  -- الاسترجاع بيحفظ الحالة النهائية بس (بدون رقم طلب)
  if not (public.is_internal() and new.status in ('sent','failed','test')) then new.status := null; end if;
  return new;
end $$;
drop trigger if exists ab_message_log_guard on public.message_log;
create trigger ab_message_log_guard before insert on public.message_log for each row execute function public.ab_message_log_guard();
revoke execute on function public.ab_message_log_guard() from public, anon, authenticated;

-- ترميز الرابط (UTF-8)
create or replace function public.url_encode(p text) returns text
language plpgsql immutable as $$
declare b bytea := convert_to(coalesce(p, ''), 'UTF8'); r text := ''; i int; c int;
begin
  for i in 0 .. length(b) - 1 loop
    c := get_byte(b, i);
    if (c between 48 and 57) or (c between 65 and 90) or (c between 97 and 122) or c in (45, 46, 95, 126) then r := r || chr(c);
    else r := r || '%' || upper(lpad(to_hex(c), 2, '0')); end if;
  end loop;
  return r;
end $$;
-- UTF-16BE hex (للبوابات اللي بتطلب النص العربي يونيكود)
create or replace function public.ucs2_hex(p text) returns text
language plpgsql immutable as $$
declare r text := ''; ch text; cp int;
begin
  foreach ch in array regexp_split_to_array(coalesce(p, ''), '') loop
    cp := ascii(ch);
    if cp > 65535 then cp := cp - 65536; r := r || upper(lpad(to_hex(55296 + (cp >> 10)), 4, '0')) || upper(lpad(to_hex(56320 + (cp & 1023)), 4, '0'));
    else r := r || upper(lpad(to_hex(cp), 4, '0')); end if;
  end loop;
  return r;
end $$;
create or replace function public.sms_phone(p text) returns text
language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
begin
  if d like '00%' then d := substr(d, 3);
  elsif d like '0%' then d := '962' || substr(d, 2);
  elsif length(d) = 9 and d like '7%' then d := '962' || d; end if;
  return nullif(d, '');
end $$;

-- دومين الرابط (بدون اسم مستخدم/كلمة سر وبدون المنفذ)
create or replace function public.sms_host(u text) returns text
language sql immutable as $$
  select lower(regexp_replace(regexp_replace(substring(u from '^https?://([^/?#]+)'), '^.*@', ''), ':[0-9]*$', ''));
$$;
-- البوابة لازم تكون دومين عام (مش IP ولا عنوان داخلي)
create or replace function public.sms_host_ok(u text) returns boolean
language sql immutable as $$
  select h is not null and h ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' and h !~ '^[0-9.]+$'
     and h !~ '(^|\.)(localhost|local|internal|intranet|lan|home|corp|arpa|test|invalid|example)$' and h !~ '^(metadata|instance-data)'
     and h !~ '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
    from (select public.sms_host(u) h) x;
$$;
create or replace function public.sms_trial(p_company uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.companies c join public.tenants t on t.id = c.tenant_id where c.id = p_company and coalesce(t.is_trial, false));
$$;
revoke execute on function public.sms_trial(uuid) from public, anon, authenticated;

-- الإعداد للواجهة: بدون الرابط (بس الدومين)
create or replace function public.sms_config_get(p_company uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.can(p_company, 'marketing', 'view') then null else
    jsonb_build_object('has_url', s.url_template is not null, 'host', public.sms_host(s.url_template), 'allow_intl', coalesce(s.allow_intl, false), 'trial', public.sms_trial(p_company),
      'enabled', coalesce(s.enabled, false), 'sender', s.sender, 'test_mode', coalesce(s.test_mode, true), 'test_phone', s.test_phone,
      'daily_limit', coalesce(s.daily_limit, 500), 'pg_net', to_regprocedure('net.http_get(text,jsonb,jsonb,integer)') is not null,
      'sent_today', (select count(*) from public.message_log m where m.company_id = p_company and m.channel = 'sms' and m.status in ('queued','sent','test')
                      and m.sent_at >= (public.local_today())::timestamp at time zone 'Asia/Amman'))
  end from (select 1) x left join public.sms_settings s on s.company_id = p_company;
$$;

-- الحفظ: مدير الشركة (companies edit). الرابط الفاضي = بيضل القديم
create or replace function public.sms_config_save(p_company uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare u text := nullif(trim(p ->> 'url_template'), '');
begin
  if not public.can(p_company, 'companies', 'edit') or not public.tenant_writable() then raise exception 'ما عندك صلاحية تعديل إعدادات الشركة'; end if;
  if public.sms_trial(p_company) then raise exception 'بوابة الرسائل مش متاحة بالنسخة التجريبية'; end if;
  if u is not null and u !~* '^https://' then raise exception 'رابط البوابة لازم يبدأ بـ https://'; end if;
  if u is not null and not public.sms_host_ok(u) then raise exception 'دومين البوابة لازم يكون عنوان عام لشركة الرسائل (مش IP ولا عنوان داخلي)'; end if;
  if u is not null and position('{phone}' in u) = 0 then raise exception 'الرابط لازم يكون فيه {phone}'; end if;
  if u is not null and position('{msg' in u) = 0 then raise exception 'الرابط لازم يكون فيه {msg} أو {msg_hex}'; end if;
  insert into public.sms_settings (company_id, enabled, url_template, sender, test_mode, test_phone, daily_limit, allow_intl, updated_by, updated_at)
  values (p_company, coalesce((p ->> 'enabled')::boolean, false), u, nullif(trim(p ->> 'sender'), ''), coalesce((p ->> 'test_mode')::boolean, true),
          nullif(trim(p ->> 'test_phone'), ''), coalesce((p ->> 'daily_limit')::int, 500), coalesce((p ->> 'allow_intl')::boolean, false), auth.uid(), now())
  on conflict (company_id) do update set enabled = excluded.enabled, url_template = coalesce(u, sms_settings.url_template),
    sender = excluded.sender, test_mode = excluded.test_mode, test_phone = excluded.test_phone, daily_limit = excluded.daily_limit, allow_intl = excluded.allow_intl,
    updated_by = auth.uid(), updated_at = now();
  if (p ->> 'clear_url')::boolean then update public.sms_settings set url_template = null, enabled = false where company_id = p_company; end if;
end $$;

-- إرسال رسالة وحدة (بيرجع رقم سطر السجل)
create or replace function public.sms_send(p_company uuid, p_phone text, p_body text, p_party uuid default null, p_kind text default 'other',
                                           p_ref uuid default null, p_campaign text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare s public.sms_settings; ph text; url text; rid bigint; lid uuid; n int; body text := left(coalesce(p_body, ''), 1000); pa public.parties; mk boolean;
begin
  mk := public.can(p_company, 'marketing', 'add');
  if not (mk or public.can(p_company, 'sales_invoices', 'add') or public.can(p_company, 'receipt_vouchers', 'add'))
     or not public.tenant_writable() then raise exception 'ما عندك صلاحية إرسال رسائل'; end if;
  if public.sms_trial(p_company) then raise exception 'بوابة الرسائل مش متاحة بالنسخة التجريبية'; end if;
  if p_party is not null then
    select * into pa from public.parties where id = p_party and company_id = p_company;
    if pa.id is null then raise exception 'الطرف مش من هالشركة'; end if;
  end if;
  if p_kind not in ('invoice','statement','payment','reminder','campaign','other') then p_kind := 'other'; end if;
  -- بدون صلاحية التسويق: بس لطرف وعلى رقمه، وفاتورة/كشف/دفعة
  if not mk then
    if pa.id is null or p_kind not in ('invoice','statement','payment')
       or public.sms_phone(p_phone) not in (coalesce(public.sms_phone(pa.mobile), '-'), coalesce(public.sms_phone(pa.phone), '-')) then
      raise exception 'الإرسال الحر بدها صلاحية التسويق؛ بتقدر تبعت فاتورة أو كشف أو دفعة لرقم الطرف نفسه بس';
    end if;
  end if;
  select * into s from public.sms_settings where company_id = p_company;
  if s.company_id is null or not s.enabled or s.url_template is null then raise exception 'بوابة الرسائل مش مفعّلة لهالشركة'; end if;
  if not public.sms_host_ok(s.url_template) then raise exception 'دومين البوابة مش مقبول، عدّل الرابط'; end if;
  if length(trim(body)) = 0 then raise exception 'نص الرسالة فاضي'; end if;
  ph := public.sms_phone(case when s.test_mode then s.test_phone else p_phone end);
  if ph is null or length(ph) < 10 or length(ph) > 15 then raise exception 'رقم الجوال مش صحيح%', case when s.test_mode then ' (رقم التجربة)' else '' end; end if;
  if ph not like '962%' and not s.allow_intl then raise exception 'الإرسال لأرقام برّا الأردن مسكّر (من إعداد البوابة)'; end if;
  perform pg_advisory_xact_lock(hashtext('sms|' || p_company));
  select count(*) into n from public.message_log where company_id = p_company and channel = 'sms' and status in ('queued','sent','test')
     and sent_at >= (public.local_today())::timestamp at time zone 'Asia/Amman';
  if n >= s.daily_limit then raise exception 'وصلت حد الرسائل اليومي (%)', s.daily_limit; end if;
  if to_regprocedure('net.http_get(text,jsonb,jsonb,integer)') is null then raise exception 'إضافة pg_net مش مفعّلة بقاعدة البيانات'; end if;
  url := replace(replace(replace(replace(s.url_template, '{phone}', ph), '{msg_hex}', public.ucs2_hex(body)), '{msg}', public.url_encode(body)),
                 '{sender}', public.url_encode(coalesce(s.sender, '')));
  begin
    execute 'select net.http_get($1, ''{}''::jsonb, ''{}''::jsonb, 10000)' into rid using url;
  exception when others then raise exception 'تعذّر الإرسال للبوابة، تأكد من الرابط';
  end;
  perform set_config('sumou.sms', public.internal_token(), true);
  insert into public.message_log (company_id, party_id, phone, channel, kind, ref_id, body, campaign, sent_by, status, request_id)
  values (p_company, p_party, ph, 'sms', p_kind, p_ref, body, p_campaign, auth.uid(), case when s.test_mode then 'test' else 'queued' end, rid)
  returning id into lid;
  perform set_config('sumou.sms', '', true);
  return lid;
end $$;

-- تحديث حالة الرسائل المعلّقة من ردود البوابة
create or replace function public.sms_refresh(p_company uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  if not public.can(p_company, 'marketing', 'view') then raise exception 'ما عندك صلاحية'; end if;
  if to_regclass('net._http_response') is null then return 0; end if;
  execute $q$
    update public.message_log m set
      status = case when m.status = 'test' then 'test' when r.status_code between 200 and 299 and coalesce(r.error_msg, '') = '' then 'sent' else 'failed' end,
      error = case when r.status_code between 200 and 299 and coalesce(r.error_msg, '') = '' then null
                   else left(case when r.status_code is not null then 'رد البوابة ' || r.status_code::text else 'ما وصل رد من البوابة' end
                             || case when coalesce(r.timed_out, false) then ' (انتهت المهلة)' else '' end, 200) end,
      request_id = null
      from net._http_response r
     where r.id = m.request_id and m.company_id = $1 and m.request_id is not null and m.channel = 'sms'
       and r.created >= m.sent_at - interval '1 minute'$q$ using p_company;
  get diagnostics n = row_count;
  return n;
end $$;

-- سطور البوابة ما بتنحذف (عشان حد اليوم والسجل)
drop policy if exists ml_delete on public.message_log;
create policy ml_delete on public.message_log for delete to authenticated using (public.can(company_id, 'marketing', 'delete') and not (channel = 'sms' and status is not null));

revoke execute on function public.sms_config_get(uuid), public.sms_config_save(uuid, jsonb), public.sms_send(uuid, text, text, uuid, text, uuid, text), public.sms_refresh(uuid) from public, anon;
grant execute on function public.sms_config_get(uuid), public.sms_config_save(uuid, jsonb), public.sms_send(uuid, text, text, uuid, text, uuid, text), public.sms_refresh(uuid) to authenticated;
revoke execute on function public.url_encode(text), public.ucs2_hex(text), public.sms_phone(text), public.sms_host(text), public.sms_host_ok(text) from public, anon;
