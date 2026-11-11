\set ON_ERROR_STOP 0
update fiscal_years set start_date='2026-01-01';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,party_name) values ('20000000-0000-0000-0000-0000000000f9','c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','sale','2026-06-01','cash','y');
update invoice_lines set invoice_id='20000000-0000-0000-0000-0000000000f9' where invoice_id=(select id from invoices where inv_type='sale' and inv_no=1) and line_no=1;
select i.inv_no,i.status,count(l.*) from invoices i left join invoice_lines l on l.invoice_id=i.id group by 1,2 order by 1;
