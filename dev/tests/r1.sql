\set ON_ERROR_STOP 0
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
-- 1) unbalanced draft -> posted directly
insert into journal_entries(id,company_id,fiscal_year_id,entry_type,entry_date) values ('e0000000-0000-0000-0000-0000000000f1','c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','journal','2026-04-02');
insert into journal_lines(entry_id,account_id,debit) select 'e0000000-0000-0000-0000-0000000000f1',id,999 from accounts where code='1101';
update journal_entries set status='posted' where id='e0000000-0000-0000-0000-0000000000f1';
select status from journal_entries where id='e0000000-0000-0000-0000-0000000000f1';
-- 2) move a line out of a posted entry into my draft
insert into journal_entries(id,company_id,fiscal_year_id,entry_type,entry_date) values ('e0000000-0000-0000-0000-0000000000f2','c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','journal','2026-04-02');
select e.entry_no, e.status, count(*) from journal_lines l join journal_entries e on e.id=l.entry_id where e.status='posted' and e.entry_type='journal' group by 1,2;
update journal_lines set entry_id='e0000000-0000-0000-0000-0000000000f2' where id=(select l.id from journal_lines l join journal_entries e on e.id=l.entry_id where e.status='posted' and e.entry_type='journal' limit 1);
select e.entry_no, e.status, count(*) from journal_lines l join journal_entries e on e.id=l.entry_id where e.entry_type='journal' group by 1,2;
-- 3) set_config from client
select set_config('sumou.internal','on',false);
update journal_entries set description='hacked' where status='posted' and entry_type='journal';
select set_config('sumou.internal','',false);
