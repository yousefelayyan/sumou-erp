\set ON_ERROR_STOP 0
-- المرحلة 38: تجميد المستندات
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
insert into journal_entries(id,company_id,fiscal_year_id,entry_type,entry_date,description) values ('e3800000-0000-0000-0000-000000000001',:'C',:'F','journal','2026-03-05','تجميد');
insert into journal_lines(entry_id,line_no,account_id,debit) select 'e3800000-0000-0000-0000-000000000001',1,id,10 from accounts where company_id=:'C' and code='5203';
insert into journal_lines(entry_id,line_no,account_id,credit) select 'e3800000-0000-0000-0000-000000000001',2,id,10 from accounts where company_id=:'C' and code='1101';
\echo == direct freeze (expected ERROR)
update journal_entries set is_frozen=true where id='e3800000-0000-0000-0000-000000000001';
select set_doc_frozen('journal_entries','e3800000-0000-0000-0000-000000000001',true);
\echo == edit frozen (expected ERROR)
update journal_entries set description='x' where id='e3800000-0000-0000-0000-000000000001';
\echo == post frozen (expected ERROR)
update journal_entries set status='posted' where id='e3800000-0000-0000-0000-000000000001';
\echo == line edit frozen (expected ERROR)
update journal_lines set description='x' where entry_id='e3800000-0000-0000-0000-000000000001';
\echo == delete frozen (expected ERROR)
delete from journal_entries where id='e3800000-0000-0000-0000-000000000001';
\echo == employee unfreeze (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select set_doc_frozen('journal_entries','e3800000-0000-0000-0000-000000000001',false);
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select set_doc_frozen('journal_entries','e3800000-0000-0000-0000-000000000001',false);
\echo == freeze a posted entry works, and stays frozen for restore test
select post_entry('e3800000-0000-0000-0000-000000000001');
select set_doc_frozen('journal_entries','e3800000-0000-0000-0000-000000000001',true);
select status, is_frozen from journal_entries where id='e3800000-0000-0000-0000-000000000001';
\echo == move lines out of frozen (expected ERROR)
update journal_lines set entry_id=(select id from journal_entries where company_id=:'C' and status='draft' and id<>'e3800000-0000-0000-0000-000000000001' limit 1) where entry_id='e3800000-0000-0000-0000-000000000001';
\echo == insert as frozen is ignored
insert into invoices(company_id,fiscal_year_id,inv_type,inv_date,payment_type,party_name,cash_account_id,is_frozen) select :'C',:'F','sale','2026-03-05','cash','x',id,true from accounts where company_id=:'C' and code='1101' returning is_frozen;
reset role;
