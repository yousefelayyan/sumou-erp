-- =====================================================================
--  المرحلة 90: إرسال الكشوف والفواتير بالإيميل
--  - parties.email2 / email3 (لحد 3 إيميلات لكل طرف)
--  - email_settings: مزوّد الإيميل (Resend أو Brevo) ومفتاحه — بدون أي سياسة قراءة ومش بالنسخة الاحتياطية
--  - email_send(company, to[], subject, html, party, kind, ref): الإرسال من السيرفر بـ pg_net (net.http_post)
--  - الحالة بتتحدّث من sms_refresh (صارت للرسائل والإيميل)
-- =====================================================================
alter table public.parties add column if not exists email2 text;
alter table public.parties add column if not exists email3 text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'parties_emails_chk') then
    alter table public.parties add constraint parties_emails_chk check (
      (email2 is null or (length(email2) <= 200 and email2 ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')) and
      (email3 is null or (length(email3) <= 200 and email3 ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'))) not valid;
  end if;
end $$;

create table if not exists public.email_settings (
  company_id  uuid primary key references public.companies(id) on delete cascade,
  enabled     boolean not null default false,
  provider    text not null default 'resend' check (provider in ('resend','brevo')),
  api_key     text check (api_key is null or length(api_key) <= 300),
  from_email  text check (from_email is null or (length(from_email) <= 200 and from_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')),
  from_name   text check (from_name is null or length(from_name) <= 100),
  reply_to    text check (reply_to is null or (length(reply_to) <= 200 and reply_to ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')),
  test_mode   boolean not null default true,
  test_email  text check (test_email is null or (length(test_email) <= 200 and test_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')),
  daily_limit int not null default 300 check (daily_limit between 1 and 10000),
  updated_by  uuid,
  updated_at  timestamptz not null default now()
);
alter table public.email_settings enable row level security;
revoke all on public.email_settings from anon, authenticated;

create or replace function public.email_ok(p text) returns boolean
language sql immutable as $$ select p is not null and length(p) <= 200 and p ~* '^[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+$' $$;

-- الإعداد للواجهة: بدون المفتاح
create or replace function public.email_config_get(p_company uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not (public.can(p_company, 'marketing', 'view') or public.can(p_company, 'companies', 'edit')) then null else
    jsonb_build_object('has_key', s.api_key is not null, 'key_hint', case when s.api_key is not null then '…' || right(s.api_key, 4) end,
      'provider', coalesce(s.provider, 'resend'), 'enabled', coalesce(s.enabled, false), 'from_email', s.from_email, 'from_name', s.from_name,
      'reply_to', s.reply_to, 'test_mode', coalesce(s.test_mode, true), 'test_email', s.test_email, 'daily_limit', coalesce(s.daily_limit, 300),
      'trial', public.sms_trial(p_company), 'pg_net', to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is not null,
      'sent_today', (select count(*) from public.message_log m where m.company_id = p_company and m.channel = 'email' and m.status in ('queued','sent','test')
                      and m.sent_at >= (public.local_today())::timestamp at time zone 'Asia/Amman'))
  end from (select 1) x left join public.email_settings s on s.company_id = p_company;
$$;

create or replace function public.email_config_save(p_company uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare k text := nullif(trim(p ->> 'api_key'), ''); fe text := nullif(trim(p ->> 'from_email'), '');
  te text := nullif(trim(p ->> 'test_email'), ''); rt text := nullif(trim(p ->> 'reply_to'), '');
begin
  if not public.can(p_company, 'companies', 'edit') or not public.tenant_writable() then raise exception 'ما عندك صلاحية تعديل إعدادات الشركة'; end if;
  if public.sms_trial(p_company) then raise exception 'بوابة الإيميل مش متاحة بالنسخة التجريبية'; end if;
  if coalesce(p ->> 'provider', 'resend') not in ('resend','brevo') then raise exception 'مزوّد الإيميل غلط'; end if;
  if k is not null and (length(k) < 10 or k ~ '\s') then raise exception 'مفتاح المزوّد مش صحيح'; end if;
  if fe is not null and not public.email_ok(fe) then raise exception 'إيميل المرسل مش صحيح'; end if;
  if te is not null and not public.email_ok(te) then raise exception 'إيميل التجربة مش صحيح'; end if;
  if rt is not null and not public.email_ok(rt) then raise exception 'إيميل الرد مش صحيح'; end if;
  insert into public.email_settings (company_id, enabled, provider, api_key, from_email, from_name, reply_to, test_mode, test_email, daily_limit, updated_by, updated_at)
  values (p_company, coalesce((p ->> 'enabled')::boolean, false), coalesce(p ->> 'provider', 'resend'), k, fe, left(nullif(trim(p ->> 'from_name'), ''), 100), rt,
          coalesce((p ->> 'test_mode')::boolean, true), te, coalesce((p ->> 'daily_limit')::int, 300), auth.uid(), now())
  on conflict (company_id) do update set enabled = excluded.enabled, provider = excluded.provider, api_key = coalesce(k, email_settings.api_key),
    from_email = excluded.from_email, from_name = excluded.from_name, reply_to = excluded.reply_to, test_mode = excluded.test_mode,
    test_email = excluded.test_email, daily_limit = excluded.daily_limit, updated_by = auth.uid(), updated_at = now();
  if (p ->> 'clear_key')::boolean then update public.email_settings set api_key = null, enabled = false where company_id = p_company; end if;
end $$;

-- إرسال إيميل (بيرجع رقم سطر السجل)
create or replace function public.email_send(p_company uuid, p_to text[], p_subject text, p_html text, p_party uuid default null,
                                             p_kind text default 'other', p_ref uuid default null, p_campaign text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare s public.email_settings; pa public.parties; mk boolean; tos text[]; e text; rid bigint; lid uuid; n int;
  subj text := left(trim(coalesce(p_subject, '')), 200); html text := coalesce(p_html, ''); url text; hdr jsonb; body jsonb;
begin
  mk := public.can(p_company, 'marketing', 'add');
  if not (mk or public.can(p_company, 'sales_invoices', 'add') or public.can(p_company, 'receipt_vouchers', 'add')
          or public.can(p_company, 'customers', 'view') or public.can(p_company, 'suppliers', 'view'))
     or not public.tenant_writable() then raise exception 'ما عندك صلاحية إرسال إيميلات'; end if;
  if public.sms_trial(p_company) then raise exception 'بوابة الإيميل مش متاحة بالنسخة التجريبية'; end if;
  if p_party is not null then
    select * into pa from public.parties where id = p_party and company_id = p_company;
    if pa.id is null then raise exception 'الطرف مش من هالشركة'; end if;
  end if;
  if p_kind not in ('invoice','statement','payment','reminder','campaign','other') then p_kind := 'other'; end if;
  select array_agg(distinct lower(trim(x))) into tos from unnest(coalesce(p_to, '{}')) x where nullif(trim(x), '') is not null;
  if coalesce(array_length(tos, 1), 0) = 0 then raise exception 'ما في إيميل للإرسال'; end if;
  if array_length(tos, 1) > 10 then raise exception 'أقصى إشي 10 إيميلات بالرسالة الوحدة'; end if;
  foreach e in array tos loop
    if not public.email_ok(e) then raise exception 'الإيميل «%» مش صحيح', e; end if;
  end loop;
  -- بدون صلاحية التسويق: بس لإيميلات الطرف نفسه، وفاتورة/كشف/دفعة
  if not mk then
    if pa.id is null or p_kind not in ('invoice','statement','payment') then
      raise exception 'الإرسال الحر بدها صلاحية التسويق؛ بتقدر تبعت فاتورة أو كشف أو دفعة لإيميل الطرف نفسه بس';
    end if;
    foreach e in array tos loop
      if e not in (coalesce(lower(trim(pa.email)), '-'), coalesce(lower(trim(pa.email2)), '-'), coalesce(lower(trim(pa.email3)), '-')) then
        raise exception 'بتقدر تبعت بس لإيميلات الطرف المسجّلة ببطاقته';
      end if;
    end loop;
  end if;
  if length(subj) = 0 then raise exception 'عنوان الإيميل فاضي'; end if;
  if length(html) = 0 then raise exception 'نص الإيميل فاضي'; end if;
  if length(html) > 300000 then raise exception 'الإيميل كبير كثير'; end if;
  select * into s from public.email_settings where company_id = p_company;
  if s.company_id is null or not s.enabled or s.api_key is null or s.from_email is null then raise exception 'بوابة الإيميل مش مفعّلة لهالشركة'; end if;
  if s.test_mode then
    if s.test_email is null then raise exception 'حط إيميل التجربة بإعداد البوابة'; end if;
    tos := array[lower(s.test_email)];
  end if;
  perform pg_advisory_xact_lock(hashtext('email|' || p_company));
  select count(*) into n from public.message_log where company_id = p_company and channel = 'email' and status in ('queued','sent','test')
     and sent_at >= (public.local_today())::timestamp at time zone 'Asia/Amman';
  if n >= s.daily_limit then raise exception 'وصلت حد الإيميلات اليومي (%)', s.daily_limit; end if;
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then raise exception 'إضافة pg_net مش مفعّلة بقاعدة البيانات'; end if;
  if s.provider = 'brevo' then
    url := 'https://api.brevo.com/v3/smtp/email';
    hdr := jsonb_build_object('api-key', s.api_key, 'Content-Type', 'application/json', 'accept', 'application/json');
    body := jsonb_build_object('sender', jsonb_build_object('email', s.from_email, 'name', coalesce(s.from_name, '')),
              'to', (select jsonb_agg(jsonb_build_object('email', x)) from unnest(tos) x), 'subject', subj, 'htmlContent', html)
            || case when s.reply_to is not null then jsonb_build_object('replyTo', jsonb_build_object('email', s.reply_to)) else '{}'::jsonb end;
  else
    url := 'https://api.resend.com/emails';
    hdr := jsonb_build_object('Authorization', 'Bearer ' || s.api_key, 'Content-Type', 'application/json');
    body := jsonb_build_object('from', case when s.from_name is not null then s.from_name || ' <' || s.from_email || '>' else s.from_email end,
              'to', to_jsonb(tos), 'subject', subj, 'html', html)
            || case when s.reply_to is not null then jsonb_build_object('reply_to', s.reply_to) else '{}'::jsonb end;
  end if;
  begin
    execute 'select net.http_post($1, $2, ''{}''::jsonb, $3, 15000)' into rid using url, body, hdr;
  exception when others then raise exception 'تعذّر الإرسال لمزوّد الإيميل';
  end;
  perform set_config('sumou.sms', public.internal_token(), true);
  insert into public.message_log (company_id, party_id, phone, channel, kind, ref_id, body, campaign, sent_by, status, request_id)
  values (p_company, p_party, left(array_to_string(tos, ', '), 200), 'email', p_kind, p_ref,
          left(subj || E'\n' || regexp_replace(regexp_replace(html, '<[^>]*>', ' ', 'g'), '\s+', ' ', 'g'), 2000),
          p_campaign, auth.uid(), case when s.test_mode then 'test' else 'queued' end, rid)
  returning id into lid;
  perform set_config('sumou.sms', '', true);
  return lid;
end $$;

-- تحديث الحالة صار للرسائل والإيميل
create or replace function public.sms_refresh(p_company uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  if not (public.can(p_company, 'marketing', 'view') or public.can(p_company, 'customers', 'view')) then raise exception 'ما عندك صلاحية'; end if;
  if to_regclass('net._http_response') is null then return 0; end if;
  execute $q$
    update public.message_log m set
      status = case when m.status = 'test' then 'test' when r.status_code between 200 and 299 and coalesce(r.error_msg, '') = '' then 'sent' else 'failed' end,
      error = case when r.status_code between 200 and 299 and coalesce(r.error_msg, '') = '' then null
                   else left(case when r.status_code is not null then 'رد المزوّد ' || r.status_code::text else 'ما وصل رد من المزوّد' end
                             || case when coalesce(r.timed_out, false) then ' (انتهت المهلة)' else '' end, 200) end,
      request_id = null
      from net._http_response r
     where r.id = m.request_id and m.company_id = $1 and m.request_id is not null and m.channel in ('sms','email')
       and r.created >= m.sent_at - interval '1 minute'$q$ using p_company;
  get diagnostics n = row_count;
  return n;
end $$;

drop policy if exists ml_delete on public.message_log;
create policy ml_delete on public.message_log for delete to authenticated using (public.can(company_id, 'marketing', 'delete') and not (channel in ('sms','email') and status is not null));

revoke execute on function public.email_config_get(uuid), public.email_config_save(uuid, jsonb),
  public.email_send(uuid, text[], text, text, uuid, text, uuid, text) from public, anon;
grant execute on function public.email_config_get(uuid), public.email_config_save(uuid, jsonb),
  public.email_send(uuid, text[], text, text, uuid, text, uuid, text) to authenticated;
revoke execute on function public.email_ok(text) from public, anon;
