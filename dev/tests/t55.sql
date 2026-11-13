-- تسجيل الشيكات من سند القبض
\set ON_ERROR_STOP 0
\set C 'c0000000-0000-0000-0000-000000000001'
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select id as cust from parties where company_id = :'C' and party_type = 'customer' order by code limit 1 \gset
select id as cash from accounts where company_id = :'C' and not is_group and account_type = 'cash' order by code limit 1 \gset
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description,cash_account_id) values (:'C','f0000000-0000-0000-0000-000000000001','receipt','2026-05-10','قبض نقد وشيكات',:'cash') returning id as rid \gset
insert into journal_lines(entry_id,line_no,account_id,debit,credit) values (:'rid',1,:'cash',100,0),(:'rid',2,(select account_id from parties where id = :'cust'),0,100);
update journal_lines set party_id = :'cust' where entry_id = :'rid' and line_no = 2;
select count(*) as n from receipt_cheques(:'C', :'rid', :'cust', null, '[{"cheque_no":"R55-1","bank_name":"العربي","due_date":"2026-06-30","amount":150},{"cheque_no":"R55-2","due_date":"2026-07-30","amount":250.5,"endorser_name":"فلان"}]');
select count(*) as linked, sum(amount) as total, min(issue_date) as issued from cheques where receipt_entry_id = :'rid';
select count(*) as cheque_entries from journal_entries where company_id = :'C' and entry_type = 'cheque' and reference like 'R55-%' and status = 'posted';
\echo == cheques only, no voucher
select count(*) as n2 from receipt_cheques(:'C', null, :'cust', '2026-05-11', '[{"cheque_no":"R55-3","due_date":"2026-08-01","amount":75}]');
\echo == missing due date (expected ERROR)
select * from receipt_cheques(:'C', :'rid', :'cust', null, '[{"cheque_no":"R55-4","amount":10}]');
\echo == direct link change (expected ERROR)
update cheques set receipt_entry_id = null where cheque_no = 'R55-1';
\echo == delete draft voucher unlinks cheques
delete from journal_entries where id = :'rid';
select count(*) as still_in_portfolio from cheques where cheque_no in ('R55-1','R55-2') and receipt_entry_id is null and status = 'portfolio';
\echo == employee without permission (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select * from receipt_cheques(:'C', :'rid', :'cust', null, '[{"cheque_no":"R55-5","due_date":"2026-08-01","amount":5}]');
reset role;
