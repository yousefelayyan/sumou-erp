\set ON_ERROR_STOP 0
-- تحميل أرصدة على سند قيد (المرحلة 82)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
\echo == customers balances = sum of party lines
select count(*) > 0 as has_rows, sum(balance) = (select sum(jl.debit - jl.credit) from journal_lines jl join journal_entries e on e.id = jl.entry_id join parties p on p.id = jl.party_id
  where e.company_id = :'C' and e.fiscal_year_id = :'F' and e.status in ('posted','reversed') and e.entry_type <> 'closing' and p.party_type = 'customer') as matches
  from entry_load_balances(:'C', :'F', '{"kind":"parties","type":"customer"}');
\echo == accounts under a parent (cash group) = trial balance of its leaves
select count(*) >= 1 as rows, bool_and(party_id is null) as no_party from entry_load_balances(:'C', :'F',
  jsonb_build_object('kind','accounts','category','assets'));
\echo == bad kind (expected ERROR)
select * from entry_load_balances(:'C', :'F', '{"kind":"x"}');
\echo == no rights (expected ERROR)
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false) \g /dev/null
select * from entry_load_balances(:'C', :'F', '{"kind":"parties","type":"customer"}');
reset role;
