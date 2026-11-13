-- الخانات العشرية
\set ON_ERROR_STOP 0
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
update company_settings set decimals = '{"amount":2,"qty":0,"price":3}' where company_id = 'c0000000-0000-0000-0000-000000000001';
select decimals from company_settings where company_id = 'c0000000-0000-0000-0000-000000000001';
\echo == decimals out of range (expected ERROR)
update company_settings set decimals = '{"amount":5}' where company_id = 'c0000000-0000-0000-0000-000000000001';
update company_settings set decimals = '{}' where company_id = 'c0000000-0000-0000-0000-000000000001';
reset role;
