-- حالات المتابعة على المستندات
\set ON_ERROR_STOP 0
\set C 'c0000000-0000-0000-0000-000000000001'
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into doc_statuses(company_id,kind,code,name,color,sort) values (:'C','sale','01','بانتظار التوقيع','#f59e0b',1) returning id as s1 \gset
insert into doc_statuses(company_id,kind,code,name,color,sort,is_final) values (:'C','sale','02','تم التسليم','#16a34a',2,true) returning id as s2 \gset
insert into doc_statuses(company_id,kind,code,name) values (:'C','purchase','01','وصلت البضاعة') returning id as p1 \gset
\echo == bad color (expected ERROR)
insert into doc_statuses(company_id,kind,code,name,color) values (:'C','sale','09','x','red');
select id as inv from invoices where company_id = :'C' and inv_type = 'sale' and status = 'posted' limit 1 \gset
select set_doc_follow('invoices', :'inv', :'s1', 'العميل بدّه نسخة موقّعة');
select set_doc_follow('invoices', :'inv', :'s2', null);
select s.name, f.kind from doc_follow f join doc_statuses s on s.id = f.status_id where f.doc_id = :'inv';
select count(*) as log_rows from doc_follow_log where doc_id = :'inv';
\echo == purchase status on sale invoice (expected ERROR)
select set_doc_follow('invoices', :'inv', :'p1', null);
\echo == direct write (expected ERROR)
insert into doc_follow(doc_id, company_id, doc_table, screen, kind) values (gen_random_uuid(), :'C', 'invoices', 'sales_invoices', 'sale');
select id as pinv from invoices where company_id = :'C' and inv_type = 'purchase' limit 1 \gset
\echo == employee without edit (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select set_doc_follow('invoices', :'pinv', null, null);
reset role;
