\set ON_ERROR_STOP 0
-- قفل الفترة لكل قسم (المرحلة 80)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
select id as cash from accounts where company_id=:'C' and account_type='cash' and not is_group limit 1 \gset
-- مسودة قبض ومسودة قيد بشهر 7 قبل القفل
insert into journal_entries(company_id,fiscal_year_id,entry_type,cash_account_id,entry_date,description) values (:'C',:'F','receipt',:'cash','2026-07-05','قبض80') returning id as rc \gset
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description) values (:'C',:'F','journal','2026-07-06','قيد80') returning id as jv \gset
\echo == bad section name (expected ERROR)
update fiscal_periods set locked_sections = '{bogus}' where fiscal_year_id=:'F' and code like '07.%';
update fiscal_periods set locked_sections = '{receipts,sales,receipts}' where fiscal_year_id=:'F' and code like '07.%' returning locked_sections;
\echo == new receipt in locked July (expected ERROR)
insert into journal_entries(company_id,fiscal_year_id,entry_type,cash_account_id,entry_date,description) values (:'C',:'F','receipt',:'cash','2026-07-10','x');
\echo == edit draft receipt in July (expected ERROR)
update journal_entries set description = 'y' where id = :'rc';
\echo == add a line to the July receipt (expected ERROR)
insert into journal_lines(entry_id,line_no,account_id,debit,credit) select :'rc', 1, id, 5, 0 from accounts where company_id=:'C' and not is_group limit 1;
\echo == move a receipt into July (expected ERROR)
insert into journal_entries(company_id,fiscal_year_id,entry_type,cash_account_id,entry_date,description) values (:'C',:'F','receipt',:'cash','2026-08-10','آب80') returning id as rc8 \gset
update journal_entries set entry_date = '2026-07-15' where id = :'rc8';
\echo == delete July receipt (expected ERROR)
delete from journal_entries where id = :'rc';
\echo == journal section still open: edit works
update journal_entries set description = 'قيد80 معدّل' where id = :'jv' returning description;
\echo == sales invoice in July (expected ERROR)
insert into invoices(company_id,fiscal_year_id,inv_type,inv_date,payment_type,party_name) values (:'C',:'F','sale','2026-07-20','cash','x');
\echo == purchase invoice in July works
insert into invoices(company_id,fiscal_year_id,inv_type,inv_date,payment_type,party_name) values (:'C',:'F','purchase','2026-07-20','cash','مورد80') returning inv_type;
\echo == freezing a July receipt is still allowed
select set_doc_frozen('journal_entries', :'rc', true); select is_frozen from journal_entries where id = :'rc';
select set_doc_frozen('journal_entries', :'rc', false) \g /dev/null
\echo == user without rights cannot unlock (0 rows)
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false) \g /dev/null
update fiscal_periods set locked_sections = '{}' where fiscal_year_id=:'F' and code like '07.%' returning code;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select period_locked(:'C', '2026-07-01', 'sales') as july_sales, period_locked(:'C', '2026-08-01', 'sales') as aug_sales;
update fiscal_periods set locked_sections = '{}' where fiscal_year_id=:'F' and code like '07.%' returning locked_sections;
delete from journal_entries where description in ('قبض80','قيد80 معدّل','آب80');
delete from invoices where party_name = 'مورد80';
reset role;
\echo == posted July receipt, lock July, reverse it dated August works; unpost blocked
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select id as cash from accounts where company_id=:'C' and account_type='cash' and not is_group limit 1 \gset
select id as inc from accounts where company_id=:'C' and category='revenue' and not is_group limit 1 \gset
insert into journal_entries(company_id,fiscal_year_id,entry_type,cash_account_id,entry_date,description) values (:'C',:'F','receipt',:'cash','2026-07-07','قبض80ب') returning id as rp \gset
insert into journal_lines(entry_id,line_no,account_id,debit,credit) values (:'rp',1,:'cash',7,0),(:'rp',2,:'inc',0,7);
select post_entry(:'rp') \g /dev/null
update fiscal_periods set locked_sections = '{receipts}' where fiscal_year_id=:'F' and code like '07.%';
select unpost_entry(:'rp');
select reverse_entry(:'rp', '2026-08-02') is not null as reversed;
update fiscal_periods set locked_sections = '{}' where fiscal_year_id=:'F' and code like '07.%';
reset role;
