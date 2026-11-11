\set ON_ERROR_STOP 0
-- فحص طريقة الترقيم (المرحلة 16)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
select ensure_company_settings(:'C');

\echo == default: journal per year, code = number
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description) values (:'C',:'F','journal','2026-03-01','n1') returning entry_no, doc_code, seq_key like 'Y%' as yearly;

\echo == journal: monthly reset, prefix JV-, 4 digits, year 2 + month
update company_settings set numbering = jsonb_build_object('journal', jsonb_build_object('mode','auto','reset','month','digits',4,'pad','0','sep','/','prefix','JV-','add_year',true,'year_digits',2,'add_month',true)) where company_id=:'C';
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description) values (:'C',:'F','journal','2026-04-05','a') returning entry_no, doc_code;
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description) values (:'C',:'F','journal','2026-04-06','b') returning entry_no, doc_code;
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description) values (:'C',:'F','journal','2026-05-01','c') returning entry_no, doc_code;

\echo == auto mode ignores a number sent by the user (gets 3, not 999)
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description,entry_no) values (:'C',:'F','journal','2026-04-07','auto999',999) returning entry_no, doc_code;
update company_settings set numbering = jsonb_set(numbering, '{journal,mode}', '"manual"') where company_id=:'C';
\echo == manual number accepted, duplicate in same month rejected (expected ERROR)
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description,entry_no) values (:'C',:'F','journal','2026-05-10','m',50) returning entry_no, doc_code;
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description,entry_no) values (:'C',:'F','journal','2026-05-11','m2',50);
\echo == zero number rejected (expected ERROR)
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description,entry_no) values (:'C',:'F','journal','2026-05-11','z',0);

\echo == user cannot forge seq_key / doc_code
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description,seq_key,doc_code) values (:'C',:'F','journal','2026-05-12','f','hack','HACK') returning entry_no, doc_code, seq_key <> 'hack' as key_ok;
update journal_entries set doc_code='HACK2', seq_key='x' where description='f' returning doc_code, seq_key <> 'x' as key_ok;
\echo == changing number on draft recomputes code
update journal_entries set entry_no=77 where description='f' returning doc_code;

\echo == draft moved to another month gets a number from that month
update journal_entries set entry_date='2026-06-15' where description='a' returning entry_no, doc_code;
\echo == html in prefix is stripped
update company_settings set numbering = jsonb_build_object('payment', jsonb_build_object('prefix','<svg onload=','suffix',',alert(1)>')) where company_id=:'C';
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description,cash_account_id) values (:'C',:'F','payment','2026-05-12','x',(select id from accounts where company_id=:'C' and code='1101')) returning doc_code, doc_code !~ '[<>]' as safe;
\echo == changing reset rule skips visually duplicate codes
update company_settings set numbering = '{}' where company_id=:'C';
insert into stock_docs(company_id,doc_type,doc_date,warehouse_id) select :'C','out','2026-06-05',id from warehouses where company_id=:'C' order by code limit 1 returning doc_no, doc_code;
insert into stock_docs(company_id,doc_type,doc_date,warehouse_id) select :'C','out','2026-06-06',id from warehouses where company_id=:'C' order by code limit 1 returning doc_no, doc_code;
update company_settings set numbering = '{"stock_out":{"reset":"year"}}' where company_id=:'C';
insert into stock_docs(company_id,doc_type,doc_date,warehouse_id) select :'C','out','2026-06-07',id from warehouses where company_id=:'C' order by code limit 1 returning doc_no, doc_code;
\echo == huge number rejected (expected ERROR)
update company_settings set numbering = '{"journal":{"mode":"manual"}}' where company_id=:'C';
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description,entry_no) values (:'C',:'F','journal','2026-05-11','big',2000000000);
\echo == bad settings are sanitized
update company_settings set numbering = jsonb_build_object('receipt', jsonb_build_object('reset','weird','digits','999','prefix', repeat('x',40),'add_year','yes')) where company_id=:'C';
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description,cash_account_id) values (:'C',:'F','receipt','2026-05-12','r',(select id from accounts where company_id=:'C' and code='1101')) returning entry_no, length(doc_code) <= 15+12 as sane;

\echo == invoices: split by cost center with code
reset role;
insert into cost_centers(id,company_id,code,name) values ('cc000000-0000-0000-0000-000000000001',:'C','A1','فرع 1'),('cc000000-0000-0000-0000-000000000002',:'C','B2','فرع 2') on conflict do nothing;
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
update company_settings set numbering = jsonb_build_object('sale', jsonb_build_object('reset','year','split','cost_center','digits',3,'sep','-','add_split',true)) where company_id=:'C';
insert into invoices(company_id,fiscal_year_id,inv_type,inv_date,payment_type,cash_account_id,cost_center_id) values
 (:'C',:'F','sale','2026-06-01','cash',(select id from accounts where company_id=:'C' and code='1101'),'cc000000-0000-0000-0000-000000000001'),
 (:'C',:'F','sale','2026-06-02','cash',(select id from accounts where company_id=:'C' and code='1101'),'cc000000-0000-0000-0000-000000000001'),
 (:'C',:'F','sale','2026-06-03','cash',(select id from accounts where company_id=:'C' and code='1101'),'cc000000-0000-0000-0000-000000000002') returning inv_no, doc_code;

\echo == stock: split by warehouse
update company_settings set numbering = jsonb_build_object('stock_in', jsonb_build_object('split','warehouse','add_split',true,'prefix','IN','sep','-')) where company_id=:'C';
insert into stock_docs(company_id,doc_type,doc_date,warehouse_id) select :'C','in','2026-06-05',id from warehouses where company_id=:'C' order by code limit 1 returning doc_no, doc_code;

\echo == reports return doc_code
select count(*) > 0 has_rows from rep_journal(:'C',:'F','2026-01-01','2026-12-31') where doc_code is not null;
select count(*) pending_with_code from pending_posts(:'C') where doc_code is not null;

\echo == other user without companies.edit cannot change numbering (0 rows)
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
update company_settings set numbering='{}' where company_id=:'C';
reset role; select numbering ? 'stock_in' still_set from company_settings where company_id=:'C';
update company_settings set numbering='{}' where company_id=:'C';

\echo == item categories
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into item_categories(id,company_id,code,name) values ('1c000000-0000-0000-0000-000000000001',:'C','01','مشروبات') returning code, name;
insert into items(company_id,code,name,category_id) values (:'C','01.000001','ماء','1c000000-0000-0000-0000-000000000001') returning code;
\echo == empty name rejected (expected ERROR)
insert into item_categories(company_id,code,name) values (:'C','02','  ');
\echo == category of another company rejected (expected ERROR)
reset role;
insert into companies(id,code,name) values ('c0000000-0000-0000-0000-0000000000f9','OTHR','شركة ثانية') on conflict do nothing;
insert into item_categories(id,company_id,code,name) values ('1c000000-0000-0000-0000-0000000000f9','c0000000-0000-0000-0000-0000000000f9','01','غريبة') on conflict do nothing;
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
insert into items(company_id,code,name,category_id) values (:'C','X1','غلط','1c000000-0000-0000-0000-0000000000f9');
\echo == used category cannot be deleted (expected ERROR)
delete from item_categories where id='1c000000-0000-0000-0000-000000000001';
\echo == backup includes categories
select (backup_company(:'C') -> 'tables' -> 'item_categories') is not null as in_backup;
reset role;
