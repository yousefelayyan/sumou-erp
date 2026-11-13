-- منع البيع بالسالب وتجاهل تتبع الكمية
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\echo == bad ignore kind (expected ERROR)
update items set qty_check_ignore = '{bogus}' where company_id = 'c0000000-0000-0000-0000-000000000001';
insert into items (company_id, code, name, item_type, unit, sale_price, tax_rate) values ('c0000000-0000-0000-0000-000000000001','Q45','صنف 45','goods','حبة',10,16) on conflict do nothing;
select id as it from items where company_id = 'c0000000-0000-0000-0000-000000000001' and code = 'Q45' \gset
select id as wh from warehouses where company_id = 'c0000000-0000-0000-0000-000000000001' order by code limit 1 \gset
update company_settings set block_negative_stock = true where company_id = 'c0000000-0000-0000-0000-000000000001';
insert into stock_docs (id, company_id, doc_type, doc_date, warehouse_id) values ('5d450000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000001','out','2026-04-01',:'wh');
insert into stock_doc_lines (doc_id, line_no, item_id, qty) values ('5d450000-0000-0000-0000-000000000001',1,:'it',3);
\echo == out without stock (expected ERROR)
select post_stock_doc('5d450000-0000-0000-0000-000000000001');
update items set qty_check_ignore = '{stock_out}' where id = :'it';
select post_stock_doc('5d450000-0000-0000-0000-000000000001');
select status from stock_docs where id = '5d450000-0000-0000-0000-000000000001';
reset role;
update company_settings set block_negative_stock = false where company_id = 'c0000000-0000-0000-0000-000000000001';
