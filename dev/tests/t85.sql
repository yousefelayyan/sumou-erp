\set ON_ERROR_STOP 0
-- حجز الكميات بطلبات المبيعات (المرحلة 85)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
select id as item from items where company_id=:'C' and is_active and item_type='goods' and track_stock order by code limit 1 \gset
select available as av0, reserved as r0 from items_available(:'C', null, local_today(), array[:'item']::uuid[]) \gset
insert into orders(company_id,order_type,party_id,reserve) values (:'C','sales_order',(select id from parties where company_id=:'C' and party_type='customer' limit 1),true) returning id as o1 \gset
insert into order_lines(order_id,line_no,item_id,description,qty,unit_price) values (:'o1',1,:'item','حجز',7,1);
insert into orders(company_id,order_type,party_id,reserve) values (:'C','sales_order',(select id from parties where company_id=:'C' and party_type='customer' limit 1),false) returning id as o2 \gset
insert into order_lines(order_id,line_no,item_id,description,qty,unit_price) values (:'o2',1,:'item','بدون حجز',100,1);
\echo == reserved = 7 and free = available - 7
select reserved - :r0 as added_reserved, free = available - reserved as free_ok, available = :av0 as available_same from items_available(:'C', null, local_today(), array[:'item']::uuid[]);
select reserved >= 7 as in_report from items_reservations(:'C') where item_id = :'item';
\echo == expired order stops reserving
update orders set valid_until = local_today() - 1 where id = :'o1';
select reserved - :r0 as after_expiry from items_available(:'C', null, local_today(), array[:'item']::uuid[]);
\echo == purchase order cannot reserve
insert into orders(company_id,order_type,reserve) values (:'C','purchase_order',true) returning reserve;
\echo == warehouse from another company (expected ERROR)
update orders set warehouse_id = gen_random_uuid() where id = :'o1';
delete from orders where id in (:'o1', :'o2');
delete from orders where order_type = 'purchase_order' and reserve = false and party_id is null and created_at > now() - interval '1 minute';
reset role;
