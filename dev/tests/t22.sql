\set ON_ERROR_STOP 0
-- فحص فترات السنة المالية (المرحلة 22)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
\echo == 12 periods for the test year
select count(*), min(code), max(code) from fiscal_periods where fiscal_year_id=:'F';
\echo == lock March for GL
update fiscal_periods set gl_locked=true where fiscal_year_id=:'F' and code like '03.%' returning code, gl_locked;
\echo == posting in a locked period (expected ERROR)
do $$ declare e uuid; a uuid; b uuid; begin
  select id into a from public.accounts where company_id='c0000000-0000-0000-0000-000000000001' and account_type='cash' and not is_group limit 1;
  select id into b from public.accounts where company_id='c0000000-0000-0000-0000-000000000001' and category='expenses' and not is_group limit 1;
  insert into public.journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description) values ('c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','journal','2026-03-10','قفل') returning id into e;
  insert into public.journal_lines(entry_id,line_no,account_id,debit,credit) values (e,1,b,10,0),(e,2,a,0,10);
  perform public.post_entry(e);
end $$;
\echo == posting in an open period works
do $$ declare e uuid; a uuid; b uuid; begin
  select id into a from public.accounts where company_id='c0000000-0000-0000-0000-000000000001' and account_type='cash' and not is_group limit 1;
  select id into b from public.accounts where company_id='c0000000-0000-0000-0000-000000000001' and category='expenses' and not is_group limit 1;
  insert into public.journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description) values ('c0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','journal','2026-04-10','مفتوح') returning id into e;
  insert into public.journal_lines(entry_id,line_no,account_id,debit,credit) values (e,1,b,10,0),(e,2,a,0,10);
  perform public.post_entry(e);
end $$;
select status from journal_entries where description='مفتوح';
\echo == lock April then unpost the April entry (expected ERROR)
update fiscal_periods set gl_locked=true where fiscal_year_id=:'F' and code like '04.%';
select unpost_entry((select id from journal_entries where description='مفتوح'));
\echo == dates and code cannot change
update fiscal_periods set start_date='2020-01-01', code='zz' where fiscal_year_id=:'F' and code like '05.%' returning code, start_date;
\echo == employee cannot unlock (expected ERROR or 0 rows)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
update fiscal_periods set gl_locked=false where fiscal_year_id=:'F' and code like '03.%';
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\echo == user cannot insert periods (expected ERROR)
insert into fiscal_periods(company_id,fiscal_year_id,code,start_date,end_date) values (:'C',:'F','13.26','2026-12-01','2026-12-31');
\echo == stock lock blocks stock moves (expected ERROR)
update fiscal_periods set stock_locked=true where fiscal_year_id=:'F' and code like '06.%';
reset role;
insert into stock_moves(company_id,item_id,warehouse_id,move_date,qty,source_type,source_id)
 select :'C', (select id from items where company_id=:'C' limit 1), (select id from warehouses where company_id=:'C' limit 1), '2026-06-15', 1, 'stock_doc', gen_random_uuid();
\echo == admin unlocks
set role authenticated;
update fiscal_periods set gl_locked=false, stock_locked=false where fiscal_year_id=:'F' returning code;
reset role;
