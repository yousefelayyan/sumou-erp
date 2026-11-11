\set ON_ERROR_STOP 0
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,party_name) values ('20000000-0000-0000-0000-0000000000f1','c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','sale','2026-06-01','cash','x');
insert into invoice_lines(invoice_id,qty,unit_price,subtotal,tax_amount,tax_rate) values ('20000000-0000-0000-0000-0000000000f1',1,1,50000,8000,16);
update invoices set status='posted', total=58000 where id='20000000-0000-0000-0000-0000000000f1';
select inv_no,status,entry_id from invoices where id='20000000-0000-0000-0000-0000000000f1';
select * from rep_sales_tax('c0000000-0000-0000-0000-000000000001','2026-06-01','2026-06-30');
-- admin: reverse invoice entry via reverse_entry, then cancel invoice -> double reversal?
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select reverse_entry((select entry_id from invoices where inv_type='sale' and inv_no=1),'2026-06-02') is not null as rev_ok;
select cancel_invoice((select id from invoices where inv_type='sale' and inv_no=1),'2026-06-03');
select e.entry_no,e.status,e.description,e.total from journal_entries e where entry_type='invoice' order by created_at;
