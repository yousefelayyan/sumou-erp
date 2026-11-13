\set ON_ERROR_STOP 0
-- ملخص نهاية اليوم وإغلاق الصندوق (المرحلة 83) — بيعتمد على t29 (سنة فيها اليوم وفواتير كاشير)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set item `psql -h /tmp -p 5433 -U postgres -Atqc "select id from items where company_id='c0000000-0000-0000-0000-000000000001' and is_active and item_type='goods' order by code limit 1"`
\set fy2 `psql -h /tmp -p 5433 -U postgres -Atqc "select id from fiscal_years where company_id='c0000000-0000-0000-0000-000000000001' and current_date between start_date and end_date and not is_closed limit 1"`
select (pos_checkout(jsonb_build_object('company_id',:'C','fiscal_year_id',:'fy2','method','cash','paid',100,'lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',1))))) ->> 'total' is not null as sold;
with s as (select x from jsonb_array_elements(pos_day_summary(:'C', local_today())) x where x ->> 'user_id' = '11111111-1111-1111-1111-111111111111')
select (x ->> 'invoices')::int > 0 as has_inv, (x ->> 'expected_cash')::numeric > 0 as has_cash, jsonb_array_length(x -> 'methods') > 0 as has_methods,
  (x ->> 'total')::numeric = (select sum(total) from invoices where company_id = :'C' and pos and status = 'posted' and inv_date = local_today() and created_by = '11111111-1111-1111-1111-111111111111') as total_ok from s;
\echo == negative counted (expected ERROR)
select pos_close_day(:'C', local_today(), -1);
select pos_close_day(:'C', local_today(), 50, 'نقص') is not null as closed;
select counted_cash, difference = counted_cash - expected_cash as diff_ok from pos_closings where company_id = :'C' and day = local_today();
\echo == close twice (expected ERROR)
select pos_close_day(:'C', local_today(), 50);
\echo == sell after closing (expected ERROR)
select pos_checkout(jsonb_build_object('company_id',:'C','fiscal_year_id',:'fy2','method','cash','paid',100,'lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',1))));
\echo == direct insert into closings (expected ERROR)
insert into pos_closings (company_id, cashier_id, day) values (:'C', auth.uid(), current_date - 1);
\echo == no rights (expected ERROR)
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false) \g /dev/null
select pos_day_summary(:'C', local_today());
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select pos_reopen_day(id) from pos_closings where company_id = :'C' and day = local_today() \g /dev/null
select (pos_checkout(jsonb_build_object('company_id',:'C','fiscal_year_id',:'fy2','method','cash','paid',100,'lines',jsonb_build_array(jsonb_build_object('item_id',:'item','qty',1))))) ->> 'total' is not null as sold_after_reopen;
reset role;
