\set ON_ERROR_STOP 0
-- ضوابط أنواع السندات، الدفعة المقدمة على الطلب، كوبونات السحب (المرحلة 94)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
insert into doc_types (id, company_id, kind, code, name, require_attach, require_party, allowed_accounts)
values ('d9400000-0000-0000-0000-000000000001', :'C', 'journal', '94', 'قيود مضبوطة', true, true,
  array[(select id from accounts where company_id = :'C' and code = '11'), (select id from accounts where company_id = :'C' and code = '4')]) on conflict (id) do nothing;
select cardinality(allowed_accounts) = 2 as acc_saved from doc_types where id = 'd9400000-0000-0000-0000-000000000001';
\echo == foreign account in allowed (expected ERROR)
update doc_types set allowed_accounts = array['00000000-0000-0000-0000-000000000000'::uuid] where id = 'd9400000-0000-0000-0000-000000000001';
-- قيد: عميل بدون طرف
insert into journal_entries (id, company_id, fiscal_year_id, entry_type, entry_date, description, doc_type_id)
values ('e9400000-0000-0000-0000-000000000001', :'C', :'F', 'journal', '2026-03-01', 't94', 'd9400000-0000-0000-0000-000000000001');
insert into journal_lines (entry_id, line_no, account_id, debit, credit) values
 ('e9400000-0000-0000-0000-000000000001', 1, (select id from accounts where company_id = :'C' and account_type = 'customer' and not is_group order by code limit 1), 10, 0),
 ('e9400000-0000-0000-0000-000000000001', 2, (select id from accounts where company_id = :'C' and category = 'revenue' and not is_group order by code limit 1), 0, 10);
\echo == no attachment (expected ERROR)
select post_entry('e9400000-0000-0000-0000-000000000001');
reset role;
insert into attachments (company_id, entity, entity_id, path, file_name) values ('c0000000-0000-0000-0000-000000000001', 'entry', 'e9400000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001/t94', 't94.pdf');
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\echo == customer line without party (expected ERROR)
select post_entry('e9400000-0000-0000-0000-000000000001');
update journal_lines set party_id = (select id from parties where company_id = :'C' and party_type = 'customer' and is_active order by code limit 1) where entry_id = 'e9400000-0000-0000-0000-000000000001' and line_no = 1;
update journal_lines set account_id = (select id from accounts where company_id = :'C' and category = 'expenses' and not is_group order by code limit 1), debit = 0, credit = 10 where entry_id = 'e9400000-0000-0000-0000-000000000001' and line_no = 2;
\echo == account not allowed (expected ERROR)
select post_entry('e9400000-0000-0000-0000-000000000001');
update journal_lines set account_id = (select id from accounts where company_id = :'C' and category = 'revenue' and not is_group order by code limit 1) where entry_id = 'e9400000-0000-0000-0000-000000000001' and line_no = 2;
select post_entry('e9400000-0000-0000-0000-000000000001') is null as posted_ok;
-- الدفعة المقدمة على الطلب
insert into orders (id, company_id, order_type, order_date, party_id) values ('09400000-0000-0000-0000-000000000001', :'C', 'sales_order', '2026-03-02',
  (select id from parties where company_id = :'C' and party_type = 'customer' and is_active order by code limit 1)) on conflict do nothing;
insert into journal_entries (id, company_id, fiscal_year_id, entry_type, entry_date, description, order_id, cash_account_id)
values ('e9400000-0000-0000-0000-000000000002', :'C', :'F', 'receipt', '2026-03-02', 'دفعة مقدمة', '09400000-0000-0000-0000-000000000001', (select id from accounts where company_id = :'C' and code = '1101'));
insert into journal_lines (entry_id, line_no, account_id, debit, credit, party_id) values
 ('e9400000-0000-0000-0000-000000000002', 1, (select id from accounts where company_id = :'C' and code = '1101'), 25, 0, null),
 ('e9400000-0000-0000-0000-000000000002', 2, (select id from accounts where company_id = :'C' and account_type = 'customer' and not is_group order by code limit 1), 0, 25, (select id from parties where company_id = :'C' and party_type = 'customer' and is_active order by code limit 1));
select draft = 25 as adv_draft from order_advances(:'C', array['09400000-0000-0000-0000-000000000001'::uuid]);
select post_entry('e9400000-0000-0000-0000-000000000002') is null as adv_posted;
select posted = 25 as adv_posted_sum from order_advances(:'C', null) where order_id = '09400000-0000-0000-0000-000000000001';
\echo == order on a journal entry (expected ERROR)
update journal_entries set order_id = '09400000-0000-0000-0000-000000000001' where id = 'e9400000-0000-0000-0000-000000000001';
-- كوبونات
select count(*) >= 0 as coupons_ok from coupon_counts(:'C', '2026-01-01', '2026-12-31', 10);
\echo == zero coupon value (expected ERROR)
select * from coupon_counts(:'C', '2026-01-01', '2026-12-31', 0);
reset role;
