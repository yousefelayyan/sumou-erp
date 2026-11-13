\set ON_ERROR_STOP 0
-- المرحلة 35: طلبات التزويد
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
insert into warehouses(id,company_id,code,name) values ('a3500000-0000-0000-0000-000000000001',:'C','W35A','الرئيسي 35'),('a3500000-0000-0000-0000-000000000002',:'C','W35B','الفرع 35');
insert into items(id,company_id,code,name) values ('13500000-0000-0000-0000-000000000001',:'C','S1','ماء 35'),('13500000-0000-0000-0000-000000000002',:'C','S2','عصير 35');
insert into stock_docs(id,company_id,doc_type,doc_date,warehouse_id) values ('d3500000-0000-0000-0000-000000000001',:'C','in','2026-02-01','a3500000-0000-0000-0000-000000000001');
insert into stock_doc_lines(doc_id,line_no,item_id,qty,unit_cost) values ('d3500000-0000-0000-0000-000000000001',1,'13500000-0000-0000-0000-000000000001',100,2),('d3500000-0000-0000-0000-000000000001',2,'13500000-0000-0000-0000-000000000002',5,3);
select post_stock_doc('d3500000-0000-0000-0000-000000000001');
insert into item_wh_limits(company_id,item_id,warehouse_id,min_qty,max_qty) values
 (:'C','13500000-0000-0000-0000-000000000001','a3500000-0000-0000-0000-000000000002',30,60),
 (:'C','13500000-0000-0000-0000-000000000002','a3500000-0000-0000-0000-000000000002',20,null);
\echo == max below min (expected ERROR)
insert into item_wh_limits(company_id,item_id,warehouse_id,min_qty,max_qty) values (:'C','13500000-0000-0000-0000-000000000001','a3500000-0000-0000-0000-000000000001',10,5);
select code, dest_qty, min_qty, src_qty, need, suggest, state from supply_min_suggest(:'C','a3500000-0000-0000-0000-000000000001','a3500000-0000-0000-0000-000000000002','2026-03-01');
\echo == same warehouses (expected ERROR)
select supply_save(jsonb_build_object('company_id',:'C','req_date','2026-03-01','from_warehouse_id','a3500000-0000-0000-0000-000000000001','to_warehouse_id','a3500000-0000-0000-0000-000000000001','lines',jsonb_build_array(jsonb_build_object('item_id','13500000-0000-0000-0000-000000000001','qty',5))));
select supply_save(jsonb_build_object('company_id',:'C','req_date','2026-03-01','from_warehouse_id','a3500000-0000-0000-0000-000000000001','to_warehouse_id','a3500000-0000-0000-0000-000000000002',
  'lines',jsonb_build_array(jsonb_build_object('item_id','13500000-0000-0000-0000-000000000001','qty',30),jsonb_build_object('item_id','13500000-0000-0000-0000-000000000002','qty',5)))) is not null as saved;
\echo == issue before confirm (expected ERROR)
select supply_issue_out((select id from supply_requests where req_no=1));
select supply_set_status((select id from supply_requests where req_no=1),'confirmed');
\echo == in before out (expected ERROR)
select supply_issue_in((select id from supply_requests where req_no=1));
select supply_issue_out((select id from supply_requests where req_no=1)) is not null as out_issued;
select d.doc_type, d.status, d.warehouse_id='a3500000-0000-0000-0000-000000000001' src, count(l.*) from stock_docs d join stock_doc_lines l on l.doc_id=d.id where d.supply_request_id is not null group by 1,2,3;
\echo == status change after out (expected ERROR)
select supply_set_status((select id from supply_requests where req_no=1),'pending');
\echo == in before posting out (expected ERROR)
select supply_issue_in((select id from supply_requests where req_no=1));
update stock_doc_lines set qty=25 where doc_id=(select out_doc_id from supply_requests where req_no=1) and item_id='13500000-0000-0000-0000-000000000001';
select post_stock_doc((select out_doc_id from supply_requests where req_no=1));
select supply_issue_in((select id from supply_requests where req_no=1)) is not null as in_issued;
select i.code, l.qty, l.unit_cost from stock_doc_lines l join items i on i.id=l.item_id where l.doc_id=(select in_doc_id from supply_requests where req_no=1) order by i.code;
\echo == edit in-doc lines (expected ERROR)
update stock_doc_lines set qty=99 where doc_id=(select in_doc_id from supply_requests where req_no=1);
\echo == delete in-doc lines (expected ERROR)
delete from stock_doc_lines where doc_id=(select in_doc_id from supply_requests where req_no=1);
\echo == spoof supply_request_id on a doc (silently ignored)
insert into stock_docs(company_id,doc_type,doc_date,warehouse_id,supply_request_id) values (:'C','in','2026-03-05','a3500000-0000-0000-0000-000000000001',(select id from supply_requests where req_no=1)) returning supply_request_id is null as ignored;
select post_stock_doc((select in_doc_id from supply_requests where req_no=1));
select stock_qty('13500000-0000-0000-0000-000000000001','a3500000-0000-0000-0000-000000000002','2026-12-31') dest_qty;
\echo == delete with docs (expected ERROR)
select supply_delete((select id from supply_requests where req_no=1));
\echo == employee no rights (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select supply_save(jsonb_build_object('company_id',:'C','req_date','2026-03-01','from_warehouse_id','a3500000-0000-0000-0000-000000000001','to_warehouse_id','a3500000-0000-0000-0000-000000000002','lines',jsonb_build_array(jsonb_build_object('item_id','13500000-0000-0000-0000-000000000001','qty',5))));
\echo == view-only user cannot delete any stock doc lines (0 rows)
with d as (delete from stock_doc_lines where doc_id='d3500000-0000-0000-0000-000000000001' returning 1) select count(*) as deleted from d;
reset role;
