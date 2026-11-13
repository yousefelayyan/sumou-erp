\set ON_ERROR_STOP 0
-- الموازنات التقديرية (المرحلة 65)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
\set B 'b0650000-0000-0000-0000-000000000001'
insert into budgets (id, company_id, fiscal_year_id, code, name, status) values (:'B', :'C', :'F', '01', 'الموازنة العامة', 'approved') on conflict do nothing;
select status as forced_draft from budgets where id = :'B';
select id as exp from accounts where company_id = :'C' and category = 'expenses' and not is_group order by code limit 1 \gset
select id as rev from accounts where company_id = :'C' and category = 'revenue' and not is_group order by code limit 1 \gset
insert into budget_lines (budget_id, account_id, amounts) values (:'B', :'exp', array[100,100,100,100,100,100,100,100,100,100,100,100.0004]), (:'B', :'rev', array_fill(500::numeric, array[12]));
select (select sum(x) from unnest(amounts) x) as exp_total from budget_lines where budget_id = :'B' and account_id = :'exp';
\echo == group account (expected ERROR)
insert into budget_lines (budget_id, account_id) values (:'B', (select id from accounts where company_id = :'C' and is_group limit 1));
\echo == wrong length (expected ERROR)
insert into budget_lines (budget_id, account_id, amounts) values (:'B', (select id from accounts where company_id = :'C' and not is_group and category = 'assets' limit 1), array[1,2,3]);
select count(*) > 0 as has_rows, bool_or(account_id = :'exp' and budget = 100) as exp_budget from budget_vs_actual(:'B');
select count(distinct account_id) >= 2 as accounts from budget_vs_actual(:'B');
-- الاعتماد بيقفل
select budget_set_status(:'B', 'approved');
select status from budgets where id = :'B';
\echo == edit approved line (expected ERROR)
update budget_lines set amounts = array_fill(1::numeric, array[12]) where budget_id = :'B' and account_id = :'exp';
\echo == user cannot set status directly
update budgets set status = 'draft', name = 'x' where id = :'B';
\echo == delete approved (no rows)
delete from budgets where id = :'B' returning id;
select budget_set_status(:'B', 'draft');
select budget_save_lines(:'B', jsonb_build_array(jsonb_build_object('account_id', :'exp', 'amounts', jsonb_build_array(1,2,3,4,5,6,7,8,9,10,11,12)))) as saved_lines;
select (select sum(x) from unnest(amounts) x) as saved_total from budget_lines where budget_id = :'B';
\echo == fill from the previous fiscal year
select budget_fill(:'B', 10, false);
reset role;
\echo == employee without budgets view (expected ERROR)
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select count(*) from budget_vs_actual('b0650000-0000-0000-0000-000000000001');
\echo == internal actual rows not callable (expected ERROR)
select * from budget_actual_rows('c0000000-0000-0000-0000-000000000001', '2026-01-01', '2026-12-31', null, null);
reset role;
