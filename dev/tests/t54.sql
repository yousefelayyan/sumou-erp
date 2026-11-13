-- الماركات وبيانات الصنف
\set ON_ERROR_STOP 0
\set C 'c0000000-0000-0000-0000-000000000001'
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into lookups(id,company_id,kind,code,name) values ('54000000-0000-0000-0000-0000000000b1',:'C','brand','000006','Milwaukee') on conflict do nothing;
select id as it from items where company_id = :'C' order by code limit 1 \gset
update items set brand_id = '54000000-0000-0000-0000-0000000000b1', model = 'M18CHM-902C', color = 'أحمر' where id = :'it';
select l.name as brand, i.model from items i join lookups l on l.id = i.brand_id where i.id = :'it';
\echo == brand from wrong kind (expected ERROR)
update items set brand_id = (select id from lookups where company_id = :'C' and kind <> 'brand' limit 1) where id = :'it';
\echo == bad lookup kind (expected ERROR)
insert into lookups(company_id,kind,code,name) values (:'C','xyz','1','x');
update items set brand_id = null, model = null, color = null where id = :'it';
reset role;
