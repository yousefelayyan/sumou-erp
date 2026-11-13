\set ON_ERROR_STOP 0
-- صرف الرواتب (المرحلة 91)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
delete from payroll_runs where company_id = :'C' and period = '2026-08' and status = 'draft';
insert into payroll_runs (id, company_id, period, run_date) values ('9a910000-0000-0000-0000-000000000001', :'C', '2026-08', '2026-08-31') on conflict do nothing;
select payroll_fill('9a910000-0000-0000-0000-000000000001') > 0 as filled;
\echo == pay before posting (expected ERROR)
select payroll_pay('9a910000-0000-0000-0000-000000000001', jsonb_build_object('account_id', (select id from accounts where company_id = :'C' and code = '1101')));
select post_payroll('9a910000-0000-0000-0000-000000000001') is not null as posted;
\echo == bad account (expected ERROR)
select payroll_pay('9a910000-0000-0000-0000-000000000001', '{"account_id":"00000000-0000-0000-0000-000000000000"}');
-- صرف موظف واحد نقداً
select payroll_pay('9a910000-0000-0000-0000-000000000001', jsonb_build_object('date','2026-09-02','account_id', (select id from accounts where company_id = :'C' and code = '1101'),
  'employees', jsonb_build_array((select employee_id from payroll_lines where run_id = '9a910000-0000-0000-0000-000000000001' and net > 0 order by employee_id limit 1)))) is not null as paid_one;
select count(*) filter (where paid) = 1 as one_paid, count(*) filter (where not paid and net > 0) > 0 as rest_unpaid from payroll_pay_status('9a910000-0000-0000-0000-000000000001');
\echo == cheques without number (expected ERROR)
select payroll_pay('9a910000-0000-0000-0000-000000000001', '{"method":"cheques","date":"2026-09-03"}');
-- الباقي بشيكات
select payroll_pay('9a910000-0000-0000-0000-000000000001', jsonb_build_object('method','cheques','date','2026-09-03','bank_name','الإسكان',
  'cheques', (select jsonb_agg(jsonb_build_object('employee_id', employee_id, 'cheque_no', 'PR' || left(employee_id::text, 6))) from payroll_lines where run_id = '9a910000-0000-0000-0000-000000000001'))) is not null as paid_cheques;
select bool_and(paid) as all_paid, count(cheque_no) > 0 as has_cheques from payroll_pay_status('9a910000-0000-0000-0000-000000000001') where net > 0;
-- القيد متوازن ورصيد الرواتب المستحقة صفر للمسيّر
select abs(sum(debit) - sum(credit)) < 0.001 as balanced from journal_lines where entry_id in (select entry_id from payroll_payments where run_id = '9a910000-0000-0000-0000-000000000001');
select abs(coalesce(sum(jl.debit - jl.credit), 0)) < 0.001 as payable_cleared from journal_lines jl
  where jl.account_id = (select salaries_payable_account_id from company_settings where company_id = :'C')
    and jl.entry_id in (select entry_id from payroll_runs where id = '9a910000-0000-0000-0000-000000000001' union select entry_id from payroll_payments where run_id = '9a910000-0000-0000-0000-000000000001');
\echo == pay again (expected ERROR)
select payroll_pay('9a910000-0000-0000-0000-000000000001', jsonb_build_object('account_id', (select id from accounts where company_id = :'C' and code = '1101')));
\echo == cancel paid run (expected ERROR)
select cancel_payroll('9a910000-0000-0000-0000-000000000001', '2026-09-05');
\echo == no rights (expected ERROR)
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false) \g /dev/null
select payroll_pay('9a910000-0000-0000-0000-000000000001', '{}');
reset role;
