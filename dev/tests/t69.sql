\set ON_ERROR_STOP 0
-- فاتورة شراء على أكثر من مورد (المرحلة 69)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
\set INV '20000000-0000-0000-0000-000000000691'
select id as s1 from parties where company_id = :'C' and party_type = 'supplier' and account_id is not null order by code limit 1 \gset
insert into parties (company_id, party_type, code, name, account_id) select :'C', 'supplier', x.c, x.n, (select account_id from parties where id = :'s1') from (values ('S691', 'مورد شحن 69'), ('S692', 'مخلّص جمركي 69')) x(c, n) on conflict do nothing;
select id as s2 from parties where company_id = :'C' and code = 'S691' \gset
select id as s3 from parties where company_id = :'C' and code = 'S692' \gset
insert into invoices (id, company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id, tax_mode) values (:'INV', :'C', :'F', 'purchase', '2026-06-01', 'credit', :'s1', 'exempt');
insert into invoice_lines (invoice_id, description, qty, unit_price, tax_rate) values (:'INV', 'خدمات استيراد', 1, 1000, 0);
insert into invoice_party_splits (invoice_id, line_no, party_id, amount, supplier_ref) values (:'INV', 1, :'s2', 150, 'F-77'), (:'INV', 2, :'s3', 50, null);
\echo == main supplier as split (expected ERROR)
insert into invoice_party_splits (invoice_id, line_no, party_id, amount) values (:'INV', 3, :'s1', 10);
select post_invoice(:'INV') is not null as posted;
select p.code, l.credit from journal_lines l join parties p on p.id = l.party_id join invoices i on i.entry_id = l.entry_id where i.id = :'INV' order by p.code;
select (select sum(debit) from journal_lines l join invoices i on i.entry_id = l.entry_id where i.id = :'INV') = (select sum(credit) from journal_lines l join invoices i on i.entry_id = l.entry_id where i.id = :'INV') as balanced;
select total, remaining from party_open_invoices(:'C', :'s1', null) where invoice_id = :'INV';
\echo == edit split after posting (expected ERROR)
update invoice_party_splits set amount = 1 where invoice_id = :'INV';
-- إلغاء الفاتورة: القيد العكسي بيرجّع كل مورد
select cancel_invoice(:'INV', '2026-06-02') is null as cancelled;
select p.code, sum(l.credit - l.debit) as net from journal_lines l join journal_entries e on e.id = l.entry_id join parties p on p.id = l.party_id
 where l.party_id in (:'s1', :'s2', :'s3') and (e.id = (select entry_id from invoices where id = :'INV') or e.reversal_of = (select entry_id from invoices where id = :'INV')) group by p.code order by p.code;
\echo == split on a sale invoice (expected ERROR)
insert into invoice_party_splits (invoice_id, party_id, amount) select id, :'s2', 5 from invoices where company_id = :'C' and inv_type = 'sale' and status = 'draft' limit 1;
\echo == splits >= total (expected ERROR)
insert into invoices (id, company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id) values ('20000000-0000-0000-0000-000000000692', :'C', :'F', 'purchase', '2026-06-01', 'credit', :'s1');
insert into invoice_lines (invoice_id, description, qty, unit_price, tax_rate) values ('20000000-0000-0000-0000-000000000692', 'x', 1, 100, 0);
insert into invoice_party_splits (invoice_id, party_id, amount) values ('20000000-0000-0000-0000-000000000692', :'s2', 100);
select post_invoice('20000000-0000-0000-0000-000000000692');
reset role;
