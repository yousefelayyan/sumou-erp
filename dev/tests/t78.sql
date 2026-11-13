\set ON_ERROR_STOP 0
-- ضوابط القروض والسلف من السندات (المرحلة 78)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
select loan_rules_save(:'C', '{"max_multiple":2,"max_inst_pct":25,"max_open":1,"max_installments":12}');
select loan_rules_get(:'C') ->> 'max_multiple' as rule;
insert into employees (id, company_id, code, name, basic_salary, allowances, hire_date, user_id) values ('78000000-0000-0000-0000-0000000000e1', :'C', 'E78', 'موظف 78', 500, 0, '2020-01-01', null) on conflict do nothing;
-- طلب المشرف لغيره بينحفظ (مخالف) بس الاعتماد ممنوع لغير المدير
reset role;
update user_groups set permissions = permissions || '{"payroll":{"view":true,"add":true,"edit":true,"post":true}}' where id = (select group_id from user_companies where user_id = '22222222-2222-2222-2222-222222222222' and company_id = :'C');
update user_companies set branch_only = false where user_id = '22222222-2222-2222-2222-222222222222';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select loan_request(jsonb_build_object('company_id', :'C', 'employee_id', '78000000-0000-0000-0000-0000000000e1', 'amount', 1500, 'installments', 3)) as lid \gset
select array_length(loan_rule_issues(:'lid'), 1) as issues;
\echo == approve violating loan (expected ERROR)
select loan_decide(:'lid', true, null);
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select loan_decide(:'lid', true, 'استثناء من المدير');
select status from employee_loans where id = :'lid';
-- سلفة من سند صرف
select id as adv from accounts where company_id = :'C' and code = '1107' \gset
select id as cash from accounts where company_id = :'C' and code = '1101' \gset
reset role; update company_settings set advances_account_id = :'adv' where company_id = :'C';
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into journal_entries (id, company_id, fiscal_year_id, entry_type, entry_date, cash_account_id) values ('78000000-0000-0000-0000-0000000000a1', :'C', :'F', 'payment', '2026-11-01', :'cash');
insert into journal_lines (entry_id, line_no, account_id, employee_id, debit, credit) values ('78000000-0000-0000-0000-0000000000a1', 1, :'adv', '78000000-0000-0000-0000-0000000000e1', 300, 0), ('78000000-0000-0000-0000-0000000000a1', 2, :'cash', null, 0, 300);
select post_entry('78000000-0000-0000-0000-0000000000a1') is not null as posted;
select loan_from_entry('78000000-0000-0000-0000-0000000000a1', '78000000-0000-0000-0000-0000000000e1', 3, to_char(current_date + interval '1 month', 'YYYY-MM')) as l2 \gset
select status, amount, (select count(*) from loan_installments where loan_id = :'l2') as inst from employee_loans where id = :'l2';
\echo == convert same entry twice (expected ERROR)
select loan_from_entry('78000000-0000-0000-0000-0000000000a1', '78000000-0000-0000-0000-0000000000e1', 3, to_char(current_date + interval '1 month', 'YYYY-MM'));
\echo == reverse entry linked to loan (expected ERROR)
select reverse_entry('78000000-0000-0000-0000-0000000000a1', '2026-11-02');
reset role;
