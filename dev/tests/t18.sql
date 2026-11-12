\set ON_ERROR_STOP 0
-- فحص الترحيل المنفصل وإلغاء الترحيل (المرحلة 18)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
select ensure_company_settings(:'C');
update company_settings set perpetual_inventory = true, posting = '{}' where company_id = :'C';
insert into items(id,company_id,code,name,sale_price) values ('10000000-0000-0000-0000-0000000000e1',:'C','PE1','صنف ترحيل',10) on conflict do nothing;
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,cash_account_id) values
 ('20000000-0000-0000-0000-0000000000e1',:'C',:'F','purchase','2026-07-01','cash',(select id from accounts where company_id=:'C' and code='1101')),
 ('20000000-0000-0000-0000-0000000000e2',:'C',:'F','sale','2026-07-02','cash',(select id from accounts where company_id=:'C' and code='1101'));
insert into invoice_lines(invoice_id,item_id,description,qty,unit_price,tax_rate) values
 ('20000000-0000-0000-0000-0000000000e1','10000000-0000-0000-0000-0000000000e1','x',10,5,0),
 ('20000000-0000-0000-0000-0000000000e2','10000000-0000-0000-0000-0000000000e1','x',4,10,0);

\echo == saving only: no stock moves, no entry
select status, stock_posted, entry_id is null no_entry, (select count(*) from stock_moves where source_id=i.id) moves from invoices i where id='20000000-0000-0000-0000-0000000000e1';
\echo == user cannot set stock_posted directly
update invoices set stock_posted = true where id='20000000-0000-0000-0000-0000000000e1' returning stock_posted;

\echo == stock first, then accounting
select post_invoice_stock('20000000-0000-0000-0000-0000000000e1') is null;
select (select count(*) from stock_moves where source_id='20000000-0000-0000-0000-0000000000e1') moves, cogs_entry_id is null no_cogs_yet from invoices where id='20000000-0000-0000-0000-0000000000e1';
\echo == edit after stock posting rejected (expected ERROR)
update invoices set notes='x' where id='20000000-0000-0000-0000-0000000000e1';
update invoice_lines set qty=11 where invoice_id='20000000-0000-0000-0000-0000000000e1';
\echo == double stock posting rejected (expected ERROR)
select post_invoice_stock('20000000-0000-0000-0000-0000000000e1');
select post_invoice('20000000-0000-0000-0000-0000000000e1') is not null;
select status, cogs_entry_id is not null has_cogs from invoices where id='20000000-0000-0000-0000-0000000000e1';

\echo == sale: accounting first, then stock (COGS 4 x 5 = 20)
select post_invoice('20000000-0000-0000-0000-0000000000e2') is not null;
select post_invoice_stock('20000000-0000-0000-0000-0000000000e2') is null;
select e.total from invoices i join journal_entries e on e.id=i.cogs_entry_id where i.id='20000000-0000-0000-0000-0000000000e2';

\echo == employee without unpost right rejected (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select unpost_invoice('20000000-0000-0000-0000-0000000000e2','gl');
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null

\echo == unpost accounting of the sale: entry and COGS gone, stock stays
select unpost_invoice('20000000-0000-0000-0000-0000000000e2','gl');
select status, stock_posted, entry_id is null, cogs_entry_id is null, (select count(*) from stock_moves where source_id=i.id) moves from invoices i where id='20000000-0000-0000-0000-0000000000e2';
\echo == unpost stock: moves gone, invoice editable again
select unpost_invoice('20000000-0000-0000-0000-0000000000e2','stock');
update invoices set notes='editable again' where id='20000000-0000-0000-0000-0000000000e2' returning notes;
\echo == re-post both works
select post_invoice('20000000-0000-0000-0000-0000000000e2') is not null, post_invoice_stock('20000000-0000-0000-0000-0000000000e2') is null;
select (select count(*) from stock_moves where source_id='20000000-0000-0000-0000-0000000000e2') moves, (select count(*) from journal_entries e where e.id in (i.entry_id, i.cogs_entry_id) and e.status='posted') entries from invoices i where id='20000000-0000-0000-0000-0000000000e2';

\echo == posting flags: sales not to stock → rejected (expected ERROR)
update company_settings set posting = '{"sale":{"stock":false},"journal":{"gl":false}}' where company_id=:'C';
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,cash_account_id) values
 ('20000000-0000-0000-0000-0000000000e3',:'C',:'F','sale','2026-07-03','cash',(select id from accounts where company_id=:'C' and code='1101'));
