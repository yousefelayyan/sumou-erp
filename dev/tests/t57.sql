-- الإجازات
\set ON_ERROR_STOP 0
\set C 'c0000000-0000-0000-0000-000000000001'
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select ensure_leave_types(:'C');
select id as annual from leave_types where company_id = :'C' and code = '01' \gset
select id as unpaid from leave_types where company_id = :'C' and code = '03' \gset
select id as emp from employees where company_id = :'C' and is_active order by code limit 1 \gset
-- 2026-12-06 أحد .. 2026-12-12 سبت = 6 أيام بدون الجمعة
select leave_request(jsonb_build_object('company_id',:'C','employee_id',:'emp','type_id',:'annual','from_date','2026-12-06','to_date','2026-12-12','reason','سفر')) as r1 \gset
select days from leave_requests where id = :'r1';
\echo == overlapping request (expected ERROR)
select leave_request(jsonb_build_object('company_id',:'C','employee_id',:'emp','type_id',:'annual','from_date','2026-12-10','to_date','2026-12-10'));
select leave_decide(:'r1', true, 'موافق');
select * from leave_balance(:'C', :'emp', 2026) where code = '01';
select leave_request(jsonb_build_object('company_id',:'C','employee_id',:'emp','type_id',:'annual','from_date','2026-12-13','to_date','2026-12-31')) as r2 \gset
\echo == employee approving (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select leave_decide(:'r2', true, null);
select count(*) as emp_sees from leave_requests;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select leave_cancel(:'r2');
-- بدون راتب بشهر 11 وخصمه بالمسيّر
select leave_request(jsonb_build_object('company_id',:'C','employee_id',:'emp','type_id',:'unpaid','from_date','2026-11-01','to_date','2026-11-03')) as r3 \gset
select leave_decide(:'r3', true, null);
reset role;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
set role authenticated;
insert into payroll_runs (company_id, period, run_date) values (:'C', '2026-11', '2026-11-30') returning id as run \gset
select payroll_fill(:'run');
select l.other_ded > 0 as unpaid_deducted, l.notes from payroll_lines l where l.run_id = :'run' and l.employee_id = :'emp';
select employee_id is not null, leave_days, absent_days >= 0 from attendance_summary(:'C', '2026-12-01', '2026-12-31') where employee_id = :'emp';
delete from payroll_runs where id = :'run';
reset role;
