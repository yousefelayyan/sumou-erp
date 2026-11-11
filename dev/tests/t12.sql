\set ON_ERROR_STOP 0
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
select ensure_company_settings(:'C');
update company_settings set perpetual_inventory = true where company_id = :'C';
insert into items(id,company_id,code,name,sale_price) values ('10000000-0000-0000-0000-0000000000c1',:'C','P1','صنف مستمر',10);
-- purchase 10 @4 then 10 @6 => avg 5
insert into invoices(id,company_id,fiscal_year_id,inv_type,inv_date,payment_type,cash_account_id) values
 ('20000000-0000-0000-0000-0000000000c1',:'C',:'F','purchase','2026-04-01','cash',(select id from accounts where company_id=:'C' and code='1101')),
 ('20000000-0000-0000-0000-0000000000c2',:'C',:'F','purchase','2026-04-02','cash',(select id from accounts where company_id=:'C' and code='1101')),
 ('20000000-0000-0000-0000-0000000000c3',:'C',:'F','sale','2026-04-03','cash',(select id from accounts where company_id=:'C' and code='1101'));
insert into invoice_lines(invoice_id,item_id,description,qty,unit_price,tax_rate) values
 ('20000000-0000-0000-0000-0000000000c1','10000000-0000-0000-0000-0000000000c1','x',10,4,0),
 ('20000000-0000-0000-0000-0000000000c2','10000000-0000-0000-0000-0000000000c1','x',10,6,0),
 ('20000000-0000-0000-0000-0000000000c3','10000000-0000-0000-0000-0000000000c1','x',8,10,16);
select post_invoice('20000000-0000-0000-0000-0000000000c1') is not null, post_invoice('20000000-0000-0000-0000-0000000000c2') is not null, post_invoice('20000000-0000-0000-0000-0000000000c3') is not null;
select a.code, l.debit, l.credit, l.description from journal_lines l join accounts a on a.id=l.account_id join invoices i on i.entry_id=l.entry_id where i.id='20000000-0000-0000-0000-0000000000c3' order by l.line_no;
select item_avg_cost(:'C','10000000-0000-0000-0000-0000000000c1','2026-12-31') avg;
-- count: actual 10 (book 12) → -2 @5 = 10
insert into stock_docs(id,company_id,doc_type,doc_date,warehouse_id) values ('30000000-0000-0000-0000-0000000000c1',:'C','count','2026-04-05',default_warehouse(:'C'));
insert into stock_doc_lines(doc_id,item_id,counted_qty) values ('30000000-0000-0000-0000-0000000000c1','10000000-0000-0000-0000-0000000000c1',10);
select post_stock_doc('30000000-0000-0000-0000-0000000000c1');
select a.code, l.debit, l.credit from journal_lines l join accounts a on a.id=l.account_id join stock_docs d on d.entry_id=l.entry_id where d.id='30000000-0000-0000-0000-0000000000c1';
-- account balances: inventory 1105 should = 10*5 = 50
select a.code, sum(l.debit-l.credit) bal from journal_lines l join accounts a on a.id=l.account_id join journal_entries e on e.id=l.entry_id where e.company_id=:'C' and a.code in ('1105','5101','5104') and e.status in ('posted','reversed') group by 1 order by 1;
select sum(value) from rep_stock_balance(:'C','2026-12-31') where item_id='10000000-0000-0000-0000-0000000000c1';
-- cancel sale → inventory back to 90? (10 after count + 8 = 18 *5 = 90)
select cancel_invoice('20000000-0000-0000-0000-0000000000c3','2026-04-06');
select a.code, sum(l.debit-l.credit) bal from journal_lines l join accounts a on a.id=l.account_id join journal_entries e on e.id=l.entry_id where e.company_id=:'C' and a.code in ('1105','5104') group by 1 order by 1;
select sum(qty) q, sum(value) v from rep_stock_balance(:'C','2026-12-31') where item_id='10000000-0000-0000-0000-0000000000c1';
select reverse_entry(entry_id) from stock_docs where id='30000000-0000-0000-0000-0000000000c1';
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description) values (:'C',:'F','stock','2026-04-01','x');
-- trial balance still balances
select sum(debit-credit) from journal_lines l join journal_entries e on e.id=l.entry_id where e.company_id=:'C';
