\set ON_ERROR_STOP 0
-- المرحلة 37: اسأل السمو + رصيد الأصناف + حذف الشركة
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
select count(*) > 0 as has_rows from ask_sales(:'C','2026-01-01','2026-12-31','customer');
select count(*) > 0 as two_level from ask_sales(:'C','2026-01-01','2026-12-31','month','{}',null,'item');
\echo == bad group (expected ERROR)
select * from ask_sales(:'C','2026-01-01','2026-12-31','drop table');
select count(*) > 0 as avail from items_available(:'C', null, null, array(select id from items where company_id=:'C'));
\echo == delete company with activity (expected ERROR)
delete from companies where id=:'C';
select company_activity(:'C') <> '{}'::jsonb as has_activity;
\echo == other user, other company (expected ERROR)
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false) \g /dev/null
select company_activity(:'C');
reset role;