insert into invoice_lines(invoice_id,item_id,description,qty,unit_price,tax_rate) values ('20000000-0000-0000-0000-0000000000e3','10000000-0000-0000-0000-0000000000e1','x',1,10,0);
select post_invoice_stock('20000000-0000-0000-0000-0000000000e3');
\echo == journal vouchers not to accounting → rejected (expected ERROR)
insert into journal_entries(id,company_id,fiscal_year_id,entry_type,entry_date,description) values ('40000000-0000-0000-0000-0000000000e1',:'C',:'F','journal','2026-07-04','ترحيل');
insert into journal_lines(entry_id,line_no,account_id,debit,credit) values
 ('40000000-0000-0000-0000-0000000000e1',1,(select id from accounts where company_id=:'C' and code='1101'),5,0),
 ('40000000-0000-0000-0000-0000000000e1',2,(select id from accounts where company_id=:'C' and code='4101'),0,5);
select post_entry('40000000-0000-0000-0000-0000000000e1');
update company_settings set posting = '{}' where company_id=:'C';
select post_entry('40000000-0000-0000-0000-0000000000e1');
\echo == unpost a journal voucher: back to draft, editable
select unpost_entry('40000000-0000-0000-0000-0000000000e1');
update journal_entries set description='معدّل' where id='40000000-0000-0000-0000-0000000000e1' returning status, description;
\echo == invoice journal cannot be unposted as a voucher (expected ERROR)
select unpost_entry((select entry_id from invoices where id='20000000-0000-0000-0000-0000000000e2'));

\echo == stock doc: stock then accounting, unpost order enforced
insert into stock_docs(id,company_id,doc_type,doc_date,warehouse_id) values ('30000000-0000-0000-0000-0000000000e1',:'C','in','2026-07-05',default_warehouse(:'C'));
insert into stock_doc_lines(doc_id,item_id,qty,unit_cost) values ('30000000-0000-0000-0000-0000000000e1','10000000-0000-0000-0000-0000000000e1',2,5);
\echo == accounting before stock rejected (expected ERROR)
select post_stock_doc_gl('30000000-0000-0000-0000-0000000000e1');
select post_stock_doc('30000000-0000-0000-0000-0000000000e1');
select entry_id is null no_entry_yet from stock_docs where id='30000000-0000-0000-0000-0000000000e1';
select post_stock_doc_gl('30000000-0000-0000-0000-0000000000e1') is not null;
\echo == unpost stock before accounting rejected (expected ERROR)
select unpost_stock_doc('30000000-0000-0000-0000-0000000000e1','stock');
select unpost_stock_doc('30000000-0000-0000-0000-0000000000e1','gl');
select unpost_stock_doc('30000000-0000-0000-0000-0000000000e1','stock');
select status, entry_id is null, (select count(*) from stock_moves where source_id=d.id) from stock_docs d where id='30000000-0000-0000-0000-0000000000e1';

\echo == group permission with unpost key works for employee
reset role;
insert into user_groups(id,name,permissions) values ('6c000000-0000-0000-0000-0000000000e1','محاسب مع إلغاء ترحيل','{"journal_entries":{"view":true,"add":true,"edit":true,"post":true,"unpost":true}}') on conflict (id) do nothing;
insert into auth.users(id,email) values ('22222222-2222-2222-2222-222222222222','emp@x.com') on conflict do nothing;
insert into profiles(id,email,is_active) values ('22222222-2222-2222-2222-222222222222','emp@x.com',true) on conflict (id) do update set is_active = true, is_admin = false;
delete from user_companies where user_id='22222222-2222-2222-2222-222222222222' and company_id=:'C';
insert into user_companies(user_id,company_id,group_id) values ('22222222-2222-2222-2222-222222222222',:'C','6c000000-0000-0000-0000-0000000000e1');

set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select post_entry('40000000-0000-0000-0000-0000000000e1');
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select unpost_entry('40000000-0000-0000-0000-0000000000e1');
select status from journal_entries where id='40000000-0000-0000-0000-0000000000e1';
reset role;
delete from user_companies where user_id='22222222-2222-2222-2222-222222222222' and company_id=:'C';
