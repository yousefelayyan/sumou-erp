\set ON_ERROR_STOP 0
-- فحص الطلبات والعروض والولاء والحقول الإضافية (المرحلة 25)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
insert into orders(id,company_id,order_type,party_id) values ('0d000000-0000-0000-0000-000000000001',:'C','sales_order',(select id from parties where company_id=:'C' and party_type='customer' limit 1)) returning order_no, status;
insert into orders(company_id,order_type,status) values (:'C','sales_order','converted') returning order_no, status as forced_open;
insert into order_lines(order_id,item_id,qty,unit_price,tax_rate) values ('0d000000-0000-0000-0000-000000000001',(select id from items where company_id=:'C' limit 1),2,50,16);
select subtotal, tax_total, total from orders where id='0d000000-0000-0000-0000-000000000001';
\echo == supplier on a sales order (expected ERROR)
update orders set party_id=(select id from parties where company_id=:'C' and party_type='supplier' limit 1) where id='0d000000-0000-0000-0000-000000000001';
\echo == convert: link a sale invoice
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,party_id) values ('0d000000-0000-0000-0000-0000000000aa',:'C',:'F','sale','2026-08-01','credit',(select party_id from orders where id='0d000000-0000-0000-0000-000000000001'));
update orders set invoice_id='0d000000-0000-0000-0000-0000000000aa' where id='0d000000-0000-0000-0000-000000000001' returning status;
\echo == converted order lines locked (expected ERROR)
insert into order_lines(order_id,qty,unit_price) values ('0d000000-0000-0000-0000-000000000001',1,1);
\echo == deleting the draft invoice reopens the order
delete from invoices where id='0d000000-0000-0000-0000-0000000000aa';
select status, invoice_id from orders where id='0d000000-0000-0000-0000-000000000001';
\echo == purchase invoice on sales order (expected ERROR)
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,party_id) values ('0d000000-0000-0000-0000-0000000000bb',:'C',:'F','purchase','2026-08-01','credit',(select id from parties where company_id=:'C' and party_type='supplier' limit 1));
update orders set invoice_id='0d000000-0000-0000-0000-0000000000bb' where id='0d000000-0000-0000-0000-000000000001';
\echo == employee without sales_orders cannot see orders
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select count(*) as visible from orders;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\echo == promotion
insert into promotions(company_id,name,date_from,date_to,discount_pct) values (:'C','عرض','2026-01-01','2026-12-31',10) returning discount_pct;
\echo == bad promotion (expected ERROR)
insert into promotions(company_id,name,date_from,date_to,discount_pct) values (:'C','غلط','2026-02-01','2026-01-01',10);
\echo == loyalty
insert into lookups(id,company_id,kind,code,name,rate) values ('1c000000-0000-0000-0000-000000000099',:'C','loyalty_type','01','فضية',1) returning kind;
update parties set loyalty_type_id='1c000000-0000-0000-0000-000000000099', loyalty_card_no='S1' where id=(select party_id from orders where id='0d000000-0000-0000-0000-000000000001') returning loyalty_card_no;
\echo == negative redeemed (expected ERROR)
update parties set loyalty_redeemed=-5 where loyalty_card_no='S1';
\echo == custom field
insert into custom_fields(company_id,entity,key,label,field_type) values (:'C','customer','license_end','انتهاء الرخصة','date') returning key;
\echo == bad key (expected ERROR)
insert into custom_fields(company_id,entity,key,label) values (:'C','customer','Bad Key','x');
update parties set extra='{"license_end":"2027-01-01"}' where loyalty_card_no='S1' returning extra;
reset role;
\echo == fixes: view-only employee cannot delete lines; totals not writable; cancelled cannot reopen
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
update orders set total=999999 where id='0d000000-0000-0000-0000-000000000001' returning total;
update orders set status='converted' where id='0d000000-0000-0000-0000-000000000001' returning status as stays_open;
\echo == link via rpc
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,party_id) values ('0d000000-0000-0000-0000-0000000000cc','c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','sale','2026-08-02','credit',(select party_id from orders where id='0d000000-0000-0000-0000-000000000001'));
select link_order_invoice('0d000000-0000-0000-0000-000000000001','0d000000-0000-0000-0000-0000000000cc');
\echo == link twice (expected ERROR)
select link_order_invoice('0d000000-0000-0000-0000-000000000001','0d000000-0000-0000-0000-0000000000cc');
update orders set party_name='تغيير', notes='ملاحظة' where id='0d000000-0000-0000-0000-000000000001' returning party_name is null as name_kept, notes;
update orders set status='cancelled' where order_no=2 and company_id='c0000000-0000-0000-0000-000000000001';
update orders set status='open' where order_no=2 and company_id='c0000000-0000-0000-0000-000000000001' returning status as stays_cancelled;
reset role;
