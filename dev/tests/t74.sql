\set ON_ERROR_STOP 0
-- البونص والعروض (المرحلة 74)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
select id as wh from warehouses where company_id = :'C' order by code limit 1 \gset
select id as su from parties where company_id = :'C' and party_type = 'supplier' and account_id is not null order by code limit 1 \gset
select id as cu from parties where company_id = :'C' and party_type = 'customer' and account_id is not null and not stop_credit order by code limit 1 \gset
insert into items (id, company_id, code, name, item_type, sale_price, purchase_price, tax_rate, min_price) values ('74000000-0000-0000-0000-0000000000b1', :'C', 'B74', 'صنف بونص 74', 'goods', 15, 10, 0, 12) on conflict do nothing;
-- شراء 10 بـ 10 + بونص 2 → الرصيد 12 والكلفة 100
insert into invoices (id, company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id, warehouse_id) values ('74000000-0000-0000-0000-0000000000a1', :'C', :'F', 'purchase', '2026-07-01', 'credit', :'su', :'wh');
insert into invoice_lines (invoice_id, line_no, item_id, qty, unit_price, tax_rate, subtotal, line_total) values ('74000000-0000-0000-0000-0000000000a1', 1, '74000000-0000-0000-0000-0000000000b1', 10, 10, 0, 100, 100);
insert into invoice_lines (invoice_id, line_no, item_id, qty, unit_price, discount, tax_rate, subtotal, line_total, is_bonus) values ('74000000-0000-0000-0000-0000000000a1', 2, '74000000-0000-0000-0000-0000000000b1', 2, 99, 5, 16, 99, 99, true);
select unit_price, discount, tax_rate, line_total from invoice_lines where invoice_id = '74000000-0000-0000-0000-0000000000a1' and is_bonus;
select post_invoice('74000000-0000-0000-0000-0000000000a1') is not null as gl, (select total from invoices where id = '74000000-0000-0000-0000-0000000000a1') as total;
select post_invoice_stock('74000000-0000-0000-0000-0000000000a1');
select sum(qty) as qty, round(sum(qty * unit_cost), 3) as value from stock_moves where item_id = '74000000-0000-0000-0000-0000000000b1';
-- بيع 5 بـ 15 + بونص 1 (السعر صفر أقل من أقل سعر بس مسموح للبونص) — الموظف بدون تجاوز
reset role;
update user_groups set permissions = (permissions - 'price_override') || '{"sales_invoices":{"view":true,"add":true,"edit":true,"post":true}}' where id = (select group_id from user_companies where user_id = '22222222-2222-2222-2222-222222222222' and company_id = :'C');
update user_companies set branch_only = false where user_id = '22222222-2222-2222-2222-222222222222';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
insert into invoices (id, company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id, warehouse_id) values ('74000000-0000-0000-0000-0000000000a2', :'C', :'F', 'sale', '2026-07-02', 'credit', :'cu', :'wh');
insert into invoice_lines (invoice_id, line_no, item_id, qty, unit_price, tax_rate, subtotal, line_total) values ('74000000-0000-0000-0000-0000000000a2', 1, '74000000-0000-0000-0000-0000000000b1', 5, 15, 0, 75, 75);
insert into invoice_lines (invoice_id, line_no, item_id, qty, tax_rate, is_bonus) values ('74000000-0000-0000-0000-0000000000a2', 2, '74000000-0000-0000-0000-0000000000b1', 1, 0, true) returning is_bonus as bonus_ok;
\echo == normal line at zero price below min (expected ERROR)
insert into invoice_lines (invoice_id, line_no, item_id, qty, unit_price, tax_rate) values ('74000000-0000-0000-0000-0000000000a2', 3, '74000000-0000-0000-0000-0000000000b1', 1, 0, 0);
select post_invoice('74000000-0000-0000-0000-0000000000a2') is not null as gl, (select total from invoices where id = '74000000-0000-0000-0000-0000000000a2') as total;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select post_invoice_stock('74000000-0000-0000-0000-0000000000a2');
reset role;
select sum(qty) as left_qty from stock_moves where item_id = '74000000-0000-0000-0000-0000000000b1';
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
-- عرض اشترِ 10 خذ 1
insert into promotions (company_id, name, date_from, date_to, item_id, discount_pct, buy_qty, free_qty) values (:'C', 'اشتر 10 خذ 1', '2026-01-01', '2026-12-31', '74000000-0000-0000-0000-0000000000b1', 0, 10, 1) returning free_qty;
\echo == promo without offer (expected ERROR)
insert into promotions (company_id, name, date_from, date_to, discount_pct) values (:'C', 'فاضي', '2026-01-01', '2026-12-31', 0);
reset role;
