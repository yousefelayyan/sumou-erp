\set ON_ERROR_STOP 0
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
\echo == moving average: buy 10@4, sell 10, buy 10@6, return 2 @7
insert into items(id,company_id,code,name) values ('10000000-0000-0000-0000-0000000000d1',:'C','MV','صنف متحرك');
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,cash_account_id) select x.id::uuid,:'C',:'F',x.t,x.d::date,'cash',(select id from accounts where company_id=:'C' and code='1101') from (values
 ('20000000-0000-0000-0000-0000000000d1','purchase','2026-08-01'),('20000000-0000-0000-0000-0000000000d2','sale','2026-08-02'),('20000000-0000-0000-0000-0000000000d3','purchase','2026-08-03')) x(id,t,d);
insert into invoice_lines(invoice_id,item_id,description,qty,unit_price,tax_rate) values
 ('20000000-0000-0000-0000-0000000000d1','10000000-0000-0000-0000-0000000000d1','x',10,4,0),('20000000-0000-0000-0000-0000000000d2','10000000-0000-0000-0000-0000000000d1','x',10,9,0),('20000000-0000-0000-0000-0000000000d3','10000000-0000-0000-0000-0000000000d1','x',10,6,0);
select post_invoice('20000000-0000-0000-0000-0000000000d1') is not null, post_invoice('20000000-0000-0000-0000-0000000000d2') is not null, post_invoice('20000000-0000-0000-0000-0000000000d3') is not null;
select post_invoice_stock('20000000-0000-0000-0000-0000000000d1') is null, post_invoice_stock('20000000-0000-0000-0000-0000000000d2') is null, post_invoice_stock('20000000-0000-0000-0000-0000000000d3') is null;
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,cash_account_id,original_invoice_id) values ('20000000-0000-0000-0000-0000000000d4',:'C',:'F','purchase_return','2026-08-04','cash',(select id from accounts where company_id=:'C' and code='1101'),'20000000-0000-0000-0000-0000000000d3');
insert into invoice_lines(invoice_id,item_id,description,qty,unit_price,tax_rate) values ('20000000-0000-0000-0000-0000000000d4','10000000-0000-0000-0000-0000000000d1','x',2,7,0);
select post_invoice('20000000-0000-0000-0000-0000000000d4') is not null;
select post_invoice_stock('20000000-0000-0000-0000-0000000000d4') is null;
select item_avg_cost(:'C','10000000-0000-0000-0000-0000000000d1','2026-12-31') avg, (select sum(value) from rep_stock_balance(:'C','2026-12-31')) report_total,
 (select sum(l.debit-l.credit) from journal_lines l join journal_entries e on e.id=l.entry_id join accounts a on a.id=l.account_id where e.company_id=:'C' and a.code='1105') book_total;
\echo == payroll re-run after cancel
insert into payroll_runs(company_id,period,run_date) values (:'C','2026-05','2026-05-31');
select count(*) from payroll_runs where period='2026-05';
\echo == viewer cannot delete bank cleared
reset role;
insert into user_companies(user_id,company_id,group_id) select '22222222-2222-2222-2222-222222222222',:'C',id from user_groups where name='مشاهد' on conflict (user_id,company_id) do update set group_id=excluded.group_id;
update profiles set is_active=true where id='22222222-2222-2222-2222-222222222222';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select count(*) seen from bank_cleared;
delete from bank_cleared;
select (dash_kpis(:'C',:'F','2026-12-31') ? 'cash') viewer_has_cash;
reset role; select count(*) still from bank_cleared;
\echo == delete user who created a company
update companies set created_by='22222222-2222-2222-2222-222222222222' where id=:'C';
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select admin_delete_user('22222222-2222-2222-2222-222222222222');
reset role; select created_by from companies where id=:'C';
