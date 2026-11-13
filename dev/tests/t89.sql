\set ON_ERROR_STOP 0
-- أداة الأرصدة الافتتاحية (المرحلة 89)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
\echo == customers = sum of customer lines of the year
select count(*) > 0 as has_rows, sum(amount) = (select sum(jl.debit - jl.credit) from journal_lines jl join journal_entries e on e.id = jl.entry_id join parties p on p.id = jl.party_id
  where e.company_id = :'C' and e.fiscal_year_id = :'F' and e.status in ('posted','reversed') and p.party_type = 'customer') as matches
  from opening_source(:'C', :'F', 'parties', 'customer');
\echo == accounts + year result balance to zero (balanced books)
select count(*) > 0 as has_rows, abs(round(sum(amount), 3)) < 0.001 as balanced from (
  select amount from opening_source(:'C', :'F', 'accounts')
  union all select amount from opening_source(:'C', :'F', 'parties', 'customer')
  union all select amount from opening_source(:'C', :'F', 'parties', 'supplier')
  union all select amount from opening_source(:'C', :'F', 'parties', 'expense')
  union all select amount from opening_source(:'C', :'F', 'employees')) x;
\echo == assets kind runs
select count(*) >= 0 as ok from opening_source(:'C', :'F', 'assets');
\echo == bad kind (expected ERROR)
select * from opening_source(:'C', :'F', 'x');
\echo == bad party type (expected ERROR)
select * from opening_source(:'C', :'F', 'parties', 'x');
\echo == asset line with party (expected ERROR)
reset role;
do $$ declare a uuid; e uuid; p uuid; acc uuid; begin
  select id into acc from accounts where company_id = 'c0000000-0000-0000-0000-000000000001' and not is_group limit 1;
  insert into fixed_assets (company_id, code, name, purchase_date, dep_start, cost, life_months, asset_account_id)
    values ('c0000000-0000-0000-0000-000000000001', 'T89', 'أصل فحص', '2020-01-01', '2020-01-01', 1000, 60, acc) returning id into a;
  insert into journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description)
    values ('c0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001', 'journal', (select start_date from fiscal_years where id = 'f0000000-0000-0000-0000-000000000001'), 't89') returning id into e;
  insert into journal_lines (entry_id, line_no, account_id, asset_id, debit, credit) values (e, 1, acc, a, 10, 0);
  raise notice 'asset line ok';
  select id into p from parties where company_id = 'c0000000-0000-0000-0000-000000000001' limit 1;
  insert into journal_lines (entry_id, line_no, account_id, asset_id, party_id, debit, credit) values (e, 2, acc, a, p, 0, 10);
end $$;
\echo == no rights (expected ERROR)
set role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false) \g /dev/null
select * from opening_source(:'C', :'F', 'parties', 'customer');
reset role;
