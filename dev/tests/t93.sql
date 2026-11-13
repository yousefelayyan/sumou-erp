\set ON_ERROR_STOP 0
-- موقع العميل والتحقق من الزيارة ومسافات المندوب والطابور بدون إنترنت (المرحلة 93)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
select geo_dist_m(31.95, 35.91, 31.96, 35.91) between 1100 and 1120 as dist_ok;
reset role; update sales_visits set status = 'cancelled' where company_id = 'c0000000-0000-0000-0000-000000000001' and status = 'open'; set role authenticated;
\echo == bad radius (expected ERROR)
select rep_geo_save(:'C', '{"mode":"block","radius":5}');
select rep_geo_save(:'C', '{"mode":"block","radius":300,"learn":true,"km_rate":0.1}');
-- عميل بدون موقع: أول زيارة بتحفظ موقعه
update parties set geo_lat = null, geo_lng = null where company_id = :'C' and code = (select min(code) from parties where company_id = :'C' and party_type = 'customer' and is_active);
select visit_start(:'C', (select id from parties where company_id = :'C' and party_type = 'customer' and is_active order by code limit 1), 31.950000, 35.910000) is not null as v1;
select geo_lat = 31.95 as learned from parties where company_id = :'C' and party_type = 'customer' and is_active order by code limit 1;
select offline_sync(:'C', 'ref-end-0001', 'visit_end', jsonb_build_object('visit_id', (select id from sales_visits where company_id = :'C' and status = 'open' limit 1), 'lat', 31.95, 'lng', 35.91, 'ended_at', '2000-01-01')) ->> 'ok' as ended;
select ended_at >= started_at as end_clamped from sales_visits where company_id = :'C' and user_id = auth.uid() and status = 'closed' order by started_at desc limit 1;
-- المدير (مشرف) بيبلّش بعيد بس بتنعلّم
select visit_start(:'C', (select id from parties where company_id = :'C' and party_type = 'customer' and is_active order by code limit 1), 31.960000, 35.910000) is not null as far_sup;
select geo_ok = false and distance_m > 1000 as flagged from sales_visits where company_id = :'C' and status = 'open';
select offline_sync(:'C', 'ref-end-0002', 'visit_end', jsonb_build_object('visit_id', (select id from sales_visits where company_id = :'C' and status = 'open' limit 1))) ->> 'ok' as ended2;
select offline_sync(:'C', 'ref-end-0002', 'visit_end', '{}') ->> 'duplicate' as dup;
select sum(km) > 1 as km_ok, sum(allowance) > 0.1 as allowance_ok, sum(far_visits) = 1 as far_ok from rep_km_report(:'C', local_today() - 1, local_today() + 1);
\echo == bad op (expected ERROR)
select offline_sync(:'C', 'ref-xxxx-0003', 'hack', '{}');
-- الموظف بدون صلاحية مشرف وبعيد
reset role;
update user_groups set permissions = permissions || '{"rep_visits":{"view":true,"add":true}}' where id = (select group_id from user_companies where user_id = '22222222-2222-2222-2222-222222222222' and company_id = 'c0000000-0000-0000-0000-000000000001');
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
\echo == far from customer (expected ERROR)
select visit_start(:'C', (select id from parties where company_id = :'C' and party_type = 'customer' and is_active order by code limit 1), 32.050000, 35.910000);
\echo == no location (expected ERROR)
select visit_start(:'C', (select id from parties where company_id = :'C' and party_type = 'customer' and is_active order by code limit 1));
select visit_start(:'C', (select id from parties where company_id = :'C' and party_type = 'customer' and is_active order by code limit 1), 31.951000, 35.910000) is not null as near_ok;
select count(*) as own_rows from rep_km_report(:'C', local_today() - 1, local_today() + 1);
\echo == employee saves settings (expected ERROR)
select rep_geo_save(:'C', '{"mode":"none"}');
select visit_cancel((select id from sales_visits where company_id = :'C' and status = 'open' and user_id = auth.uid()));
reset role;
update company_settings set rep_geo = '{}' where company_id = 'c0000000-0000-0000-0000-000000000001';
