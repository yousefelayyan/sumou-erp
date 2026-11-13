\set ON_ERROR_STOP 0
-- المرحلة 40: زيارات المندوب ودفعات العملاء من الجوال
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set cust `psql -h /tmp -p 5433 -U postgres -Atqc "select id from parties where company_id='c0000000-0000-0000-0000-000000000001' and party_type='customer' and is_active order by code limit 1"`
\set cash `psql -h /tmp -p 5433 -U postgres -Atqc "select id from accounts where company_id='c0000000-0000-0000-0000-000000000001' and account_type='cash' and not is_group limit 1"`
select visit_start(:'C', :'cust', 31.95, 35.91, 'تحصيل') is not null as started;
\echo == second open visit (expected ERROR)
select visit_start(:'C', :'cust');
\echo == bad location (expected ERROR)
select visit_end((select id from sales_visits where status='open'), 999, 0);
select mobile_payment(jsonb_build_object('company_id',:'C','party_id',:'cust','kind','cash','amount',25,'account_id',:'cash','visit_id',(select id from sales_visits where status='open'))) ->> 'posted' as posted;
select e.status, e.total, e.visit_id is not null as linked from journal_entries e where e.visit_id is not null;
select (mobile_payment(jsonb_build_object('company_id',:'C','party_id',:'cust','kind','cheques','visit_id',(select id from sales_visits where status='open'),
  'cheques',jsonb_build_array(jsonb_build_object('cheque_no','M-1','amount',40,'due_date','2026-12-20','bank_name','العربي'),jsonb_build_object('cheque_no','M-2','amount',60,'due_date','2027-01-20'))))) ->> 'total' as cheques_total;
select count(*) as visit_cheques from cheques where visit_id is not null;
\echo == revenue account as cash (expected ERROR)
select mobile_payment(jsonb_build_object('company_id',:'C','party_id',:'cust','kind','cash','amount',5,'account_id',(select id from accounts where company_id=:'C' and category='revenue' and not is_group limit 1)));
select visit_end((select id from sales_visits where status='open'), 31.96, 35.92, 'تم التحصيل', 'ناجحة', 2, 0.5);
select user_id is not null as u, visits, payments from visits_report(:'C', '2000-01-01', '2100-01-01');
\echo == employee cannot see others or report (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select count(*) as emp_sees from sales_visits;
select * from visits_report(:'C', '2000-01-01', '2100-01-01');
reset role;
