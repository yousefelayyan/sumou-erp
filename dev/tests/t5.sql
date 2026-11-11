set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select ensure_company_settings('c0000000-0000-0000-0000-000000000001');
insert into items(id,company_id,code,name,sale_price) values ('10000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000001','I1','خدمة استشارة',100);
-- credit sale to C0001, 2 x 100, discount 10, 16%
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,party_id) select '20000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','sale','2026-05-01','credit',id from parties where code='C0001';
insert into invoice_lines(invoice_id,line_no,item_id,description,qty,unit_price,discount,tax_rate) values ('20000000-0000-0000-0000-000000000001',1,'10000000-0000-0000-0000-000000000001','استشارة',2,100,10,16),('20000000-0000-0000-0000-000000000001',2,null,'معفاة',1,50,0,0);
select post_invoice('20000000-0000-0000-0000-000000000001') is not null as posted;
select inv_no,status,subtotal,tax_total,total from invoices;
select a.code, l.debit, l.credit, l.party_id is not null as has_party from journal_lines l join accounts a on a.id=l.account_id join invoices i on i.entry_id=l.entry_id order by l.line_no;
-- purchase cash with tax-inclusive price 116
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,prices_include_tax) values ('20000000-0000-0000-0000-000000000002','c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','purchase','2026-05-02','cash',true);
insert into invoice_lines(invoice_id,description,qty,unit_price,tax_rate) values ('20000000-0000-0000-0000-000000000002','قرطاسية',1,116,16);
select post_invoice('20000000-0000-0000-0000-000000000002') is not null;
select inv_type,subtotal,tax_total,total from invoices where id='20000000-0000-0000-0000-000000000002';
update invoices set notes='x' where id='20000000-0000-0000-0000-000000000002';
select cancel_invoice('20000000-0000-0000-0000-000000000002','2026-05-03');
select inv_type,status from invoices order by inv_type;
select * from rep_sales_tax('c0000000-0000-0000-0000-000000000001','2026-01-01','2026-12-31');
select a.code,sum(l.debit) d,sum(l.credit) c from journal_lines l join journal_entries e on e.id=l.entry_id join accounts a on a.id=l.account_id where e.status in ('posted','reversed') group by a.code order by a.code;
