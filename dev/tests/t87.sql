\set ON_ERROR_STOP 0
-- تصليحات المراجعة (المرحلة 87)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
insert into guarantee_cheques (company_id, direction, cheque_no, amount, doc_no) values (:'C','in','G-87',10,2147483647) returning doc_no < 2147483647 as numbered_by_system;
delete from guarantee_cheques where cheque_no = 'G-87';
\echo == serial out dated before it came in (expected ERROR)
\set IT '10000000-0000-0000-0000-000000000087'
insert into items(id,company_id,code,name,serial_tracked) values (:'IT',:'C','S87','سيريال 87',true) on conflict do nothing;
select id as wh from warehouses where company_id = :'C' and is_active order by code limit 1 \gset
insert into stock_docs (id, company_id, doc_type, doc_date, warehouse_id) values ('5d870000-0000-0000-0000-000000000001',:'C','in','2026-06-10',:'wh');
insert into stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost, serials) values ('5d870000-0000-0000-0000-000000000001',1,:'IT',1,5,array['Z87']);
select post_stock_doc('5d870000-0000-0000-0000-000000000001');
insert into stock_docs (id, company_id, doc_type, doc_date, warehouse_id) values ('5d870000-0000-0000-0000-000000000002',:'C','out','2026-06-01',:'wh');
insert into stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost, serials) values ('5d870000-0000-0000-0000-000000000002',1,:'IT',1,5,array['Z87']);
select post_stock_doc('5d870000-0000-0000-0000-000000000002');
\echo == alt barcode reused as main barcode (expected ERROR)
insert into item_barcodes (company_id, item_id, barcode) values (:'C', :'IT', 'ALT87');
update items set barcode = 'ALT87' where company_id = :'C' and code <> 'S87' and id = (select id from items where company_id = :'C' and code <> 'S87' order by code limit 1);
reset role;
