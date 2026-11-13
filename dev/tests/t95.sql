\set ON_ERROR_STOP 0
-- نواقص الأقسام (المرحلة 95)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
\set fy2 `psql -h /tmp -p 5433 -U postgres -Atqc "select id from fiscal_years where company_id='c0000000-0000-0000-0000-000000000001' and current_date between start_date and end_date and not is_closed limit 1"`
-- 1) القيد المتكرر بينسخ الموظف
insert into journal_entries (id, company_id, fiscal_year_id, entry_type, entry_date, description) values ('e9500000-0000-0000-0000-000000000001', :'C', :'F', 'journal', '2026-01-05', 'سلفة متكررة');
insert into journal_lines (entry_id, line_no, account_id, debit, credit, employee_id) values
 ('e9500000-0000-0000-0000-000000000001', 1, (select id from accounts where company_id = :'C' and not is_group and category = 'assets' order by code desc limit 1), 10, 0, (select id from employees where company_id = :'C' order by code limit 1)),
 ('e9500000-0000-0000-0000-000000000001', 2, (select id from accounts where company_id = :'C' and code = '1101'), 0, 10, null);
insert into recurring_entries (company_id, source_entry_id, title, every_months, day_of_month, next_date, end_date) values (:'C', 'e9500000-0000-0000-0000-000000000001', 't95', 1, 5, '2026-02-05', '2026-02-28');
select run_recurring(:'C', '2026-02-28') >= 1 as ran;
select count(*) = 1 as emp_copied from journal_lines l join journal_entries e on e.id = l.entry_id where e.description like 'سلفة متكررة (متكرر 02/2026)%' and l.employee_id is not null;
-- 2) اسأل السمو بمندوب السطر
select count(*) >= 0 as ask_ok from ask_sales(:'C', '2026-01-01', '2026-12-31', 'rep');
-- 3) المناوبة الليلية
reset role;
insert into work_shifts (id, company_id, code, name, start_time, end_time) values ('a9500000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'N95', 'ليلي', '22:00', '06:00') on conflict do nothing;
update employees set shift_id = 'a9500000-0000-0000-0000-000000000001' where id = (select id from employees where company_id = 'c0000000-0000-0000-0000-000000000001' order by code limit 1);
select att_shift_day((select id from employees where company_id = 'c0000000-0000-0000-0000-000000000001' order by code limit 1), '2026-03-02 05:40') = '2026-03-01' as night_out_prev_day,
       att_shift_day((select id from employees where company_id = 'c0000000-0000-0000-0000-000000000001' order by code limit 1), '2026-03-01 21:50') = '2026-03-01' as night_in_same_day;
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select (attendance_import(:'C', jsonb_build_array(
  jsonb_build_object('code', (select coalesce(device_code, code) from employees where company_id = :'C' order by code limit 1), 'ts', '2026-03-01 21:55'),
  jsonb_build_object('code', (select coalesce(device_code, code) from employees where company_id = :'C' order by code limit 1), 'ts', '2026-03-02 06:05')), true)) ->> 'days' as days_one;
select check_out is not null as night_closed from attendance where employee_id = (select id from employees where company_id = :'C' order by code limit 1) and day = '2026-03-01';
reset role;
update employees set shift_id = null where shift_id = 'a9500000-0000-0000-0000-000000000001';
-- 5) نقطة البيع: بونص من العرض
insert into promotions (id, company_id, name, date_from, date_to, buy_qty, free_qty, free_repeat, discount_pct)
select 'b9500000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'اشتري 2 خذ 1', current_date - 1, current_date + 1, 2, 1, true, 0
 where not exists (select 1 from promotions where id = 'b9500000-0000-0000-0000-000000000001');
update promotions set item_id = (select id from items where company_id = 'c0000000-0000-0000-0000-000000000001' and is_active and item_type = 'goods' and not serial_tracked order by code limit 1) where id = 'b9500000-0000-0000-0000-000000000001';
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select (r -> 'lines' -> 1 ->> 'bonus')::boolean as bonus_line, (r -> 'lines' -> 1 ->> 'qty')::numeric = 2 as bonus_qty from (select pos_checkout(jsonb_build_object('company_id', :'C', 'fiscal_year_id', :'fy2', 'method', 'cash', 'paid', 1000, 'discount', 1,
  'lines', jsonb_build_array(jsonb_build_object('item_id', (select id from items where company_id = :'C' and is_active and item_type = 'goods' and not serial_tracked order by code limit 1), 'qty', 4)))) r) x;
\echo == POS serial item without serials (expected ERROR)
select pos_checkout(jsonb_build_object('company_id', :'C', 'fiscal_year_id', :'fy2', 'method', 'cash', 'paid', 1000,
  'lines', jsonb_build_array(jsonb_build_object('item_id', '10000000-0000-0000-0000-000000000086', 'qty', 1))));
-- 6) الجرد بيعدّ السيريالات
select string_agg(serial, ',' order by serial) as before_count from serial_balances(:'C', (select id from warehouses where company_id = :'C' and code = 'W86'), '10000000-0000-0000-0000-000000000086');
insert into stock_docs (id, company_id, doc_type, doc_date, warehouse_id) values ('5d950000-0000-0000-0000-000000000001', :'C', 'count', current_date, (select id from warehouses where company_id = :'C' and code = 'W86'));
insert into stock_doc_lines (doc_id, line_no, item_id, qty, counted_qty, unit_cost, serials) values ('5d950000-0000-0000-0000-000000000001', 1, '10000000-0000-0000-0000-000000000086', 0, 1, 200, array['SN95X']);
select post_stock_doc('5d950000-0000-0000-0000-000000000001') is null as counted;
select string_agg(serial, ',' order by serial) as after_count from serial_balances(:'C', (select id from warehouses where company_id = :'C' and code = 'W86'), '10000000-0000-0000-0000-000000000086');
-- 7) بونص الطلب
insert into orders (id, company_id, order_type, order_date) values ('09500000-0000-0000-0000-000000000001', :'C', 'sales_order', current_date);
insert into order_lines (order_id, line_no, item_id, qty, unit_price, bonus_qty) values ('09500000-0000-0000-0000-000000000001', 1, (select id from items where company_id = :'C' and is_active order by code limit 1), 2, 5, 1);
\echo == negative bonus (expected ERROR)
update order_lines set bonus_qty = -1 where order_id = '09500000-0000-0000-0000-000000000001';
-- 8) حذف طلب عليه دفعة مقدمة مرحّلة
\echo == delete order with posted advance (expected ERROR)
delete from orders where id = '09400000-0000-0000-0000-000000000001';
-- 4) كلمة السر: إجبار التغيير بيقفل الصلاحيات
reset role;
select set_config('sumou.pwd', internal_token(), false) \g /dev/null
update profiles set must_change_password = true where id = '22222222-2222-2222-2222-222222222222';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select can(:'C', 'customers', 'view') as can_while_must_change, tenant_writable() as writable_while_must_change, (my_password_status() ->> 'must_change')::boolean as status_ok;
reset role;
update profiles set must_change_password = false where id = '22222222-2222-2222-2222-222222222222';
select set_config('sumou.pwd', '', false) \g /dev/null
