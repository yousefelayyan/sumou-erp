set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select ensure_company_settings('c0000000-0000-0000-0000-000000000001');
insert into items(id,company_id,code,name,sale_price) values ('10000000-0000-0000-0000-0000000000b1','c0000000-0000-0000-0000-000000000001','G1','كرتونة ماء',2);
-- purchase 100 @1.5
insert into parties(company_id,party_type,code,name,account_id) select 'c0000000-0000-0000-0000-000000000001','supplier','','مورد', id from accounts where code='2101';
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,party_id) values ('20000000-0000-0000-0000-0000000000b1','c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','purchase','2026-03-01','credit',(select id from parties where party_type='supplier'));
update invoices set party_id=(select id from parties where party_type='supplier') where id='20000000-0000-0000-0000-0000000000b1';
insert into invoice_lines(invoice_id,item_id,description,qty,unit_price,tax_rate) values ('20000000-0000-0000-0000-0000000000b1','10000000-0000-0000-0000-0000000000b1','ماء',100,1.5,16);
select post_invoice('20000000-0000-0000-0000-0000000000b1') is not null;
select post_invoice_stock('20000000-0000-0000-0000-0000000000b1') is null;
-- sale 30
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,cash_account_id) values ('20000000-0000-0000-0000-0000000000b2','c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','sale','2026-03-05','cash',(select id from accounts where code='1101'));
insert into invoice_lines(invoice_id,item_id,description,qty,unit_price,tax_rate) values ('20000000-0000-0000-0000-0000000000b2','10000000-0000-0000-0000-0000000000b1','ماء',30,2,16);
select post_invoice('20000000-0000-0000-0000-0000000000b2') is not null;
select post_invoice_stock('20000000-0000-0000-0000-0000000000b2') is null;
-- count: actual 65
insert into stock_docs(id,company_id,doc_type,doc_date,warehouse_id) values ('30000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000001','count','2026-03-10',(select id from warehouses limit 1));
insert into stock_doc_lines(doc_id,item_id,counted_qty) values ('30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-0000000000b1',65);
select post_stock_doc('30000000-0000-0000-0000-000000000001');
select * from rep_stock_balance('c0000000-0000-0000-0000-000000000001','2026-12-31');
select qty, description from rep_item_card('c0000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-0000000000b1','2026-01-01','2026-12-31');
select cancel_invoice('20000000-0000-0000-0000-0000000000b2','2026-03-11');
select qty from rep_stock_balance('c0000000-0000-0000-0000-000000000001','2026-12-31');
update stock_docs set notes='x' where id='30000000-0000-0000-0000-000000000001';
