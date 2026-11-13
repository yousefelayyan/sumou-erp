-- وثائق العملاء بتاريخ انتهاء
\set ON_ERROR_STOP 0
\set C 'c0000000-0000-0000-0000-000000000001'
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into party_doc_types(company_id,code,name,applies_to,required,on_missing) values (:'C','01','سجل تجاري','customer',true,'block') returning id as dt \gset
select p.id as cust from parties p where p.company_id = :'C' and p.party_type = 'customer' order by code limit 1 \gset
select problem from party_doc_issues(:'C', :'cust', '2026-06-01');
insert into party_documents(company_id,party_id,type_id,doc_no,issue_date,expiry_date) values (:'C',:'cust',:'dt','12345','2025-01-01','2026-03-31');
select problem from party_doc_issues(:'C', :'cust', '2026-06-01');
select count(*) as report_rows from party_docs_report(:'C', 30);
-- فحص الـ trigger كمستخدم مش مدير: بنستدعي الدالة بسجل وهمي
-- فاتورة مسودة للزبون وترحيلها كمستخدم بدون المدير
insert into invoices(company_id,fiscal_year_id,inv_type,inv_date,party_id,payment_type) values (:'C','f0000000-0000-0000-0000-000000000001','sale','2026-06-01',:'cust','credit') returning id as inv \gset
insert into invoice_lines(invoice_id,line_no,description,qty,unit_price,tax_rate) values (:'inv',1,'خدمة',1,10,16);
\echo == non-admin posting invoice for party with expired doc (expected ERROR)
reset role;
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select set_config('sumou.internal', public.internal_token(), false) \g /dev/null
update invoices set status = 'posted' where id = :'inv';
select set_config('sumou.internal', '', false) \g /dev/null
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
set role authenticated;
update party_documents set expiry_date = '2027-03-31' where party_id = :'cust';
select count(*) filter (where problem in ('missing','expired')) as blocking from party_doc_issues(:'C', :'cust', '2026-06-01');
delete from invoices where id = :'inv';
delete from party_documents where party_id = :'cust';
update party_doc_types set is_active = false where id = :'dt';
reset role;
