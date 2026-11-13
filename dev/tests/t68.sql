\set ON_ERROR_STOP 0
-- الموظف على سطور القيود وميزان مراجعة الموظفين (المرحلة 68)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
select id as emp from employees where company_id = :'C' order by code limit 1 \gset
select id as adv from accounts where company_id = :'C' and not is_group order by code limit 1 \gset
select id as cash from accounts where company_id = :'C' and account_type = 'cash' and not is_group limit 1 \gset
insert into journal_entries (id, company_id, fiscal_year_id, entry_type, entry_date, description, status) values ('e6800000-0000-0000-0000-000000000001', :'C', :'F', 'journal', '2026-03-01', 'سلفة موظف', 'draft');
insert into journal_lines (entry_id, line_no, account_id, debit, credit, employee_id) values ('e6800000-0000-0000-0000-000000000001', 1, :'adv', 50, 0, :'emp'), ('e6800000-0000-0000-0000-000000000001', 2, :'cash', 0, 50, null);
select post_entry('e6800000-0000-0000-0000-000000000001') is null as posted;
select open_debit, period_debit, period_credit from rep_employee_tb(:'C', :'F', :'adv', '2026-01-01', '2026-12-31') where employee_id = :'emp';
select count(*) as ledger_rows from rep_employee_ledger(:'C', :'F', :'adv', :'emp', '2026-01-01', '2026-12-31');
\echo == party and employee on one line (expected ERROR)
insert into journal_entries (id, company_id, fiscal_year_id, entry_type, entry_date, status) values ('e6800000-0000-0000-0000-000000000002', :'C', :'F', 'journal', '2026-03-01', 'draft');
insert into journal_lines (entry_id, line_no, account_id, debit, credit, employee_id, party_id) values ('e6800000-0000-0000-0000-000000000002', 1, :'adv', 5, 0, :'emp', (select id from parties where company_id = :'C' limit 1));
\echo == employee from nowhere (expected ERROR)
insert into journal_lines (entry_id, line_no, account_id, debit, credit, employee_id) values ('e6800000-0000-0000-0000-000000000002', 1, :'adv', 5, 0, gen_random_uuid());
-- قيد الرواتب: سطر صافي لكل موظف
select count(*) filter (where l.employee_id is not null) > 0 as payroll_has_employee_lines
  from payroll_runs r join journal_lines l on l.entry_id = r.entry_id where r.company_id = :'C' and r.status in ('posted','cancelled');
-- المسيّر الملغى: رصيد الموظفين على حساب الرواتب المستحقة بيرجع صفر
select coalesce(sum(t.period_debit - t.period_credit), 0) = 0 as cancelled_nets_out from rep_employee_tb(:'C', :'F', null, '2026-01-01', '2026-12-31') t where t.account_id <> :'adv';
reset role;
\echo == employee without payroll/reports view (expected ERROR)
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select count(*) from rep_employee_tb('c0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001', null, '2026-01-01', '2026-12-31');
reset role;
