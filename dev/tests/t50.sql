-- قوائم الأسعار وضوابط السعر
\set ON_ERROR_STOP 0
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into items(id,company_id,code,name,sale_price,min_price,max_discount_pct) values ('50000000-0000-0000-0000-0000000000a1',:'C','P50','صنف 50',20,15,10) on conflict do nothing;
insert into price_lists(id,company_id,code,name) values ('50000000-0000-0000-0000-0000000000b1',:'C','VIP','جملة') on conflict do nothing;
insert into price_list_items(list_id,item_id,price) values ('50000000-0000-0000-0000-0000000000b1','50000000-0000-0000-0000-0000000000a1',17) on conflict do nothing;
update parties set price_list_id = '50000000-0000-0000-0000-0000000000b1' where id = (select id from parties where company_id = :'C' and party_type = 'customer' order by code limit 1);
select count(*) as prices from party_item_prices(:'C', (select id from parties where company_id = :'C' and party_type = 'customer' order by code limit 1));
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,party_name) values ('50000000-0000-0000-0000-0000000000c1',:'C',:'F','sale','2026-05-01','cash','x');
reset role;
update user_groups set permissions = permissions || '{"sales_invoices":{"view":true,"add":true,"edit":true}}' where id = (select group_id from user_companies where user_id = '22222222-2222-2222-2222-222222222222' and company_id = :'C');
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
\echo == below min price (expected ERROR)
insert into invoice_lines(invoice_id,item_id,description,qty,unit_price,tax_rate) values ('50000000-0000-0000-0000-0000000000c1','50000000-0000-0000-0000-0000000000a1','x',1,14,0);
\echo == discount over max (expected ERROR)
insert into invoice_lines(invoice_id,item_id,description,qty,unit_price,discount,tax_rate) values ('50000000-0000-0000-0000-0000000000c1','50000000-0000-0000-0000-0000000000a1','x',1,20,3,0);
insert into invoice_lines(invoice_id,item_id,description,qty,unit_price,discount,tax_rate) values ('50000000-0000-0000-0000-0000000000c1','50000000-0000-0000-0000-0000000000a1','x',1,20,2,0);
select count(*) as ok_lines from invoice_lines where invoice_id = '50000000-0000-0000-0000-0000000000c1';
\echo == employee writes price list (expected ERROR)
insert into price_lists(company_id,code,name) values (:'C','X','x');
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into invoice_lines(invoice_id,item_id,description,qty,unit_price,tax_rate) values ('50000000-0000-0000-0000-0000000000c1','50000000-0000-0000-0000-0000000000a1','admin',1,10,0);
select count(*) as admin_line from invoice_lines where invoice_id = '50000000-0000-0000-0000-0000000000c1' and description = 'admin';
delete from invoices where id = '50000000-0000-0000-0000-0000000000c1';
reset role;
