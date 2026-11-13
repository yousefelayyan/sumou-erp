\set ON_ERROR_STOP 0
-- إيقاف البيع على العميل وفئته (المرحلة 71)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
select id as cu, account_id as acc from parties where company_id = :'C' and party_type = 'customer' and account_id is not null order by code limit 1 \gset
select start_date as fs from fiscal_years where id = :'F' \gset
insert into parties (company_id, party_type, code, name, account_id) values (:'C', 'customer', 'C711', 'عميل موقوف 71', :'acc') on conflict do nothing;
select id as c7 from parties where company_id = :'C' and code = 'C711' \gset
insert into party_categories (company_id, party_type, code, name) values (:'C', 'customer', 'K71', 'فئة موقوفة 71') on conflict do nothing;
select id as k7 from party_categories where company_id = :'C' and code = 'K71' \gset
-- الموظف بيرحّل (عنده صلاحية مبيعات بس مش تجاوز)
reset role;
update user_groups set permissions = permissions || '{"sales_invoices":{"view":true,"add":true,"edit":true,"post":true},"cheques":{"view":true,"add":true,"edit":true}}'::jsonb where id in (select group_id from user_companies where user_id = '22222222-2222-2222-2222-222222222222' and company_id = :'C');
update user_groups set permissions = permissions - 'credit_override' where id in (select group_id from user_companies where user_id = '22222222-2222-2222-2222-222222222222' and company_id = :'C');
update parties set stop_credit = true where id = :'c7';
update user_companies set branch_only = false where user_id = '22222222-2222-2222-2222-222222222222';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
insert into invoices (id, company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id) values ('20000000-0000-0000-0000-000000000711', :'C', :'F', 'sale', :'fs', 'credit', :'c7');
insert into invoice_lines (invoice_id, description, qty, unit_price, tax_rate) values ('20000000-0000-0000-0000-000000000711', 'خدمة', 1, 100, 0);
\echo == post credit to stopped customer (expected ERROR)
select post_invoice('20000000-0000-0000-0000-000000000711');
-- نقدي مسموح
insert into invoices (id, company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id, cash_account_id) select '20000000-0000-0000-0000-000000000712', :'C', :'F', 'sale', :'fs', 'cash', :'c7', id from accounts where company_id = :'C' and account_type = 'cash' and not is_group limit 1;
insert into invoice_lines (invoice_id, description, qty, unit_price, tax_rate) values ('20000000-0000-0000-0000-000000000712', 'خدمة', 1, 50, 0);
select post_invoice('20000000-0000-0000-0000-000000000712') is not null as cash_ok;
-- على الفئة: وقف الشيكات
reset role;
update parties set stop_credit = false, category_id = :'k7' where id = :'c7';
update party_categories set stop_cheques = true where id = :'k7';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select (party_stops(:'c7') ->> 'stop_cheques')::boolean as cat_flag;
\echo == cheque from stopped category (expected ERROR)
select register_cheque(jsonb_build_object('company_id', :'C', 'direction', 'in', 'cheque_no', '7101', 'amount', 20, 'party_id', :'c7', 'issue_date', :'fs', 'due_date', :'fs'));
select post_invoice('20000000-0000-0000-0000-000000000711') is not null as credit_ok_now;
-- رصيد مدين
reset role;
update party_categories set stop_cheques = false, stop_if_debit = true where id = :'k7';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
insert into invoices (id, company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id) values ('20000000-0000-0000-0000-000000000713', :'C', :'F', 'sale', :'fs', 'credit', :'c7');
insert into invoice_lines (invoice_id, description, qty, unit_price, tax_rate) values ('20000000-0000-0000-0000-000000000713', 'خدمة', 1, 10, 0);
\echo == customer with debit balance (expected ERROR)
select post_invoice('20000000-0000-0000-0000-000000000713');
-- المدير بيتجاوز
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select post_invoice('20000000-0000-0000-0000-000000000713') is not null as admin_ok;
reset role;
