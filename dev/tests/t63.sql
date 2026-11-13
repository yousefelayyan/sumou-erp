-- سجل أسعار الصنف للعميل/المورد
\set ON_ERROR_STOP 0
\set C 'c0000000-0000-0000-0000-000000000001'
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select i.party_id as cust, l.item_id as item from invoices i join invoice_lines l on l.invoice_id = i.id
 where i.company_id = :'C' and i.inv_type = 'sale' and i.status = 'posted' and l.item_id is not null and i.party_id is not null limit 1 \gset
select count(*) > 0 as has_last, bool_and(times >= 1) as times_ok, bool_and(min_price <= max_price) as range_ok from party_last_prices(:'C', :'cust', 'sale');
select count(*) > 0 as has_hist, bool_and(net_price >= 0) as net_ok from party_price_history(:'C', :'cust', :'item', 'sale', 10);
select last_price = (select net_price from party_price_history(:'C', :'cust', :'item', 'sale', 1)) as last_matches from party_last_prices(:'C', :'cust', 'sale') where item_id = :'item';
select count(*) as purchase_rows_for_customer from party_last_prices(:'C', :'cust', 'purchase');
select count(*) as null_item from party_price_history(:'C', :'cust', null, 'sale');
\echo == bad kind (expected ERROR)
select * from party_last_prices(:'C', :'cust', 'xx');
\echo == internal helper not callable (expected ERROR)
select * from price_hist_rows(:'C', :'cust', null, 'sale');
-- إعداد اعتماد آخر سعر
update company_settings set use_last_price = true where company_id = :'C';
select use_last_price from company_settings where company_id = :'C';
update company_settings set use_last_price = false where company_id = :'C';
reset role;
\echo == employee without sales view (expected ERROR if no permission)
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select count(*) >= 0 as emp_ok from party_last_prices(:'C', :'cust', 'purchase');
reset role;
