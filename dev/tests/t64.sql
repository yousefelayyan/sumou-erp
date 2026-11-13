\set ON_ERROR_STOP 0
-- الدفعات وتواريخ الانتهاء (المرحلة 64)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
\set IT '10000000-0000-0000-0000-000000000064'
insert into items(id,company_id,code,name,sale_price,batch_mode) values (:'IT',:'C','B64','دواء تجريبي',10,'expiry') on conflict do nothing;
\echo == bad batch mode (expected ERROR)
update items set batch_mode = 'xx' where id = :'IT';
select id as wh from warehouses where company_id = :'C' and is_active order by code limit 1 \gset
insert into warehouses(company_id, code, name) values (:'C','W64','مستودع 64') on conflict do nothing;
select id as wh2 from warehouses where company_id = :'C' and code = 'W64' \gset
-- إدخال دفعتين
insert into stock_docs (id, company_id, doc_type, doc_date, warehouse_id) values ('5d640000-0000-0000-0000-000000000001',:'C','in','2026-03-01',:'wh');
insert into stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost, batch_no, expiry_date) values
 ('5d640000-0000-0000-0000-000000000001',1,:'IT',10,2,'A1','2026-12-31'),
 ('5d640000-0000-0000-0000-000000000001',2,:'IT',5,2,'B2','2026-06-30');
select post_stock_doc('5d640000-0000-0000-0000-000000000001');
select batch_no, expiry_date, qty from batch_balances(:'C', :'wh', :'IT') order by batch_no;
-- إخراج بدون دفعة: الأقرب انتهاء أول (B2 كاملة ثم 2 من A1)
insert into stock_docs (id, company_id, doc_type, doc_date, warehouse_id) values ('5d640000-0000-0000-0000-000000000002',:'C','out','2026-04-01',:'wh');
insert into stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost) values ('5d640000-0000-0000-0000-000000000002',1,:'IT',7,2);
select post_stock_doc('5d640000-0000-0000-0000-000000000002');
select batch_no, qty from batch_balances(:'C', :'wh', :'IT', true) order by batch_no;
-- تحويل برقم دفعة
insert into stock_docs (id, company_id, doc_type, doc_date, warehouse_id, to_warehouse_id) values ('5d640000-0000-0000-0000-000000000003',:'C','transfer','2026-04-02',:'wh',:'wh2');
insert into stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost, batch_no) values ('5d640000-0000-0000-0000-000000000003',1,:'IT',3,2,'A1');
select post_stock_doc('5d640000-0000-0000-0000-000000000003');
select warehouse_id = :'wh2' as in_wh2, batch_no, qty from batch_balances(:'C', null, :'IT') order by 1, 2;
\echo == out with a batch that has no qty (expected ERROR)
insert into stock_docs (id, company_id, doc_type, doc_date, warehouse_id) values ('5d640000-0000-0000-0000-000000000004',:'C','out','2026-04-03',:'wh2');
insert into stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost, batch_no) values ('5d640000-0000-0000-0000-000000000004',1,:'IT',5,2,'A1');
select post_stock_doc('5d640000-0000-0000-0000-000000000004');
-- بيع بعد انتهاء B2 (رصيدها صفر أصلاً) — FEFO من A1
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,cash_account_id,warehouse_id) values
 ('20000000-0000-0000-0000-000000000641',:'C',:'F','sale','2026-07-02','cash',(select id from accounts where company_id=:'C' and code='1101'),:'wh');
insert into invoice_lines(invoice_id,item_id,description,qty,unit_price,tax_rate) values ('20000000-0000-0000-0000-000000000641',:'IT','x',2,10,0);
select post_invoice_stock('20000000-0000-0000-0000-000000000641') is null as posted;
select batch_no, qty from batch_balances(:'C', :'wh', :'IT') order by batch_no;
\echo == unpost stock returns the batch
select unpost_invoice('20000000-0000-0000-0000-000000000641', 'stock') is null as unposted;
select batch_no, qty from batch_balances(:'C', :'wh', :'IT') order by batch_no;
-- منع بيع دفعة منتهية برقمها
update company_settings set block_expired_sale = true where company_id = :'C';
insert into stock_docs (id, company_id, doc_type, doc_date, warehouse_id) values ('5d640000-0000-0000-0000-000000000005',:'C','in','2026-03-05',:'wh');
insert into stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost, batch_no, expiry_date) values ('5d640000-0000-0000-0000-000000000005',1,:'IT',4,2,'OLD','2026-05-01');
select post_stock_doc('5d640000-0000-0000-0000-000000000005');
update invoice_lines set batch_no = 'OLD' where invoice_id = '20000000-0000-0000-0000-000000000641';
\echo == sell expired batch (expected ERROR)
select post_invoice_stock('20000000-0000-0000-0000-000000000641');
update company_settings set block_expired_sale = false where company_id = :'C';
select post_invoice_stock('20000000-0000-0000-0000-000000000641') is null as posted_old;
select batch_no, qty from batch_balances(:'C', :'wh', :'IT') order by batch_no;
select count(*) as history_rows from batch_history((select id from item_batches where company_id = :'C' and item_id = :'IT' and batch_no = 'A1'));
\echo == user cannot write batch_moves (expected ERROR)
insert into batch_moves (company_id,item_id,warehouse_id,move_date,qty,source_type,source_id) values (:'C',:'IT',:'wh','2026-01-01',100,'x',gen_random_uuid());
\echo == internal helpers not callable (expected ERROR)
select batch_sync('stock_doc', '5d640000-0000-0000-0000-000000000001');
-- تعديل تاريخ الانتهاء مسموح، ورقم الدفعة ما بيتغيّر
update item_batches set expiry_date = '2027-01-31', batch_no = 'ZZ' where company_id = :'C' and item_id = :'IT' and batch_no = 'A1' returning batch_no, expiry_date;
reset role;
\echo == employee with inventory view: read only
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select count(*) from batch_moves;
select count(*) from batch_history((select id from item_batches where batch_no = 'A1' limit 1));
reset role;
-- بعد المراجعة: إلغاء ترحيل إدخال طلع من دفعته ممنوع، وتاريخ انتهاء مختلف لنفس الدفعة ممنوع
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\echo == unpost inbound after its batch was sold (expected ERROR)
select unpost_stock_doc('5d640000-0000-0000-0000-000000000005', 'stock');
insert into stock_docs (id, company_id, doc_type, doc_date, warehouse_id) values ('5d640000-0000-0000-0000-000000000006',:'C','in','2026-03-06',:'wh');
insert into stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost, batch_no, expiry_date) values ('5d640000-0000-0000-0000-000000000006',1,:'IT',1,2,'A1','2028-01-01');
\echo == same batch with a different expiry (expected ERROR)
select post_stock_doc('5d640000-0000-0000-0000-000000000006');
reset role;
\echo == cross-company batch move (expected ERROR)
insert into batch_moves (company_id,item_id,warehouse_id,move_date,qty,source_type,source_id) values (gen_random_uuid(),'10000000-0000-0000-0000-000000000064',(select id from warehouses limit 1),'2026-01-01',1,'x',gen_random_uuid());
