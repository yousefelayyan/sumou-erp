\set ON_ERROR_STOP 0
-- المرحلة 39: مراتب الولاء والاسترداد النقدي
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set cust `psql -h /tmp -p 5433 -U postgres -Atqc "select id from parties where company_id='c0000000-0000-0000-0000-000000000001' and party_type='customer' and is_active order by code limit 1"`
insert into loyalty_tiers(company_id,rank,name,min_spend,cashback_pct) values (:'C',1,'الأولى',0,1),(:'C',2,'الثانية',100,2),(:'C',3,'الثالثة',1000,3);
\echo == bad pct (expected ERROR)
insert into loyalty_tiers(company_id,rank,name,min_spend,cashback_pct) values (:'C',9,'غلط',0,80);
update parties set loyalty_type_id=(select id from lookups where company_id=:'C' and kind='loyalty_type' limit 1) where id=:'cust';
select tier_name, spend_12m > 0 as has_spend, earned > 0 as earned_ok, balance from loyalty_cashback(:'C', :'cust', '2026-12-31');
\echo == redeem without account (expected ERROR)
select loyalty_redeem(:'cust', 0.5, '2026-12-01');
update company_settings set cashback_account_id=(select id from accounts where company_id=:'C' and code='5203') where company_id=:'C';
\echo == redeem more than balance (expected ERROR)
select loyalty_redeem(:'cust', 999999, '2026-12-01');
select loyalty_redeem(:'cust', 0.5, '2026-12-01') is not null as redeemed;
select redeemed from loyalty_cashback(:'C', :'cust', '2026-12-31');
\echo == reverse redemption entry from vouchers (expected ERROR)
select reverse_entry((select entry_id from loyalty_redemptions limit 1));
select loyalty_redeem_cancel((select id from loyalty_redemptions limit 1), '2026-12-02');
select count(*) as left_red from loyalty_redemptions;
\echo == employee (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select loyalty_redeem(:'cust', 0.1, '2026-12-01');
reset role;
