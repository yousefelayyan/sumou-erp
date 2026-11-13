\set ON_ERROR_STOP 0
-- مندوب لكل سطر وهيكل المندوبين (المرحلة 77)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
insert into lookups (id, company_id, kind, code, name, rep_role) values ('77000000-0000-0000-0000-0000000000e1', :'C', 'sales_rep', 'M77', 'مدير 77', 'manager') on conflict do nothing;
insert into lookups (id, company_id, kind, code, name, rep_role, supervisor_id) values ('77000000-0000-0000-0000-0000000000e2', :'C', 'sales_rep', 'A77', 'مندوب أ 77', 'rep', '77000000-0000-0000-0000-0000000000e1'),
 ('77000000-0000-0000-0000-0000000000e3', :'C', 'sales_rep', 'B77', 'مندوب ب 77', 'rep', '77000000-0000-0000-0000-0000000000e1') on conflict do nothing;
\echo == hierarchy cycle (expected ERROR)
update lookups set supervisor_id = '77000000-0000-0000-0000-0000000000e2' where id = '77000000-0000-0000-0000-0000000000e1';
select id as cu from parties where company_id = :'C' and party_type = 'customer' and account_id is not null and not stop_credit and not stop_if_debit order by code limit 1 \gset
insert into invoices (id, company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id, sales_rep_id) values ('77000000-0000-0000-0000-0000000000a1', :'C', :'F', 'sale', '2026-10-05', 'credit', :'cu', '77000000-0000-0000-0000-0000000000e2');
insert into invoice_lines (invoice_id, line_no, description, qty, unit_price, tax_rate, sales_rep_id) values
 ('77000000-0000-0000-0000-0000000000a1', 1, 'أ', 1, 300, 0, null), ('77000000-0000-0000-0000-0000000000a1', 2, 'ب', 1, 200, 0, '77000000-0000-0000-0000-0000000000e3');
select post_invoice('77000000-0000-0000-0000-0000000000a1') is not null as posted;
select l.code, c.net_sales from rep_commissions(:'C', '2026-10-01', '2026-10-31') c join lookups l on l.id = c.rep_id where l.code in ('A77','B77') order by 1;
\echo == line rep on purchase ignored / other company rep (expected ERROR)
insert into invoice_lines (invoice_id, line_no, description, qty, unit_price, tax_rate, sales_rep_id) select '77000000-0000-0000-0000-0000000000a1', 3, 'x', 1, 1, 0, id from lookups where company_id <> :'C' and kind = 'sales_rep' limit 1;
insert into invoice_lines (invoice_id, line_no, description, qty, unit_price, tax_rate, sales_rep_id) values ('77000000-0000-0000-0000-0000000000a1', 3, 'x', 1, 1, 0, '00000000-0000-0000-0000-000000000000');
reset role;
