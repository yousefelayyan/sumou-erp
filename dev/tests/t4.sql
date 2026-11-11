set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into parties(company_id,party_type,code,name,account_id) select 'c0000000-0000-0000-0000-000000000001','customer','', 'محمد', id from accounts where code='1103';
insert into parties(company_id,party_type,code,name,account_id) select 'c0000000-0000-0000-0000-000000000001','customer','', 'أحمد', id from accounts where code='1103';
select code,name from parties;
insert into journal_entries(id,company_id,fiscal_year_id,entry_type,entry_date,description) values ('e0000000-0000-0000-0000-0000000000a1','c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','journal','2026-02-01','بيع آجل');
insert into journal_lines(entry_id,line_no,account_id,party_id,debit) select 'e0000000-0000-0000-0000-0000000000a1',1,a.id,p.id,250 from accounts a, parties p where a.code='1103' and p.code='C0001';
insert into journal_lines(entry_id,line_no,account_id,credit) select 'e0000000-0000-0000-0000-0000000000a1',2,id,250 from accounts where code='4101';
select post_entry('e0000000-0000-0000-0000-0000000000a1');
select * from party_balances;
select entry_no, debit from rep_party_ledger('c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001',(select id from parties where code='C0001'),'2026-01-01','2026-12-31');
select * from rep_party_movements('c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','customer','2026-12-31');
