\set ON_ERROR_STOP 0
-- فحص قوائم الإعداد (المرحلة 23)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
insert into lookups(id,company_id,kind,code,name) values ('1c000000-0000-0000-0000-000000000001',:'C','bank','01','البنك العربي') returning kind, name;
insert into lookups(company_id,kind,code,name,parent_id) values (:'C','bank_branch','01','الشميساني','1c000000-0000-0000-0000-000000000001') returning kind, name;
insert into lookups(company_id,kind,code,name,account_id) values (:'C','payment_method','01','نقدي',(select id from accounts where company_id=:'C' and account_type='cash' and not is_group limit 1)) returning kind, account_id is not null as has_acc;
\echo == region under a bank (expected ERROR)
insert into lookups(company_id,kind,code,name,parent_id) values (:'C','region','01','غلط','1c000000-0000-0000-0000-000000000001');
\echo == group account on payment method (expected ERROR)
insert into lookups(company_id,kind,code,name,account_id) values (:'C','payment_method','02','غلط',(select id from accounts where company_id=:'C' and is_group limit 1));
\echo == bad kind (expected ERROR)
insert into lookups(company_id,kind,code,name) values (:'C','other','01','غلط');
\echo == duplicate code (expected ERROR)
insert into lookups(company_id,kind,code,name) values (:'C','bank','01','مكرر');
\echo == bank with branches cannot be deleted (expected ERROR)
delete from lookups where id='1c000000-0000-0000-0000-000000000001';
\echo == employee cannot add (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
insert into lookups(company_id,kind,code,name) values (:'C','bank','09','ممنوع');
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\echo == in backup
select jsonb_array_length(backup_company(:'C') -> 'tables' -> 'lookups') as lookups;
reset role;
