-- المناوبات والإضافي والجزاءات
\set ON_ERROR_STOP 0
\set C 'c0000000-0000-0000-0000-000000000001'
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\echo == bad shift (expected ERROR)
insert into work_shifts(company_id,code,name,start_time,end_time) values (:'C','X','x','08:00','08:00');
insert into work_shifts(company_id,code,name,start_time,end_time,grace_min,days_off) values (:'C','S1','صباحي','08:00','16:00',10,'{5,6}') returning id as sh \gset
select id as emp, basic_salary + allowances as monthly from employees where company_id = :'C' and is_active order by code offset 1 limit 1 \gset
update employees set shift_id = :'sh' where id = :'emp';
update company_settings set attendance = attendance || '{"apply_payroll":true,"ot_rate":1.25,"ot_offday_rate":1.5,"ot_min":30,"hours_per_day":8}' where company_id = :'C';
-- 2026-10-04 أحد: تأخير 40 دقيقة وإضافي ساعة. 2026-10-05 اثنين: خروج مبكر 30 د. 2026-10-09 جمعة (عطلة): 4 ساعات إضافي عطلة
select attendance_set(jsonb_build_object('company_id',:'C','employee_id',:'emp','day','2026-10-04','check_in','08:40','check_out','17:00')) \g /dev/null
select attendance_set(jsonb_build_object('company_id',:'C','employee_id',:'emp','day','2026-10-05','check_in','08:00','check_out','15:30')) \g /dev/null
select attendance_set(jsonb_build_object('company_id',:'C','employee_id',:'emp','day','2026-10-09','check_in','09:00','check_out','13:00')) \g /dev/null
select late_minutes, early_minutes, ot_minutes, offday_minutes, absent_days, late_amount > 0 as late_amt, ot_amount from attendance_summary(:'C','2026-10-04','2026-10-10') where employee_id = :'emp';
select round(:monthly / 30.0 / 8 * (1 * 1.25 + 4 * 1.5), 3) as expected_ot;
\echo == employee shift from another company (expected ERROR)
update employees set shift_id = gen_random_uuid() where id = :'emp';
insert into payroll_runs (company_id, period, run_date) values (:'C', '2026-10', '2026-10-31') returning id as run \gset
select payroll_fill(:'run') \g /dev/null
select overtime > 0 as ot_added, other_ded > 0 as penalties, notes from payroll_lines where run_id = :'run' and employee_id = :'emp';
delete from payroll_runs where id = :'run';
update company_settings set attendance = attendance - 'apply_payroll' where company_id = :'C';
reset role;
