\set ON_ERROR_STOP 0
-- تقارير تحصيل الفواتير (المرحلة 72)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
insert into parties(id,company_id,party_type,code,name,account_id) values ('72000000-0000-0000-0000-000000000001',:'C','customer','C72','زبون 72',(select account_id from parties where company_id = :'C' and party_type = 'customer' and account_id is not null limit 1)) on conflict do nothing;
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,due_date,payment_type,party_id) values
 ('72000000-0000-0000-0000-0000000000a1',:'C',:'F','sale','2026-03-01','2026-03-31','credit','72000000-0000-0000-0000-000000000001'),
 ('72000000-0000-0000-0000-0000000000a2',:'C',:'F','sale','2026-03-05','2026-04-04','credit','72000000-0000-0000-0000-000000000001');
insert into invoice_lines(invoice_id,description,qty,unit_price,tax_rate) values ('72000000-0000-0000-0000-0000000000a1','x',1,100,0),('72000000-0000-0000-0000-0000000000a2','x',1,60,0);
select post_invoice('72000000-0000-0000-0000-0000000000a1') is not null and post_invoice('72000000-0000-0000-0000-0000000000a2') is not null as posted;
-- دفعة 60 بعد 11 يوم، و 60 بعد 51 يوم
select id as cash from accounts where company_id = :'C' and code = '1101' \gset
select account_id as ar from parties where id = '72000000-0000-0000-0000-000000000001' \gset
insert into journal_entries(id,company_id,fiscal_year_id,entry_type,entry_date,cash_account_id) values
 ('72000000-0000-0000-0000-0000000000e1',:'C',:'F','receipt','2026-03-12',:'cash'), ('72000000-0000-0000-0000-0000000000e2',:'C',:'F','receipt','2026-04-21',:'cash');
insert into journal_lines(entry_id,line_no,account_id,party_id,debit,credit) values
 ('72000000-0000-0000-0000-0000000000e1',1,:'cash',null,60,0),('72000000-0000-0000-0000-0000000000e1',2,:'ar','72000000-0000-0000-0000-000000000001',0,60),
 ('72000000-0000-0000-0000-0000000000e2',1,:'cash',null,60,0),('72000000-0000-0000-0000-0000000000e2',2,:'ar','72000000-0000-0000-0000-000000000001',0,60);
select post_entry('72000000-0000-0000-0000-0000000000e1') is not null and post_entry('72000000-0000-0000-0000-0000000000e2') is not null as rec;
select auto_allocate('72000000-0000-0000-0000-0000000000e1','72000000-0000-0000-0000-000000000001') as a1, auto_allocate('72000000-0000-0000-0000-0000000000e2','72000000-0000-0000-0000-000000000001') as a2;
-- الأولى (100): 60 بيوم 11 و 40 بيوم 51 → موزون 27، سداد كامل 51، تأخير 21
select coalesce(doc_code, inv_no::text) is not null as ok, collected, remaining, avg_days, full_days, late_days
  from rep_invoice_collection(:'C', 'customer', '2026-03-01', '2026-03-31') where party_id = '72000000-0000-0000-0000-000000000001' order by inv_date;
select count(*) as open_cnt, sum(remaining) as open_amt from rep_open_invoices(:'C', 'customer') where party_id = '72000000-0000-0000-0000-000000000001';
-- الموظف بدون صلاحيات
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
reset role;
update user_groups set permissions = permissions - 'reports' - 'branch_reports' - 'sales_invoices' - 'receipt_vouchers' where id = (select group_id from user_companies where user_id = '22222222-2222-2222-2222-222222222222' and company_id = :'C');
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
\echo == employee without permission (expected ERROR)
select count(*) from rep_open_invoices(:'C', 'customer');
reset role;
