\set ON_ERROR_STOP 0
-- المرحلة 33: حركات الأصول الثابتة
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set cust `psql -h /tmp -p 5433 -U postgres -Atqc "select id from parties where company_id='c0000000-0000-0000-0000-000000000001' and party_type='customer' and is_active order by code limit 1"`
insert into fixed_assets(id,company_id,code,name,purchase_date,dep_start,cost,salvage,life_months,asset_account_id,department_id)
 select 'fa330000-0000-0000-0000-000000000001',:'C','M1','سيارة','2026-01-01','2026-01-01',12000,0,60,id,'d0000000-0000-0000-0000-000000000002' from accounts where company_id=:'C' and code='1206';
insert into fixed_assets(id,company_id,code,name,purchase_date,dep_start,cost,salvage,life_months,asset_account_id,department_id)
 select 'fa330000-0000-0000-0000-000000000002',:'C','M2','طابعة','2026-01-01','2026-01-01',600,0,12,id,'d0000000-0000-0000-0000-000000000002' from accounts where company_id=:'C' and code='1206';
insert into fixed_assets(id,company_id,code,name,purchase_date,dep_start,cost,salvage,life_months,asset_account_id)
 select 'fa330000-0000-0000-0000-000000000003',:'C','M3','مكتب','2026-01-01','2026-01-01',1200,0,24,id from accounts where company_id=:'C' and code='1206';
select ensure_asset_disposal_account(:'C') is not null as disp_acc;
select a.code, a.nature, a.category from accounts a join company_settings s on s.asset_disposal_account_id = a.id where s.company_id = :'C';

\echo == transfer: same department (expected ERROR)
select asset_mov_save(jsonb_build_object('company_id',:'C','kind','transfer','mov_date','2026-06-10','from_department_id','d0000000-0000-0000-0000-000000000002','to_department_id','d0000000-0000-0000-0000-000000000002','lines',jsonb_build_array(jsonb_build_object('asset_id','fa330000-0000-0000-0000-000000000002'))));
\echo == transfer: asset not in from dept (expected ERROR)
select asset_mov_save(jsonb_build_object('company_id',:'C','kind','transfer','mov_date','2026-06-10','from_department_id','d0000000-0000-0000-0000-000000000003','to_department_id','d0000000-0000-0000-0000-000000000002','lines',jsonb_build_array(jsonb_build_object('asset_id','fa330000-0000-0000-0000-000000000002'))));
select asset_mov_save(jsonb_build_object('company_id',:'C','kind','transfer','mov_date','2026-06-10','from_department_id','d0000000-0000-0000-0000-000000000002','to_department_id','d0000000-0000-0000-0000-000000000003','lines',jsonb_build_array(jsonb_build_object('asset_id','fa330000-0000-0000-0000-000000000002')))) is not null as tr_saved;
\echo == second draft with same asset (expected ERROR)
select asset_mov_save(jsonb_build_object('company_id',:'C','kind','dispose','mov_date','2026-06-10','lines',jsonb_build_array(jsonb_build_object('asset_id','fa330000-0000-0000-0000-000000000002'))));
select asset_mov_post((select id from asset_movements where kind='transfer')) is null as tr_no_entry;
select code, department_id = 'd0000000-0000-0000-0000-000000000003' as moved from fixed_assets where code='M2';

\echo == direct insert blocked (expected ERROR)
insert into asset_movements(company_id,mov_no,kind,mov_date) values (:'C',99,'dispose','2026-01-01');

\echo == dispose without depreciation up to prev month (expected ERROR)
select asset_mov_save(jsonb_build_object('company_id',:'C','kind','dispose','mov_date','2026-07-15','lines',jsonb_build_array(jsonb_build_object('asset_id','fa330000-0000-0000-0000-000000000003')))) is not null as disp_saved;
select asset_mov_post((select id from asset_movements where kind='dispose'));
select post_depreciation(:'C','2026-06-30') is not null as dep_ok;
select asset_accum('fa330000-0000-0000-0000-000000000003') accum3;
select asset_mov_post((select id from asset_movements where kind='dispose')) is not null as disp_posted;
select a.code, l.debit, l.credit from journal_lines l join accounts a on a.id=l.account_id
 where l.entry_id=(select entry_id from asset_movements where kind='dispose') order by l.line_no;
select status, disposed_date from fixed_assets where code='M3';
\echo == manual reactivate blocked (expected ERROR)
update fixed_assets set status='active' where code='M3';

\echo == sale with gain
select asset_mov_save(jsonb_build_object('company_id',:'C','kind','sale','mov_date','2026-07-20','party_id',:'cust','tax_rate',16,'lines',jsonb_build_array(jsonb_build_object('asset_id','fa330000-0000-0000-0000-000000000001','sale_price',12000)))) is not null as sale_saved;
select total_price, total_tax from asset_movements where kind='sale';
select asset_mov_post((select id from asset_movements where kind='sale')) is not null as sale_posted;
select a.code, l.debit, l.credit, l.party_id is not null as has_party from journal_lines l join accounts a on a.id=l.account_id
 where l.entry_id=(select entry_id from asset_movements where kind='sale') order by l.line_no;
select sum(debit)=sum(credit) as balanced from journal_lines where entry_id=(select entry_id from asset_movements where kind='sale');

\echo == employee without rights (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select asset_mov_cancel((select id from asset_movements where kind='sale'));
select count(*) as emp_sees from asset_movements;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null

\echo == cancel sale restores asset
select asset_mov_cancel((select id from asset_movements where kind='sale'), '2026-07-25');
select status, disposed_date from fixed_assets where code='M1';
select m.status, e.status as entry_status from asset_movements m join journal_entries e on e.id=m.entry_id where m.kind='sale';
\echo == delete posted (expected ERROR)
select asset_mov_delete((select id from asset_movements where kind='dispose'));
\echo == cancel transfer restores department
select asset_mov_cancel((select id from asset_movements where kind='transfer'));
select department_id = 'd0000000-0000-0000-0000-000000000002' as back from fixed_assets where code='M2';
reset role;
