-- خصومات العملاء وتسوية الأرصدة الصغيرة
\set ON_ERROR_STOP 0
\set C 'c0000000-0000-0000-0000-000000000001'
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into discount_types(id,company_id,code,name,account_id) values ('51000000-0000-0000-0000-0000000000d1',:'C','01','خصم نقدي',(select id from accounts where company_id = :'C' and category = 'expenses' and not is_group order by code limit 1)) on conflict do nothing;
\echo == discount type on group account (expected ERROR)
insert into discount_types(company_id,code,name,account_id) values (:'C','02','x',(select id from accounts where company_id = :'C' and is_group limit 1));
select id as cust from parties where company_id = :'C' and party_type = 'customer' order by code offset 1 limit 1 \gset
select customer_discount(jsonb_build_object('company_id',:'C','date','2026-06-15','post',true,'lines',jsonb_build_array(jsonb_build_object('party_id',:'cust','discount_type_id','51000000-0000-0000-0000-0000000000d1','amount',0.5)))) as did \gset
select status, total from journal_entries where id = :'did';
select count(*) as preview from settle_small_balances(:'C','customer',0.001,1,'2026-06-20',false);
\echo == apply without settle account (expected ERROR)
select * from settle_small_balances(:'C','customer',0.001,1,'2026-06-20',true);
update company_settings set settle_account_id = (select id from accounts where company_id = :'C' and category = 'expenses' and not is_group order by code limit 1) where company_id = :'C';
select count(*) filter (where entry_id is not null) as applied from settle_small_balances(:'C','customer',0.001,1,'2026-06-20',true);
reset role;
update company_settings set settle_account_id = null where company_id = :'C';
