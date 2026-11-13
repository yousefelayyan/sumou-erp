-- سقف الائتمان وتوزيع الدفعات
\set ON_ERROR_STOP 0
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
insert into parties(id,company_id,party_type,code,name,credit_limit,account_id) values ('49000000-0000-0000-0000-000000000001',:'C','customer','C49','زبون 49',150,(select account_id from parties where company_id = :'C' and party_type = 'customer' limit 1)) on conflict do nothing;
update company_settings set credit_limit_mode = 'block' where company_id = :'C';
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,party_id) values
 ('49000000-0000-0000-0000-0000000000a1',:'C',:'F','sale','2026-05-01','credit','49000000-0000-0000-0000-000000000001'),
 ('49000000-0000-0000-0000-0000000000a2',:'C',:'F','sale','2026-05-02','credit','49000000-0000-0000-0000-000000000001'),
 ('49000000-0000-0000-0000-0000000000a3',:'C',:'F','sale','2026-05-03','credit','49000000-0000-0000-0000-000000000001');
insert into invoice_lines(invoice_id,description,qty,unit_price,tax_rate) values
 ('49000000-0000-0000-0000-0000000000a1','x',1,100,0),('49000000-0000-0000-0000-0000000000a2','x',1,40,0),('49000000-0000-0000-0000-0000000000a3','x',1,30,0);
select post_invoice('49000000-0000-0000-0000-0000000000a1') is not null as p1, post_invoice('49000000-0000-0000-0000-0000000000a2') is not null as p2;
-- الموظف بدون صلاحية تجاوز
reset role;
update user_groups set permissions = permissions || '{"sales_invoices":{"view":true,"add":true,"edit":true,"post":true},"receipt_vouchers":{"view":true,"add":true,"edit":true,"post":true}}' where id = (select group_id from user_companies where user_id = '22222222-2222-2222-2222-222222222222' and company_id = :'C');
update user_companies set branch_only = false where user_id = '22222222-2222-2222-2222-222222222222';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
\echo == over credit limit (expected ERROR)
select post_invoice('49000000-0000-0000-0000-0000000000a3');
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select post_invoice('49000000-0000-0000-0000-0000000000a3') is not null as admin_override;
-- سند قبض 120 من الزبون
select id as cash from accounts where company_id = :'C' and code = '1101' \gset
select account_id as ar from parties where id = '49000000-0000-0000-0000-000000000001' \gset
insert into journal_entries(id,company_id,fiscal_year_id,entry_type,entry_date,cash_account_id) values ('49000000-0000-0000-0000-0000000000e1',:'C',:'F','receipt','2026-05-10',:'cash');
insert into journal_lines(entry_id,line_no,account_id,party_id,debit,credit) values ('49000000-0000-0000-0000-0000000000e1',1,:'cash',null,120,0),('49000000-0000-0000-0000-0000000000e1',2,:'ar','49000000-0000-0000-0000-000000000001',0,120);
select post_entry('49000000-0000-0000-0000-0000000000e1');
select auto_allocate('49000000-0000-0000-0000-0000000000e1','49000000-0000-0000-0000-000000000001') as allocated;
select string_agg(coalesce(doc_code, inv_no::text) || ':' || remaining, ', ' order by inv_date) as open from party_open_invoices(:'C','49000000-0000-0000-0000-000000000001');
\echo == over allocate (expected ERROR)
select allocate_payment('49000000-0000-0000-0000-0000000000e1','49000000-0000-0000-0000-000000000001', jsonb_build_array(jsonb_build_object('invoice_id','49000000-0000-0000-0000-0000000000a1','amount',100), jsonb_build_object('invoice_id','49000000-0000-0000-0000-0000000000a2','amount',40)));
\echo == direct insert (expected ERROR)
insert into invoice_allocations(company_id,entry_id,invoice_id,amount) values (:'C','49000000-0000-0000-0000-0000000000e1','49000000-0000-0000-0000-0000000000a3',1);
-- عكس السند بيرجّع المتبقي
select reverse_entry('49000000-0000-0000-0000-0000000000e1','2026-05-11') is not null as reversed;
select sum(remaining) as remaining_after_reverse from party_open_invoices(:'C','49000000-0000-0000-0000-000000000001');
reset role;
update company_settings set credit_limit_mode = 'warn' where company_id = :'C';
