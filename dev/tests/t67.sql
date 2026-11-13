\set ON_ERROR_STOP 0
-- حقول الطلب الإضافية ونوع الضريبة (المرحلة 67)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
insert into orders (company_id, order_type, order_date, tax_mode, discount_pct, delivered, closed) values (:'C', 'sales_order', current_date, 'zero', 5, true, true) returning tax_mode, discount_pct, delivered as forced_false, closed as forced_closed_false \gset
select :'tax_mode' as tax_mode, :'forced_false' as delivered, :'forced_closed_false' as closed;
select id as o from orders where company_id = :'C' and order_type = 'sales_order' order by created_at desc limit 1 \gset
\echo == bad tax mode (expected ERROR)
update orders set tax_mode = 'xx' where id = :'o';
\echo == direct delivered ignored
update orders set delivered = true where id = :'o' returning delivered;
select order_set_flags(:'o', '{"delivered": true, "closed": true}');
select delivered, delivered_date is not null as has_date, closed from orders where id = :'o';
select order_set_flags(:'o', '{"delivered": false}');
select delivered, delivered_date from orders where id = :'o';
\echo == payment method from nowhere (expected ERROR)
update orders set payment_method_id = gen_random_uuid() where id = :'o';
update invoices set tax_mode = 'exempt' where company_id = :'C' and status = 'draft' and id = (select id from invoices where company_id = :'C' and status = 'draft' limit 1) returning tax_mode;
reset role;
\echo == employee flags (expected ERROR if no edit)
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select order_set_flags((select id from orders where company_id = 'c0000000-0000-0000-0000-000000000001' and order_type = 'purchase_order' limit 1), '{"closed": true}');
reset role;
