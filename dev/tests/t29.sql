\set ON_ERROR_STOP 0
-- المرحلة 29: نقاط البيع
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set item `psql -h /tmp -p 5433 -U postgres -Atqc "select id from items where company_id='c0000000-0000-0000-0000-000000000001' and is_active and item_type='goods' order by code limit 1"`
\set fy f0000000-0000-0000-0000-000000000001
select count(*) as cashier_group from user_groups where name='كاشير';
\echo == empty cart / wrong year (expected ERROR)
select pos_checkout(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','fiscal_year_id',:'fy','lines','[]'::jsonb));
select pos_checkout(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','fiscal_year_id',gen_random_uuid(),'lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',1))));
\echo == make an open year containing today
reset role;
insert into fiscal_years(id,company_id,code,start_date,end_date) select 'f0000000-0000-0000-0000-0000000000a9','c0000000-0000-0000-0000-000000000001','POS',date_trunc('year',current_date)::date,(date_trunc('year',current_date)+interval '1 year - 1 day')::date
 where not exists (select 1 from fiscal_years where company_id='c0000000-0000-0000-0000-000000000001' and current_date between start_date and end_date);
\set fy2 `psql -h /tmp -p 5433 -U postgres -Atqc "select id from fiscal_years where company_id='c0000000-0000-0000-0000-000000000001' and current_date between start_date and end_date and not is_closed limit 1"`
update items set sale_price = 11.6, tax_rate = 16, image = 'data:image/jpeg;base64,AAAA' where id = :'item';
set role authenticated;
\echo == bad image (expected ERROR)
update items set image = 'javascript:alert(1)' where id = :'item';
select (pos_checkout(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','fiscal_year_id',:'fy2','method','cash','paid',30,
   'lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',2))))) ->> 'total' as total;
select inv_type, payment_type, status, pos, pos_paid, total, subtotal, tax_total, entry_id is not null as has_entry from invoices where pos order by created_at desc limit 1;
\echo == price override by admin is allowed
select (pos_checkout(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','fiscal_year_id',:'fy2','method','card',
   'lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',1,'price',5.8))))) ->> 'total' as total_override;
\echo == cashier (pos rights only): price override ignored
reset role;
insert into user_companies(user_id,company_id,group_id) values ('22222222-2222-2222-2222-222222222222','c0000000-0000-0000-0000-000000000001',(select id from user_groups where name='كاشير' and tenant_id=(select tenant_id from profiles where id='22222222-2222-2222-2222-222222222222')))
  on conflict (user_id, company_id) do update set group_id = excluded.group_id;
update profiles set is_active = true where id='22222222-2222-2222-2222-222222222222';
update profiles set permissions='{}' where id='22222222-2222-2222-2222-222222222222';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select (pos_checkout(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','fiscal_year_id',:'fy2',
   'lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',1,'price',0.001,'discount',5))))) ->> 'total' as cashier_total;
