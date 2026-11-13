-- سجل الرسائل والواتساب
\set ON_ERROR_STOP 0
\set C 'c0000000-0000-0000-0000-000000000001'
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select id as cust from parties where company_id = :'C' and party_type = 'customer' order by code limit 1 \gset
insert into message_log(company_id,party_id,phone,channel,kind,body) values (:'C',:'cust','962790000000','whatsapp','invoice','مرحبا');
\echo == fake sender (expected ERROR)
insert into message_log(company_id,party_id,phone,channel,kind,body,sent_by) values (:'C',:'cust','962790000000','whatsapp','other','x','22222222-2222-2222-2222-222222222222');
\echo == bad channel (expected ERROR)
insert into message_log(company_id,phone,channel,kind,body) values (:'C','1','fax','other','x');
select count(*) as admin_sees from message_log where company_id = :'C';
update company_settings set msg_templates = '{"invoice":"اهلا [الاسم]"}' where company_id = :'C';
select msg_templates->>'invoice' as tpl from company_settings where company_id = :'C';
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select count(*) as emp_sees_others from message_log where company_id = :'C' and sent_by <> auth.uid();
reset role;
