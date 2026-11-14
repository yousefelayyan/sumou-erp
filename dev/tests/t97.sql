\set ON_ERROR_STOP 0
-- تصليحات الأمان (المرحلة 97)
\set C 'c0000000-0000-0000-0000-000000000001'
-- 1) قفل كلمة السر بيسكّر has_company كمان
reset role;
select set_config('sumou.pwd', internal_token(), false) \g /dev/null
update profiles set must_change_password = true where id = '22222222-2222-2222-2222-222222222222';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select has_company(:'C') = false as hc_locked, (select count(*) from accounts) = 0 as accounts_hidden, (my_password_status() ->> 'must_change')::boolean as status_ok;
reset role;
update profiles set must_change_password = false where id = '22222222-2222-2222-2222-222222222222';
select set_config('sumou.pwd', '', false) \g /dev/null
-- 2) ضوابط القروض ما بتكشف الراتب للموظف على قرض غيره (الموظف 2222 بدون رواتب)
reset role;
select id as lid from employee_loans where employee_id is distinct from (select id from employees where user_id = '22222222-2222-2222-2222-222222222222') limit 1 \gset
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
reset role; update profiles set must_change_password = true where id = '22222222-2222-2222-2222-222222222222' and set_config('sumou.pwd', internal_token(), true) is not null;
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select coalesce(array_length(loan_rule_issues(:'lid'), 1), 0) = 0 as loan_rules_hidden_when_no_access;
reset role; update profiles set must_change_password = false where id = '22222222-2222-2222-2222-222222222222' and set_config('sumou.pwd', internal_token(), true) is not null;
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
-- 3) سجل النشاط: إدخال مباشر بينعلّم، وتصوير الشاشة ممنوع
insert into activity_log (user_id, company_id, action, entity, details) values (auth.uid(), :'C', 'تجربة97', 'x', '{"a":1}');
reset role; select (details ->> 'client')::boolean as marked_client from activity_log where action = 'تجربة97';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
\echo == forged screen log (expected ERROR)
insert into activity_log (user_id, company_id, action, entity) values (auth.uid(), :'C', 'تصوير شاشة', 'screen');
\echo == update log (expected ERROR)
update activity_log set action = 'x' where action = 'تجربة97';
-- 4) المرفقات: المسار لازم يطابق المستند
reset role;
select id as eid from journal_entries where company_id = :'C' limit 1 \gset
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\echo == attachment wrong path (expected ERROR)
insert into attachments (company_id, entity, entity_id, path, file_name) values (:'C', 'entry', :'eid', :'C' || '/employee/x/1.pdf', 'a.pdf');
insert into attachments (company_id, entity, entity_id, path, file_name) values (:'C', 'entry', :'eid', :'C' || '/entry/' || :'eid' || '/t97.pdf', 'a.pdf');
\echo == duplicate attachment path (expected ERROR)
insert into attachments (company_id, entity, entity_id, path, file_name) values (:'C', 'entry', :'eid', :'C' || '/entry/' || :'eid' || '/t97.pdf', 'b.pdf');
-- 5) شعار الشركة
reset role;
\echo == bad logo url (expected ERROR)
update companies set logo_url = 'javascript:alert(1)' where id = :'C';
update companies set logo_url = 'https://example.com/logo.png' where id = :'C';
update companies set logo_url = null where id = :'C';
-- 6) الزائر ما بيشغّل الدوال إلا التسجيل بالتجربة
select has_function_privilege('anon', 'public.has_company(uuid)', 'execute') = false as anon_no_has_company,
       has_function_privilege('anon', 'public.screen_event(uuid,text,text)', 'execute') = false as anon_no_screen,
       has_function_privilege('anon', 'public.trial_signup(jsonb)', 'execute') as anon_trial,
       has_function_privilege('authenticated', 'public.can(uuid,text,text)', 'execute') as auth_can,
       has_function_privilege('authenticated', 'public.internal_token()', 'execute') = false as auth_no_token;
-- تنظيف
delete from attachments where path like '%/t97.pdf';
delete from activity_log where action = 'تجربة97';
