-- القروض والسلف و«راتبي»
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into employees (company_id, code, name, basic_salary, user_id) values ('c0000000-0000-0000-0000-000000000001','EL46','موظف 46',500,'22222222-2222-2222-2222-222222222222') on conflict do nothing;
select id as emp from employees where company_id = 'c0000000-0000-0000-0000-000000000001' and code = 'EL46' \gset
update employees set user_id = '22222222-2222-2222-2222-222222222222' where id = :'emp';
select to_char(local_today(),'YYYY-MM') as m0, to_char(local_today() + interval '1 month','YYYY-MM') as m1 \gset
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
\echo == employee requests own loan
select loan_request(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','amount',300,'installments',3,'first_month',:'m0','reason','طوارئ')) as lid \gset
\echo == tiny amount (expected ERROR)
select loan_request(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','amount',0.001,'installments',3));
\echo == old month request, approval refused later
select loan_request(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','amount',50,'installments',1,'first_month','2020-01')) as oldid \gset
\echo == employee approves own loan (expected ERROR)
select loan_decide(:'lid', true);
select count(*) as my_loans from employee_loans;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\echo == past first month (expected ERROR)
select loan_decide(:'oldid', true);
select loan_decide(:'lid', true, 'موافق');
select count(*) as inst, sum(amount) as total from loan_installments where loan_id = :'lid';
\echo == direct insert (expected ERROR)
insert into employee_loans (company_id, employee_id, loan_no, amount, first_month) values ('c0000000-0000-0000-0000-000000000001', :'emp', 999, 1, '2026-01');
-- مسيّرين مسودة: القسط بيتحجز لواحد بس
insert into payroll_runs (company_id, period, run_date) values ('c0000000-0000-0000-0000-000000000001', :'m0', local_today()) on conflict do nothing;
insert into payroll_runs (company_id, period, run_date) values ('c0000000-0000-0000-0000-000000000001', :'m1', local_today()) on conflict do nothing;
select id as run0 from payroll_runs where company_id = 'c0000000-0000-0000-0000-000000000001' and period = :'m0' \gset
select id as run1 from payroll_runs where company_id = 'c0000000-0000-0000-0000-000000000001' and period = :'m1' \gset
select payroll_fill(:'run0') > 0 as f0, payroll_fill(:'run1') > 0 as f1;
select (select advances from payroll_lines where run_id = :'run0' and employee_id = :'emp') as adv0,
       (select advances from payroll_lines where run_id = :'run1' and employee_id = :'emp') as adv1;
-- خصم أقل من القسط
update payroll_lines set advances = 60 where run_id = :'run0' and employee_id = :'emp';
\echo == advances below reserved (expected ERROR)
select post_payroll(:'run0') is not null;
update payroll_lines set advances = 100 where run_id = :'run0' and employee_id = :'emp';
select post_payroll(:'run0') is not null as posted;
select string_agg(status || ':' || coalesce(paid_run_id::text = :'run0', false)::text, ',' order by seq) as st from loan_installments where loan_id = :'lid';
-- تأجيل قسط محجوز بمسيّر الشهر الجاي بينزّل خصمه
select loan_defer((select id from loan_installments where loan_id = :'lid' and seq = 2));
select (select advances from payroll_lines where run_id = :'run1' and employee_id = :'emp') as adv1_after_defer;
select select_cancel from (select cancel_payroll(:'run0') is null as select_cancel) x;
select count(*) filter (where status = 'pending') as pending_after_cancel from loan_installments where loan_id = :'lid';
select count(*) as users_list from company_users('c0000000-0000-0000-0000-000000000001');
reset role;
-- تنظيف
delete from payroll_runs where company_id = 'c0000000-0000-0000-0000-000000000001' and period in (:'m1') and status = 'draft';
