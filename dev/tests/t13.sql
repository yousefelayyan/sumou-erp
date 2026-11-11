\set ON_ERROR_STOP 0
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
\echo == dashboard
select dash_kpis(:'C',:'F','2026-12-31') - 'month_sales' as k;
select kind, doc_type, count(*) from pending_posts(:'C') group by 1,2;
\echo == recurring
insert into journal_entries(id,company_id,fiscal_year_id,entry_type,entry_date,description) values ('e1300000-0000-0000-0000-000000000001',:'C',:'F','journal','2026-01-05','إيجار شهري');
insert into journal_lines(entry_id,line_no,account_id,debit) select 'e1300000-0000-0000-0000-000000000001',1,id,300 from accounts where company_id=:'C' and code='5203';
insert into journal_lines(entry_id,line_no,account_id,credit) select 'e1300000-0000-0000-0000-000000000001',2,id,300 from accounts where company_id=:'C' and code='1101';
insert into recurring_entries(company_id,source_entry_id,title,day_of_month,next_date) values (:'C','e1300000-0000-0000-0000-000000000001','إيجار',5,'2026-02-05');
select run_recurring(:'C','2026-05-10') as made;
select run_recurring(:'C','2026-05-10') as made_again;
select next_date from recurring_entries;
\echo == payroll
insert into employees(company_id,code,name,basic_salary,allowances,income_tax) values (:'C','1','أحمد',600,100,10),(:'C','2','سارة',400,0,0);
insert into employees(company_id,code,name,basic_salary,ss_subject) values (:'C','3','عامل مؤقت',300,false);
insert into payroll_runs(id,company_id,period,run_date) values ('a1300000-0000-0000-0000-000000000001',:'C','2026-05','2026-05-31');
select payroll_fill('a1300000-0000-0000-0000-000000000001') filled;
update payroll_lines set advances = 50 where employee_id=(select id from employees where code='1');
select e.name, l.gross, l.ss_employee, l.ss_employer, l.income_tax, l.advances, l.net from payroll_lines l join employees e on e.id=l.employee_id order by e.code;
select post_payroll('a1300000-0000-0000-0000-000000000001') is not null posted;
select a.code, l.debit, l.credit from journal_lines l join accounts a on a.id=l.account_id where l.entry_id=(select entry_id from payroll_runs where id='a1300000-0000-0000-0000-000000000001') order by l.line_no;
update payroll_lines set basic=1 where run_id='a1300000-0000-0000-0000-000000000001';
select reverse_entry(entry_id) from payroll_runs;
select cancel_payroll('a1300000-0000-0000-0000-000000000001','2026-06-01');
select status from payroll_runs;
\echo == assets
insert into fixed_assets(id,company_id,code,name,purchase_date,dep_start,cost,salvage,life_months,asset_account_id) select 'fa000000-0000-0000-0000-000000000001',:'C','A1','لابتوب','2026-01-10','2026-01-10',1300,100,24,id from accounts where company_id=:'C' and code='1206';
select * from depreciation_preview(:'C','2026-03-15');
select post_depreciation(:'C','2026-03-15') is not null dep1;
select asset_accum('fa000000-0000-0000-0000-000000000001') accum;
select * from depreciation_preview(:'C','2026-03-31');
select post_depreciation(:'C','2026-06-30') is not null dep2;
select asset_accum('fa000000-0000-0000-0000-000000000001') accum2;
update fixed_assets set cost=2000 where code='A1';
select cancel_depreciation((select id from depreciation_runs order by created_at limit 1));
select cancel_depreciation((select id from depreciation_runs order by created_at desc limit 1), '2026-07-01');
select asset_accum('fa000000-0000-0000-0000-000000000001') accum_after_cancel;
\echo == bank recon
insert into bank_recons(id,company_id,account_id,statement_date,statement_balance) select 'b1300000-0000-0000-0000-000000000001',:'C',id,'2026-12-31',0 from accounts where company_id=:'C' and code='1101';
select count(*) lines, sum(debit-credit) from rep_bank_lines('b1300000-0000-0000-0000-000000000001');
select account_book_balance(:'C',(select id from accounts where company_id=:'C' and code='1101'),'2026-12-31') book;
insert into bank_cleared(line_id,recon_id) select line_id,'b1300000-0000-0000-0000-000000000001' from rep_bank_lines('b1300000-0000-0000-0000-000000000001') limit 2;
select count(*) filter (where cleared) from rep_bank_lines('b1300000-0000-0000-0000-000000000001');
insert into bank_cleared(line_id,recon_id) select l.id,'b1300000-0000-0000-0000-000000000001' from journal_lines l join accounts a on a.id=l.account_id where a.code='4101' limit 1;
\echo == cost centers & fx
insert into cost_centers(id,company_id,code,name) values ('cc000000-0000-0000-0000-000000000001',:'C','1','الفرع الرئيسي');
insert into journal_entries(id,company_id,fiscal_year_id,entry_type,entry_date,description) values ('e1300000-0000-0000-0000-000000000002',:'C',:'F','journal','2026-07-01','بيع بالدولار');
insert into journal_lines(entry_id,line_no,account_id,debit,currency,fx_rate,fx_amount) select 'e1300000-0000-0000-0000-000000000002',1,id,70.9,'USD',0.709,100 from accounts where company_id=:'C' and code='1102';
insert into journal_lines(entry_id,line_no,account_id,credit,cost_center_id) select 'e1300000-0000-0000-0000-000000000002',2,id,70.9,'cc000000-0000-0000-0000-000000000001' from accounts where company_id=:'C' and code='4104';
select post_entry('e1300000-0000-0000-0000-000000000002');
select * from rep_cost_centers(:'C','2026-01-01','2026-12-31') where cost_center_id is not null;
select currency, fx_balance, jod_balance from rep_fx_balances(:'C','2026-12-31');
select reverse_entry('e1300000-0000-0000-0000-000000000002','2026-07-02');
select * from rep_cost_centers(:'C','2026-01-01','2026-12-31') where cost_center_id is not null;
\echo == backup / restore
reset role;
create temp table tb_before as select sum(l.debit) d, sum(l.credit) c, count(*) n from journal_lines l join journal_entries e on e.id=l.entry_id where e.company_id=:'C';
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
create temp table bk as select backup_company(:'C') j;
select jsonb_object_keys(j->'tables') k, jsonb_array_length(j->'tables'->jsonb_object_keys(j->'tables')) n from bk order by 1;
select restore_company((select j from bk));
reset role;
select set_config('sumou.internal', public.internal_token(), false) \g /dev/null
delete from companies where id=:'C';
select set_config('sumou.internal', '', false) \g /dev/null
select count(*) companies_left from companies where id=:'C';
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select restore_company((select j from bk)) restored;
reset role;
select (select row(d,c,n)::text from tb_before) before, (select row(sum(l.debit), sum(l.credit), count(*))::text from journal_lines l join journal_entries e on e.id=l.entry_id where e.company_id=:'C') after;
select count(*) reversed_links from journal_entries where company_id=:'C' and reversed_by is not null;
select count(*) invoices, count(original_invoice_id) returns from invoices where company_id=:'C';
