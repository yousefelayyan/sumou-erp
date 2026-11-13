-- الحضور والانصراف
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into work_locations (company_id, name, lat, lng, radius_m) values ('c0000000-0000-0000-0000-000000000001','المكتب الرئيسي',31.955,35.910,150);
insert into employees (company_id, code, name, basic_salary, user_id) values ('c0000000-0000-0000-0000-000000000001','EL46','موظف 46',500,'22222222-2222-2222-2222-222222222222') on conflict do nothing;
select id as emp from employees where company_id = 'c0000000-0000-0000-0000-000000000001' and user_id = '22222222-2222-2222-2222-222222222222' \gset
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
\echo == far away (expected ERROR)
select attendance_punch('c0000000-0000-0000-0000-000000000001','in',31.990,35.910);
\echo == out before in (expected ERROR)
select attendance_punch('c0000000-0000-0000-0000-000000000001','out',31.9551,35.9101);
select attendance_punch('c0000000-0000-0000-0000-000000000001','in',31.9551,35.9101) ->> 'location' as loc;
\echo == double in (expected ERROR)
select attendance_punch('c0000000-0000-0000-0000-000000000001','in',31.9551,35.9101);
select attendance_punch('c0000000-0000-0000-0000-000000000001','out',31.9552,35.9101) ->> 'kind' as k;
select count(*) as my_rows from attendance;
\echo == employee direct insert (expected ERROR)
insert into attendance (company_id, employee_id, day) values ('c0000000-0000-0000-0000-000000000001', :'emp', '2026-01-01');
\echo == employee sets attendance (expected ERROR)
select attendance_set(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','employee_id',:'emp','day','2026-11-01','check_in','08:00'));
\echo == employee summary (expected ERROR)
select * from attendance_summary('c0000000-0000-0000-0000-000000000001','2026-11-01','2026-11-05');
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select attendance_set(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','employee_id',:'emp','day','2026-11-01','check_in','08:30','check_out','16:00','notes','يدوي')) is not null as set_ok;
\echo == out before in (expected ERROR)
select attendance_set(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','employee_id',:'emp','day','2026-11-02','check_in','10:00','check_out','09:00'));
select days, hours, late_days, late_minutes from attendance_summary('c0000000-0000-0000-0000-000000000001','2026-11-01','2026-11-01') where employee_id = :'emp';
-- السماح من برّا الموقع
update company_settings set attendance = '{"allow_outside":true}' where company_id = 'c0000000-0000-0000-0000-000000000001';
select attendance_set(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','employee_id',:'emp','day',local_today())) is null as cleared;
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select attendance_punch('c0000000-0000-0000-0000-000000000001','in',31.990,35.910) ->> 'outside' as outside_flag;
reset role;
update company_settings set attendance = '{}' where company_id = 'c0000000-0000-0000-0000-000000000001';
