\set ON_ERROR_STOP 0
-- الباركود المتعدد والسيريال (المرحلة 86)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set IT '10000000-0000-0000-0000-000000000086'
insert into items(id,company_id,code,name,sale_price,serial_tracked,barcode) values (:'IT',:'C','S86','جوال تجريبي',300,true,'628000086') on conflict do nothing;
select id as wh from warehouses where company_id = :'C' and is_active order by code limit 1 \gset
insert into warehouses(company_id, code, name) values (:'C','W86','مستودع 86') on conflict do nothing;
select id as wh2 from warehouses where company_id = :'C' and code = 'W86' \gset
\echo == alt barcode = main barcode (expected ERROR)
insert into item_barcodes (company_id, item_id, barcode) values (:'C', :'IT', '628000086');
insert into item_barcodes (company_id, item_id, barcode, factor, label) values (:'C', :'IT', '628000086-BOX', 5, 'كرتونة') returning factor;
-- إدخال 3 سيريالات
insert into stock_docs (id, company_id, doc_type, doc_date, warehouse_id) values ('5d860000-0000-0000-0000-000000000001',:'C','in','2026-05-01',:'wh');
\echo == serial count must equal qty (expected ERROR)
insert into stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost, serials) values ('5d860000-0000-0000-0000-000000000001',1,:'IT',3,200,array['SN1',' SN2 ','SN2']);
select post_stock_doc('5d860000-0000-0000-0000-000000000001');
update stock_doc_lines set serials = array['SN1','SN2','SN3'] where doc_id = '5d860000-0000-0000-0000-000000000001';
select post_stock_doc('5d860000-0000-0000-0000-000000000001');
select string_agg(serial, ',' order by serial) from serial_balances(:'C', :'wh', :'IT');
\echo == receive an existing serial again (expected ERROR)
insert into stock_docs (id, company_id, doc_type, doc_date, warehouse_id) values ('5d860000-0000-0000-0000-000000000002',:'C','in','2026-05-02',:'wh2');
insert into stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost, serials) values ('5d860000-0000-0000-0000-000000000002',1,:'IT',1,200,array['SN1']);
select post_stock_doc('5d860000-0000-0000-0000-000000000002');
\echo == transfer SN2 to wh2, then sell SN2 from wh (expected ERROR on the sale post)
insert into stock_docs (id, company_id, doc_type, doc_date, warehouse_id, to_warehouse_id) values ('5d860000-0000-0000-0000-000000000003',:'C','transfer','2026-05-03',:'wh',:'wh2');
insert into stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost, serials) values ('5d860000-0000-0000-0000-000000000003',1,:'IT',1,200,array['SN2']);
select post_stock_doc('5d860000-0000-0000-0000-000000000003');
select warehouse_id = :'wh2' as in_wh2, serial from serial_balances(:'C', null, :'IT') order by 1, 2;
insert into stock_docs (id, company_id, doc_type, doc_date, warehouse_id) values ('5d860000-0000-0000-0000-000000000004',:'C','out','2026-05-04',:'wh');
insert into stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost, serials) values ('5d860000-0000-0000-0000-000000000004',1,:'IT',1,200,array['SN2']);
select post_stock_doc('5d860000-0000-0000-0000-000000000004');
update stock_doc_lines set serials = array['SN3'] where doc_id = '5d860000-0000-0000-0000-000000000004';
select post_stock_doc('5d860000-0000-0000-0000-000000000004');
select count(*) as in_stock from serial_balances(:'C', null, :'IT');
\echo == unpost the first in doc after its serials moved (expected ERROR)
select unpost_stock_doc('5d860000-0000-0000-0000-000000000001', 'stock');
select move_date, qty, doc_kind from serial_history(:'C', 'SN3') order by move_date;
reset role;
\echo == purchase invoice with serials, then unpost stock
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into invoices (id, company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_name, warehouse_id) values ('5d860000-0000-0000-0000-0000000000a1',:'C','f0000000-0000-0000-0000-000000000001','purchase','2026-05-05','cash','مورد 86',:'wh');
insert into invoice_lines (invoice_id, line_no, item_id, description, qty, unit_price, tax_rate, subtotal, tax_amount, line_total, serials) values ('5d860000-0000-0000-0000-0000000000a1',1,:'IT','جوال',2,200,0,400,0,400,array['SN8','SN9']);
select post_invoice_stock('5d860000-0000-0000-0000-0000000000a1');
select count(*) as after_purchase from serial_balances(:'C', :'wh', :'IT');
select unpost_invoice('5d860000-0000-0000-0000-0000000000a1', 'stock');
select count(*) as after_unpost from serial_balances(:'C', :'wh', :'IT');
reset role;
