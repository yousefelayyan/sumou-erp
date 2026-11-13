-- زبائني: ربط المندوب بالمستخدم وأيام المسار
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into lookups (company_id, kind, code, name, user_id) values ('c0000000-0000-0000-0000-000000000001','sales_rep','R43','مندوب 43','11111111-1111-1111-1111-111111111111') on conflict do nothing;
insert into lookups (company_id, kind, code, name, weekdays) values ('c0000000-0000-0000-0000-000000000001','route','RT43','مسار 43','{0,2}') on conflict do nothing;
\echo == bad weekday (expected ERROR)
insert into lookups (company_id, kind, code, name, weekdays) values ('c0000000-0000-0000-0000-000000000001','route','RT44','x','{9}');
update parties set sales_rep_id = (select id from lookups where code = 'R43'), route_id = (select id from lookups where code = 'RT43')
 where id = (select id from parties where company_id = 'c0000000-0000-0000-0000-000000000001' and party_type = 'customer' order by code limit 1);
select (d ->> 'customers')::int as customers, (d ->> 'has_rep')::boolean as has_rep from (select rep_customers_dash('c0000000-0000-0000-0000-000000000001','2026-01-01','2026-12-31') d) x;
select (d ->> 'customers')::int as day0 from (select rep_customers_dash('c0000000-0000-0000-0000-000000000001','2026-01-01','2026-12-31', null, 0) d) x;
select (d ->> 'customers')::int as day1 from (select rep_customers_dash('c0000000-0000-0000-0000-000000000001','2026-01-01','2026-12-31', null, 1) d) x;
select (d ->> 'customers')::int >= 1 as all_reps from (select rep_customers_dash('c0000000-0000-0000-0000-000000000001','2026-01-01','2026-12-31', null, null, true) d) x;
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
\echo == employee without rights (expected ERROR)
select rep_customers_dash('c0000000-0000-0000-0000-000000000001','2026-01-01','2026-12-31');
reset role;
