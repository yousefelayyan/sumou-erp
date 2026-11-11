\set ON_ERROR_STOP 0
insert into auth.users(id,email) values ('11111111-1111-1111-1111-111111111111','admin@x.com'),('22222222-2222-2222-2222-222222222222','emp@x.com');
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into companies(id,code,name) values ('c0000000-0000-0000-0000-000000000001','Z','زوز');
insert into fiscal_years(id,company_id,code,start_date,end_date) values ('f0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000001','2026','2026-01-01','2026-12-31');
select seed_default_accounts('c0000000-0000-0000-0000-000000000001') as seeded;
select seed_default_accounts('c0000000-0000-0000-0000-000000000001') as seeded_again;
select code,level,(select code from accounts p where p.id=a.parent_id) parent from accounts a where code in ('1','11','1101','5402');
-- receipt: cash debit 100, sales credit 100
insert into journal_entries(id,company_id,fiscal_year_id,entry_type,entry_date,description,cash_account_id)
 select 'e0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','receipt','2026-03-01','بيع', id from accounts where code='1101';
insert into journal_lines(entry_id,line_no,account_id,debit) select 'e0000000-0000-0000-0000-000000000001',1,id,100 from accounts where code='1101';
insert into journal_lines(entry_id,line_no,account_id,credit) select 'e0000000-0000-0000-0000-000000000001',2,id,90 from accounts where code='4101';
select post_entry('e0000000-0000-0000-0000-000000000001'); -- unbalanced
update journal_lines set credit=100 where entry_id='e0000000-0000-0000-0000-000000000001' and line_no=2;
insert into journal_lines(entry_id,line_no,account_id,credit) select 'e0000000-0000-0000-0000-000000000001',3,id,5 from accounts where code='4';  -- group account
select post_entry('e0000000-0000-0000-0000-000000000001') as posted;
select entry_no,status,total from journal_entries;
update journal_entries set description='x' where id='e0000000-0000-0000-0000-000000000001';
delete from journal_lines where entry_id='e0000000-0000-0000-0000-000000000001';
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date) values ('c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','journal','2027-01-05'); -- out of FY
select reverse_entry('e0000000-0000-0000-0000-000000000001','2026-03-05') is not null as reversed;
select entry_no,status,total,reversal_of is not null rev from journal_entries order by created_at;
select a.code, b.debit, b.credit from account_balances b join accounts a on a.id=b.account_id;
-- employee as data entry
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
update profiles set is_active=true where email='emp@x.com';
insert into user_companies select '22222222-2222-2222-2222-222222222222','c0000000-0000-0000-0000-000000000001',id from user_groups where name='مدخل بيانات';
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select count(*) emp_sees_entries from journal_entries;
insert into journal_entries(id,company_id,fiscal_year_id,entry_type,entry_date) values ('e0000000-0000-0000-0000-000000000009','c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','journal','2026-04-01');
insert into journal_lines(entry_id,account_id,debit) select 'e0000000-0000-0000-0000-000000000009',id,10 from accounts where code='5203';
insert into journal_lines(entry_id,account_id,credit) select 'e0000000-0000-0000-0000-000000000009',id,10 from accounts where code='1101';
select post_entry('e0000000-0000-0000-0000-000000000009'); -- no post perm
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date) values ('c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','opening','2026-01-01'); -- no perm
insert into accounts(company_id,code,name,category,nature) values ('c0000000-0000-0000-0000-000000000001','9','x','assets','debit'); -- no perm
reset role;
