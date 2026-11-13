-- أنواع السندات
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select ensure_doc_types('c0000000-0000-0000-0000-000000000001') >= 0 as ensured;
select count(*) filter (where is_default) as defaults from doc_types where company_id = 'c0000000-0000-0000-0000-000000000001';
select count(*) as untyped from journal_entries where company_id = 'c0000000-0000-0000-0000-000000000001' and entry_type in ('journal','receipt','payment','opening') and doc_type_id is null;
insert into doc_types (company_id, kind, code, name, own_seq, prefix, date_today, edit_days, print_copies)
values ('c0000000-0000-0000-0000-000000000001','journal','T48','قيود تسويات','true','JV-',true,0,2) on conflict do nothing;
select id as dt from doc_types where company_id = 'c0000000-0000-0000-0000-000000000001' and kind = 'journal' and code = 'T48' \gset
\echo == wrong kind type on receipt (expected ERROR)
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,doc_type_id) values ('c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','receipt',local_today(),:'dt');
reset role;
update user_groups set permissions = permissions || '{"journal_entries":{"view":true,"add":true,"edit":true}}' where id = (select group_id from user_companies where user_id = '22222222-2222-2222-2222-222222222222' and company_id = 'c0000000-0000-0000-0000-000000000001');
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
\echo == employee: date not today (expected ERROR)
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,doc_type_id) values ('c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','journal',local_today() - 3,:'dt');
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,doc_type_id) values ('c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','journal',local_today(),:'dt') returning doc_code like 'JV-%' as prefixed, entry_no \gset
select :'prefixed' as prefixed, :'entry_no' as first_no;
reset role;
alter table journal_entries disable trigger user;
update journal_entries set created_at = now() - interval '3 days' where doc_type_id = :'dt';
alter table journal_entries enable trigger user;
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
\echo == employee edit after edit_days (expected ERROR)
update journal_entries set description = 'x' where doc_type_id = :'dt';
\echo == employee: switch to default type to escape window (expected ERROR)
update journal_entries set description = 'bypass', doc_type_id = (select id from doc_types where company_id = 'c0000000-0000-0000-0000-000000000001' and kind = 'journal' and is_default) where doc_type_id = :'dt';
\echo == employee: add line to expired draft (expected ERROR)
insert into journal_lines(entry_id, line_no, account_id, debit, credit) select id, 9, (select id from accounts where company_id = 'c0000000-0000-0000-0000-000000000001' and not is_group limit 1), 1, 0 from journal_entries where doc_type_id = :'dt';
reset role;
-- قيد على النوع الافتراضي بدون ما ينبعت النوع
update doc_types set date_today = true where company_id = 'c0000000-0000-0000-0000-000000000001' and kind = 'journal' and is_default;
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
\echo == employee: default type date_today, type omitted (expected ERROR)
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date) values ('c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','journal',local_today() - 5);
reset role;
update doc_types set date_today = false where company_id = 'c0000000-0000-0000-0000-000000000001' and kind = 'journal' and is_default;
select count(*) as typed_default from journal_entries j join doc_types t on t.id = j.doc_type_id where t.is_default and j.company_id = 'c0000000-0000-0000-0000-000000000001';
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\echo == admin edits freely
update journal_entries set description = 'admin' where doc_type_id = :'dt' and status = 'draft';
\echo == deactivate default (expected ERROR)
update doc_types set is_active = false where company_id = 'c0000000-0000-0000-0000-000000000001' and kind = 'journal' and is_default;
delete from journal_entries where doc_type_id = :'dt';
delete from doc_types where id = :'dt';
reset role;
