\set ON_ERROR_STOP 0
-- المرحلة 34: عهد الأصول الثابتة
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
insert into asset_custodians(id,company_id,code,name) values
 ('cc340000-0000-0000-0000-000000000001',:'C','K1','أحمد'),('cc340000-0000-0000-0000-000000000002',:'C','K2','سارة');
\echo == manual custodian on asset (expected ERROR)
update fixed_assets set custodian_id='cc340000-0000-0000-0000-000000000001' where code='M2';
\echo == transfer from someone not holding (expected ERROR)
select custody_save(jsonb_build_object('company_id',:'C','kind','transfer','doc_date','2026-08-01','from_custodian_id','cc340000-0000-0000-0000-000000000001','to_custodian_id','cc340000-0000-0000-0000-000000000002','lines',jsonb_build_array(jsonb_build_object('asset_id','fa330000-0000-0000-0000-000000000002'))));
select custody_save(jsonb_build_object('company_id',:'C','kind','handover','doc_date','2026-08-01','to_custodian_id','cc340000-0000-0000-0000-000000000001','location','مكتب 3',
  'lines',jsonb_build_array(jsonb_build_object('asset_id','fa330000-0000-0000-0000-000000000002','condition','جديد','accessories','شاحن')))) is not null as h_saved;
\echo == same asset in another open doc (expected ERROR)
select custody_save(jsonb_build_object('company_id',:'C','kind','handover','doc_date','2026-08-02','to_custodian_id','cc340000-0000-0000-0000-000000000002','lines',jsonb_build_array(jsonb_build_object('asset_id','fa330000-0000-0000-0000-000000000002'))));
select custody_set_status((select id from custody_docs where kind='handover'),'confirmed');
select custody_set_status((select id from custody_docs where kind='handover'),'done');
select c.name, a.location, a.custody_since from fixed_assets a join asset_custodians c on c.id=a.custodian_id where a.code='M2';
\echo == edit done doc (expected ERROR)
select custody_save(jsonb_build_object('id',(select id from custody_docs where kind='handover'),'doc_date','2026-08-01','to_custodian_id','cc340000-0000-0000-0000-000000000002','lines',jsonb_build_array(jsonb_build_object('asset_id','fa330000-0000-0000-0000-000000000002'))));
select custody_save(jsonb_build_object('company_id',:'C','kind','transfer','doc_date','2026-09-01','from_custodian_id','cc340000-0000-0000-0000-000000000001','to_custodian_id','cc340000-0000-0000-0000-000000000002','location','المستودع',
  'lines',jsonb_build_array(jsonb_build_object('asset_id','fa330000-0000-0000-0000-000000000002')))) is not null as t_saved;
select custody_set_status((select id from custody_docs where kind='transfer'),'done');
select c.name, a.location from fixed_assets a join asset_custodians c on c.id=a.custodian_id where a.code='M2';
\echo == revert earlier doc while later exists (expected ERROR)
select custody_set_status((select id from custody_docs where kind='handover'),'pending');
select kind, from_name, to_name, location, ended from custody_history('fa330000-0000-0000-0000-000000000002');
\echo == revert transfer restores
select custody_set_status((select id from custody_docs where kind='transfer'),'pending');
select c.name, a.location from fixed_assets a join asset_custodians c on c.id=a.custodian_id where a.code='M2';
select custody_set_status((select id from custody_docs where kind='handover'),'closed');
\echo == closing keeps the custodian
select c.name, a.location from fixed_assets a join asset_custodians c on c.id=a.custodian_id where a.code='M2';
\echo == closed doc cannot change (expected ERROR)
select custody_set_status((select id from custody_docs where kind='handover'),'pending');
\echo == delete done/closed (expected ERROR)
select custody_delete((select id from custody_docs where kind='handover'));
select custody_delete((select id from custody_docs where kind='transfer'));
select count(*) docs_left from custody_docs;
\echo == employee no rights (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select custody_save(jsonb_build_object('company_id',:'C','kind','handover','doc_date','2026-08-01','to_custodian_id','cc340000-0000-0000-0000-000000000001','lines',jsonb_build_array(jsonb_build_object('asset_id','fa330000-0000-0000-0000-000000000001'))));
insert into asset_custodians(company_id,code,name) values (:'C','K9','x');
reset role;
