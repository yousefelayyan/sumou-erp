\set ON_ERROR_STOP 0
-- عمولة وسيلة الدفع بالفواتير (المرحلة 92)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
select id as wh from warehouses where company_id = :'C' order by code limit 1 \gset
select id as bank from accounts where company_id = :'C' and code = '1102' \gset
select id as exp from accounts where company_id = :'C' and category = 'expenses' and not is_group order by code limit 1 \gset
insert into lookups (id, company_id, kind, code, name, account_id, rate, commission_account_id) values ('92000000-0000-0000-0000-0000000000c1', :'C', 'payment_method', 'V92', 'فيزا 92', :'bank', 2, :'exp') on conflict (id) do nothing;
insert into items (id, company_id, code, name, item_type, sale_price, purchase_price, tax_rate) values ('92000000-0000-0000-0000-0000000000b1', :'C', 'S92', 'خدمة 92', 'service', 100, 0, 0) on conflict do nothing;
insert into invoices (id, company_id, fiscal_year_id, inv_type, inv_date, payment_type, cash_account_id, payment_method_id, pm_commission, warehouse_id)
  values ('92000000-0000-0000-0000-0000000000a1', :'C', :'F', 'sale', '2026-07-05', 'cash', :'bank', '92000000-0000-0000-0000-0000000000c1', 999, :'wh');
select pm_commission = 0 as forged_blocked from invoices where id = '92000000-0000-0000-0000-0000000000a1';
insert into invoice_lines (invoice_id, line_no, item_id, qty, unit_price, tax_rate, subtotal, line_total) values ('92000000-0000-0000-0000-0000000000a1', 1, '92000000-0000-0000-0000-0000000000b1', 5, 100, 0, 500, 500);
select post_invoice('92000000-0000-0000-0000-0000000000a1') is not null as posted;
select i.pm_commission as comm,
  (select debit from journal_lines where entry_id = i.entry_id and account_id = :'bank') as bank_net,
  (select debit from journal_lines where entry_id = i.entry_id and account_id = :'exp') as fee,
  (select abs(sum(debit) - sum(credit)) < 0.001 from journal_lines where entry_id = i.entry_id) as balanced
  from invoices i where i.id = '92000000-0000-0000-0000-0000000000a1';
\echo == method from another company (expected ERROR)
insert into invoices (company_id, fiscal_year_id, inv_type, inv_date, payment_type, cash_account_id, payment_method_id) values (:'C', :'F', 'sale', '2026-07-05', 'cash', :'bank', gen_random_uuid());
-- الآجل بيمسح الوسيلة
insert into invoices (id, company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id, payment_method_id) values ('92000000-0000-0000-0000-0000000000a2', :'C', :'F', 'sale', '2026-07-05', 'credit',
  (select id from parties where company_id = :'C' and party_type = 'customer' limit 1), '92000000-0000-0000-0000-0000000000c1');
select payment_method_id is null as credit_cleared from invoices where id = '92000000-0000-0000-0000-0000000000a2';
reset role;