\echo == cashier cannot set pos_only on self
update profiles set pos_only = false, is_admin = true where id = auth.uid();
reset role; select pos_only, is_admin from profiles where id='22222222-2222-2222-2222-222222222222';
\echo == admin sets pos_only
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
update profiles set pos_only = true where id='22222222-2222-2222-2222-222222222222';
select pos_only from profiles where id='22222222-2222-2222-2222-222222222222';
\echo == user without pos permission (expected ERROR)
reset role; update user_companies set group_id = null where user_id='22222222-2222-2222-2222-222222222222' and company_id='c0000000-0000-0000-0000-000000000001';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select pos_checkout(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','fiscal_year_id',:'fy2','lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',1))));
reset role; update profiles set pos_only=false where id='22222222-2222-2222-2222-222222222222';

-- ===== review fixes
reset role;
insert into user_companies(user_id,company_id,group_id) values ('22222222-2222-2222-2222-222222222222','c0000000-0000-0000-0000-000000000001',(select id from user_groups where name='كاشير' and tenant_id=(select tenant_id from profiles where id='22222222-2222-2222-2222-222222222222')))
  on conflict (user_id, company_id) do update set group_id = excluded.group_id;
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
\echo == cashier cannot insert invoices directly (expected ERROR)
insert into invoices(company_id,fiscal_year_id,inv_type,inv_date,payment_type,cash_account_id) values ('c0000000-0000-0000-0000-000000000001',:'fy2','sale_return',current_date,'cash',null);
\echo == cashier: paid less than total (expected ERROR)
select pos_checkout(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','fiscal_year_id',:'fy2','paid',1,'lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',1))));
\echo == cashier: bad uuid (expected ERROR)
select pos_checkout(jsonb_build_object('company_id','x','lines','[1]'::jsonb));
select (pos_checkout(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','fiscal_year_id',:'fy2','paid',20,'lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',1))))) - 'created_at' - 'id' - 'no' - 'doc_code' as cashier_sale;
\echo == cashier cannot cancel (expected ERROR)
select cancel_invoice((select id from invoices where pos order by created_at desc limit 1));
\echo == admin: pos flag on normal invoice is ignored; foreign warehouse rejected
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into invoices(company_id,fiscal_year_id,inv_type,inv_date,payment_type,party_name,pos,pos_paid) values ('c0000000-0000-0000-0000-000000000001',:'fy2','sale',current_date,'credit','x',true,999) returning pos, pos_paid;
reset role;
\set otherwh `psql -h /tmp -p 5433 -U postgres -Atqc "select id from warehouses where company_id <> 'c0000000-0000-0000-0000-000000000001' limit 1"`
set role authenticated;
\echo == foreign warehouse (expected ERROR if another company exists)
insert into invoices(company_id,fiscal_year_id,inv_type,inv_date,payment_type,party_name,warehouse_id) values ('c0000000-0000-0000-0000-000000000001',:'fy2','sale',current_date,'credit','x',nullif(:'otherwh','')::uuid);
\echo == revenue account as card account (expected ERROR)
reset role;
update company_settings set pos = jsonb_build_object('card_account_id',(select id from accounts where company_id='c0000000-0000-0000-0000-000000000001' and category='revenue' and not is_group limit 1)) where company_id='c0000000-0000-0000-0000-000000000001';
set role authenticated;
select pos_checkout(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','fiscal_year_id',:'fy2','method','card','lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',1))));
reset role; update company_settings set pos='{}' where company_id='c0000000-0000-0000-0000-000000000001';
\echo == admin cannot set pos_only on self
set role authenticated;
update profiles set pos_only = true where id = auth.uid();
select pos_only from profiles where id = auth.uid();
reset role;

-- ===== payment methods at POS
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into lookups(company_id,kind,code,name,name2,pos_label,account_id,use_pos) values ('c0000000-0000-0000-0000-000000000001','payment_method','POS1','كليك','CliQ','📱 كليك',(select id from accounts where company_id='c0000000-0000-0000-0000-000000000001' and account_type='bank' and not is_group limit 1),true);
insert into lookups(company_id,kind,code,name,account_id,use_pos) values ('c0000000-0000-0000-0000-000000000001','payment_method','POS2','مش للكاشير',(select id from accounts where company_id='c0000000-0000-0000-0000-000000000001' and account_type='bank' and not is_group limit 1),false);
select (r ->> 'method') as method, (r ->> 'paid')::numeric = (r ->> 'total')::numeric as paid_eq_total from (select pos_checkout(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','fiscal_year_id',:'fy2','method_id',(select id from lookups where code='POS1'),'paid',999,'lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',1)))) r) x;
select i.cash_account_id = l.account_id as debit_is_method_acc from invoices i join lookups l on l.id = i.pos_method_id where i.pos order by i.created_at desc limit 1;
\echo == method not enabled for POS (expected ERROR)
select pos_checkout(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','fiscal_year_id',:'fy2','method_id',(select id from lookups where code='POS2'),'lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',1))));
reset role;

-- ===== credit, invoice discount, sales rep
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set cust `psql -h /tmp -p 5433 -U postgres -Atqc "select id from parties where company_id='c0000000-0000-0000-0000-000000000001' and party_type='customer' and is_active order by code limit 1"`
\echo == credit without customer (expected ERROR)
select pos_checkout(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','fiscal_year_id',:'fy2','method','credit','lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',1))));
select r ->> 'method' as m, (r ->> 'paid')::numeric as paid, (r ->> 'total')::numeric as total, (r ->> 'discount')::numeric as disc
  from (select pos_checkout(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','fiscal_year_id',:'fy2','method','credit','party_id',:'cust','discount',3.2,
       'lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',2)))) r) x;
select payment_type, party_id = :'cust' as cust_ok, cash_account_id is null as no_cash, status, total from invoices where pos order by created_at desc limit 1;
\echo == discount bigger than total (expected ERROR)
select pos_checkout(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','fiscal_year_id',:'fy2','discount',999,'lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',1))));
reset role;
insert into lookups(company_id,kind,code,name,rate) values ('c0000000-0000-0000-0000-000000000001','sales_rep','RP9','فراس',1) on conflict do nothing;
set role authenticated;
select (pos_checkout(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','fiscal_year_id',:'fy2','sales_rep_id',(select id from lookups where code='RP9'),'lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',1))))) is not null as with_rep;
select l.name as rep from invoices i join lookups l on l.id = i.sales_rep_id where i.pos order by i.created_at desc limit 1;
\echo == cashier discount without pos edit (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select pos_checkout(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','fiscal_year_id',:'fy2','discount',1,'lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',1))));
reset role;
