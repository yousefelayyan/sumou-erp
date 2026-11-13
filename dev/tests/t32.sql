\set ON_ERROR_STOP 0
-- المرحلة 32: السنوات غير المتاحة
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\echo == current year cannot be unavailable (expected ERROR)
insert into fiscal_years(company_id,code,start_date,end_date,unavailable) values ('c0000000-0000-0000-0000-000000000001','CUR32',local_today()-1,local_today()+1,true);
insert into fiscal_years(company_id,code,start_date,end_date,unavailable) values ('c0000000-0000-0000-0000-000000000001','NXT32',local_today()+400,local_today()+700,true) returning unavailable;
\echo == past-start unavailable year gets released
reset role;
insert into fiscal_years(company_id,code,start_date,end_date,unavailable) values ('c0000000-0000-0000-0000-000000000001','OLD32','2001-01-01','2001-12-31',true);
set role authenticated;
select fy_release_started('c0000000-0000-0000-0000-000000000001') as released;
select code, unavailable from fiscal_years where code in ('OLD32','NXT32') order by code;
\echo == other user without company gets nothing
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false) \g /dev/null
select fy_release_started('c0000000-0000-0000-0000-000000000001') as released_none;
reset role;
