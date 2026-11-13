\set ON_ERROR_STOP 0
-- إرسال الإيميل (المرحلة 90) — net.http_post وهمي للاختبار المحلي
do $$ begin
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
    create schema if not exists net;
    create table if not exists net._http_response (id bigint primary key, status_code int, content text, error_msg text, url text, timed_out boolean, created timestamptz default now());
    create sequence if not exists net.req_seq;
    alter table net._http_response add column if not exists body jsonb;
    alter table net._http_response add column if not exists headers jsonb;
    create or replace function net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds int) returns bigint
      language plpgsql security definer as $f$ declare i bigint := nextval('net.req_seq'); begin
        insert into net._http_response (id, status_code, content, url, body, headers) values (i, case when body::text like '%fail@x.com%' then 401 else 200 end, '{}', url, body, headers); return i; end $f$;
  end if;
end $$;
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\echo == send before setup (expected ERROR)
select email_send(:'C', array['a@b.com'], 'مرحبا', '<p>x</p>');
\echo == bad from email (expected ERROR)
select email_config_save(:'C', '{"from_email":"not-an-email","api_key":"re_1234567890abcd"}');
select email_config_save(:'C', '{"enabled":true,"test_mode":false,"provider":"resend","from_email":"office@sumou.jo","from_name":"السمو","api_key":"re_SECRETKEY_1234"}');
select (email_config_get(:'C')::text like '%SECRETKEY%') as leaks, email_config_get(:'C') ->> 'key_hint' as hint;
\echo == read settings table directly (expected ERROR)
select api_key from email_settings;
select email_send(:'C', array['client@x.com'], 'كشف حساب', '<h1>كشف</h1>', null, 'campaign') is not null as sent;
select email_send(:'C', array['fail@x.com'], 'فشل', '<p>f</p>', null, 'campaign') is not null as sent2;
\echo == bad recipient (expected ERROR)
select email_send(:'C', array['bad mail'], 'x', '<p>x</p>');
reset role;
select url = 'https://api.resend.com/emails' as url_ok, body ->> 'from' = 'السمو <office@sumou.jo>' as from_ok, headers ->> 'Authorization' = 'Bearer re_SECRETKEY_1234' as auth_ok
  from net._http_response where body is not null order by id desc offset 1 limit 1;
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select sms_refresh(:'C') >= 2 as refreshed;
select status, coalesce(error, '') like '%SECRET%' as leak from message_log where company_id = :'C' and channel = 'email' order by sent_at, body;
\echo == brevo + test mode sends to test address
select email_config_save(:'C', '{"enabled":true,"test_mode":true,"provider":"brevo","from_email":"office@sumou.jo","test_email":"me@sumou.jo"}');
select email_send(:'C', array['someone@x.com'], 'تجربة', '<p>t</p>') is not null as t;
reset role;
select url = 'https://api.brevo.com/v3/smtp/email' as brevo, body -> 'to' -> 0 ->> 'email' = 'me@sumou.jo' as to_test, headers ->> 'api-key' = 're_SECRETKEY_1234' as key_kept
  from net._http_response order by id desc limit 1;
\echo == party email check
update parties set email2 = 'bad' where company_id = 'c0000000-0000-0000-0000-000000000001' and id = (select id from parties where company_id = 'c0000000-0000-0000-0000-000000000001' limit 1);
\echo == employee without marketing: free email (expected ERROR)
set role authenticated; select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false) \g /dev/null
select email_send(:'C', array['x@y.com'], 's', '<p>b</p>');
reset role;
