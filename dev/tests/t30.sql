\set ON_ERROR_STOP 0
-- المرحلة 30: طبيعة مدين ودائن + حساب الموظف
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
update accounts set nature='both' where company_id='c0000000-0000-0000-0000-000000000001' and code='1101' returning nature;
\echo == bad nature (expected ERROR)
update accounts set nature='x' where company_id='c0000000-0000-0000-0000-000000000001' and code='1101';
insert into employees(company_id,code,name,basic_salary,account_id) values ('c0000000-0000-0000-0000-000000000001','E30','موظف 30',300,(select id from accounts where company_id='c0000000-0000-0000-0000-000000000001' and not is_group order by code limit 1)) returning account_id is not null as linked;
\echo == group account / other company (expected ERROR)
insert into employees(company_id,code,name,basic_salary,account_id) values ('c0000000-0000-0000-0000-000000000001','E31','x',1,(select id from accounts where company_id='c0000000-0000-0000-0000-000000000001' and is_group limit 1));
reset role;
