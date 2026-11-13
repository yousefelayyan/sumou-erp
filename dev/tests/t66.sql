\set ON_ERROR_STOP 0
-- الإشعارات المدينة والدائنة (المرحلة 66)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
select i.id as inv, i.party_id as cust from invoices i where i.company_id = :'C' and i.inv_type = 'sale' and i.status = 'posted' and i.payment_type = 'credit' and i.party_id is not null order by i.inv_date limit 1 \gset
select id as disc from accounts where company_id = :'C' and category = 'expenses' and not is_group order by code limit 1 \gset
select coalesce(sum(remaining), 0) as rem0 from party_open_invoices(:'C', :'cust', null) where invoice_id = :'inv' \gset
-- إشعار دائن للعميل 10 + 16% على فاتورته
select note_save(jsonb_build_object('company_id', :'C', 'party_type', 'customer', 'note_kind', 'credit', 'party_id', :'cust', 'invoice_id', :'inv', 'account_id', :'disc', 'amount', 10, 'tax_rate', 16, 'description', 'خصم لاحق')) as n1 \gset
select note_no, amount, tax_amount, total, status from party_notes where id = :'n1';
select note_post(:'n1') is not null as posted;
select e.entry_type, e.status, (select sum(debit) from journal_lines where entry_id = e.id) d, (select sum(credit) from journal_lines where entry_id = e.id) c
  from party_notes n join journal_entries e on e.id = n.entry_id where n.id = :'n1';
select round(:rem0 - coalesce(sum(remaining), 0), 3) as allocated from party_open_invoices(:'C', :'cust', null) where invoice_id = :'inv';
\echo == unpost note entry from journal screen (expected ERROR)
select unpost_entry((select entry_id from party_notes where id = :'n1'));
\echo == edit posted note (expected ERROR)
select note_save(jsonb_build_object('id', :'n1', 'party_id', :'cust', 'account_id', :'disc', 'amount', 5));
select note_cancel(:'n1');
select status, cancel_entry_id is not null as reversed from party_notes where id = :'n1';
select note_post(note_save(jsonb_build_object('company_id', :'C', 'party_type', 'customer', 'note_kind', 'debit', 'party_id', :'cust', 'account_id', :'disc', 'amount', 50, 'tax_rate', 16))) is not null as dn_posted;
select inv_type, tax from rep_sales_tax(:'C', '2000-01-01', '2100-01-01') where inv_type like 'sale_%n';
select count(*) as sale_cn_rows from rep_sales_tax(:'C', '2000-01-01', '2100-01-01') where inv_type = 'sale_cn';
-- إشعار مدين لمورد، مسودة بتنحذف
select id as sup from parties where company_id = :'C' and party_type = 'supplier' and account_id is not null order by code limit 1 \gset
select note_save(jsonb_build_object('company_id', :'C', 'party_type', 'supplier', 'note_kind', 'debit', 'party_id', :'sup', 'account_id', :'disc', 'amount', 20)) as n2 \gset
select note_post(note_save(jsonb_build_object('company_id', :'C', 'party_type', 'supplier', 'note_kind', 'debit', 'party_id', :'sup', 'account_id', :'disc', 'amount', 100, 'tax_rate', 16))) as sdn \gset
select (select sum(debit) from journal_lines where entry_id = :'sdn') = (select sum(credit) from journal_lines where entry_id = :'sdn') as supplier_dn_balanced;
select note_post(note_save(jsonb_build_object('company_id', :'C', 'party_type', 'supplier', 'note_kind', 'credit', 'party_id', :'sup', 'account_id', :'disc', 'amount', 100, 'tax_rate', 16))) as scn \gset
select (select sum(debit) from journal_lines where entry_id = :'scn') = (select sum(credit) from journal_lines where entry_id = :'scn') as supplier_cn_balanced;
select note_delete(:'n2');
select count(*) as deleted from party_notes where id = :'n2';
\echo == customer note on a supplier (expected ERROR)
select note_save(jsonb_build_object('company_id', :'C', 'party_type', 'customer', 'note_kind', 'debit', 'party_id', :'sup', 'account_id', :'disc', 'amount', 20));
\echo == direct insert (expected ERROR)
insert into party_notes (company_id, fiscal_year_id, party_type, note_kind, note_no, note_date, party_id, account_id, amount) values (:'C', 'f0000000-0000-0000-0000-000000000001', 'customer', 'debit', 99, current_date, :'cust', :'disc', 1);
select count(*) > 0 as aging_rows from rep_party_aging_docs(:'C', 'f0000000-0000-0000-0000-000000000001', 'customer', '2100-01-01');
reset role;
