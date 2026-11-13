\set ON_ERROR_STOP 0
-- بوابة الرسائل القصيرة (المرحلة 73) — pg_net وهمي للاختبار المحلي
do $$ begin
  if to_regprocedure('net.http_get(text,jsonb,jsonb,integer)') is null then
    create schema if not exists net;
    create table if not exists net._http_response (id bigint primary key, status_code int, content text, error_msg text, url text, timed_out boolean, created timestamptz default now());
    create sequence if not exists net.req_seq;
    create or replace function net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds int) returns bigint
      language plpgsql security definer as $f$ declare i bigint := nextval('net.req_seq'); begin
        insert into net._http_response (id, status_code, content, error_msg, url) values (i, case when url like '%962790000000%' then 500 else 200 end, 'user=u pass=SECRET', null, url); return i; end $f$;
  end if;
end $$;
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\echo == send before setup (expected ERROR)
select sms_send(:'C', '0791234567', 'مرحبا');
\echo == ssrf ip host (expected ERROR)
select sms_config_save(:'C', '{"url_template":"https://169.254.169.254/x?a={phone}&b={msg}"}');
\echo == http not https (expected ERROR)
select sms_config_save(:'C', '{"url_template":"http://sms.gateway.jo/x?a={phone}&b={msg}"}');
\echo == bad url (expected ERROR)
select sms_config_save(:'C', '{"url_template":"https://sms.gateway.jo/send?user=u&pass=SECRET&to=x"}');
select sms_config_save(:'C', '{"enabled":true,"test_mode":false,"sender":"Sumou","url_template":"https://u:PW@sms.gateway.jo:443/send?user=u&pass=SECRET&to={phone}&text={msg}&from={sender}"}');
select (sms_config_get(:'C') ->> 'host') as host, (sms_config_get(:'C')::text like '%SECRET%') as leaks;
\echo == read settings table directly (expected ERROR)
select url_template from sms_settings;
select sms_send(:'C', '0791234567', 'مرحبا أحمد', null, 'campaign') is not null as sent;
select sms_send(:'C', '0790000000', 'فشل', null, 'campaign') is not null as sent2;
reset role;
select url like '%to=962791234567%' and url like '%text=%D9%85%D8%B1%D8%AD%D8%A8%D8%A7%20%D8%A3%D8%AD%D9%85%D8%AF%' as url_ok from net._http_response order by id desc offset 1 limit 1;
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select sms_refresh(:'C') as refreshed;
select status, error, coalesce(error,'') like '%SECRET%' as leak from message_log where company_id = :'C' and channel = 'sms' order by sent_at, body;
-- السجل من المستخدم ما بيقدر يكتب الحالة
insert into message_log (company_id, phone, channel, body, status, request_id) values (:'C', '079', 'sms', 'يدوي', 'sent', 1) returning status is null and request_id is null as forced;
reset role; select ucs2_hex('سلام') as hex;
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
-- وضع التجربة بيبعت لرقم التجربة
select sms_config_save(:'C', '{"enabled":true,"test_mode":true,"test_phone":"0795555555","daily_limit":3}');
select sms_send(:'C', '0791111111', 'تجربة') is not null as t;
select phone, status from message_log where body = 'تجربة';
\echo == daily limit (expected ERROR)
select sms_send(:'C', '0791111111', 'تجربة 2'); select sms_send(:'C', '0791111111', 'تجربة 3');
\echo == international number blocked (expected ERROR)
select sms_config_save(:'C', '{"enabled":true,"test_mode":false,"daily_limit":50}');
select sms_send(:'C', '00447700900123', 'برّا');
-- الموظف بدون تسويق
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
\echo == employee free send without marketing (expected ERROR)
reset role;
update user_groups set permissions = (permissions - 'marketing') || '{"sales_invoices":{"view":true,"add":true}}' where id = (select group_id from user_companies where user_id = '22222222-2222-2222-2222-222222222222' and company_id = :'C');
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select sms_send(:'C', '0791234567', 'سبام');
\echo == employee save settings (expected ERROR)
select sms_config_save(:'C', '{"enabled":false}');
reset role;
