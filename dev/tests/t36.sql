\set ON_ERROR_STOP 0
-- المرحلة 36: حقول بطاقة العميل + قفل سند إخراج طلب التزويد
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
insert into lookups(id,company_id,kind,code,name) values ('b3600000-0000-0000-0000-000000000001',:'C','route','R1','خط الزرقاء');
update parties set route_id='b3600000-0000-0000-0000-000000000001', reference='REF-9', name2='Alpha Co', currency='jod'
 where id=(select id from parties where company_id=:'C' and party_type='customer' order by code limit 1) returning reference, name2, currency;
\echo == bank as route (expected ERROR)
update parties set route_id=(select id from lookups where company_id=:'C' and kind<>'route' limit 1) where id=(select id from parties where company_id=:'C' and party_type='customer' order by code limit 1);
\echo == unknown currency (expected ERROR)
update parties set currency='XYZ' where id=(select id from parties where company_id=:'C' and party_type='customer' order by code limit 1);
\echo == main department (expected ERROR)
update parties set department_id='d0000000-0000-0000-0000-000000000001' where id=(select id from parties where company_id=:'C' and party_type='customer' order by code limit 1);
\echo == unpost supply out doc after in doc issued (expected ERROR)
select unpost_stock_doc((select out_doc_id from supply_requests where req_no=1), 'stock');
reset role;
