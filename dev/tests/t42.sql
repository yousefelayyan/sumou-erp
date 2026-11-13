-- الفروع: موظف الفرع، تقارير الفرع، كاشير الفرع، ماذا لو
reset role;
insert into departments (id, company_id, code, name, kind) values ('d4200000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000001','M42','الرئيسية 42','main') on conflict do nothing;
insert into departments (id, company_id, code, name, kind, parent_id) values
 ('d4200000-0000-0000-0000-000000000002','c0000000-0000-0000-0000-000000000001','B42A','فرع أ','sub','d4200000-0000-0000-0000-000000000001'),
 ('d4200000-0000-0000-0000-000000000003','c0000000-0000-0000-0000-000000000001','B42B','فرع ب','sub','d4200000-0000-0000-0000-000000000001') on conflict do nothing;
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select id as fy from fiscal_years where id = 'f0000000-0000-0000-0000-000000000001' \gset
select id as a1 from accounts where company_id='c0000000-0000-0000-0000-000000000001' and not is_group order by code limit 1 \gset
select id as a2 from accounts where company_id='c0000000-0000-0000-0000-000000000001' and not is_group order by code offset 1 limit 1 \gset
insert into journal_entries (id, company_id, fiscal_year_id, entry_type, entry_date, description, department_id) values
 ('e4200000-0000-0000-0000-00000000000a','c0000000-0000-0000-0000-000000000001',:'fy','journal','2026-02-01','فرع أ','d4200000-0000-0000-0000-000000000002'),
 ('e4200000-0000-0000-0000-00000000000b','c0000000-0000-0000-0000-000000000001',:'fy','journal','2026-02-01','فرع ب','d4200000-0000-0000-0000-000000000003');
insert into journal_lines (entry_id, line_no, account_id, debit, credit) values
 ('e4200000-0000-0000-0000-00000000000a',1,:'a1',100,0),('e4200000-0000-0000-0000-00000000000a',2,:'a2',0,100),
 ('e4200000-0000-0000-0000-00000000000b',1,:'a1',7,0),('e4200000-0000-0000-0000-00000000000b',2,:'a2',0,7);
select post_entry('e4200000-0000-0000-0000-00000000000a'), post_entry('e4200000-0000-0000-0000-00000000000b');
\echo == branch A TB (100), main (107), all except B
select sum(period_debit) filter (where account_id = :'a1') as a_only from rep_trial_balance('c0000000-0000-0000-0000-000000000001', :'fy', '2026-02-01','2026-02-01', array['d4200000-0000-0000-0000-000000000002']::uuid[]);
select sum(period_debit) filter (where account_id = :'a1') as main_all from rep_trial_balance('c0000000-0000-0000-0000-000000000001', :'fy', '2026-02-01','2026-02-01', array['d4200000-0000-0000-0000-000000000002','d4200000-0000-0000-0000-000000000003']::uuid[]);
select sum(period_debit) filter (where account_id = :'a1') - (select sum(period_debit) filter (where account_id = :'a1') from rep_trial_balance('c0000000-0000-0000-0000-000000000001', :'fy', '2026-02-01','2026-02-01')) as excl_b_diff
  from rep_trial_balance('c0000000-0000-0000-0000-000000000001', :'fy', '2026-02-01','2026-02-01', null, array['d4200000-0000-0000-0000-000000000003']::uuid[]);
reset role;
update user_companies set branch_only = true, department_id = 'd4200000-0000-0000-0000-000000000002' where user_id = '22222222-2222-2222-2222-222222222222' and company_id = 'c0000000-0000-0000-0000-000000000001';
update user_groups set permissions = permissions || '{"journal_entries":{"view":true,"add":true}}' where id = (select group_id from user_companies where user_id = '22222222-2222-2222-2222-222222222222' and company_id = 'c0000000-0000-0000-0000-000000000001');
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
\echo == branch user sees only branch A entries
select count(*) filter (where department_id = 'd4200000-0000-0000-0000-000000000003') as seen_b, count(*) filter (where department_id = 'd4200000-0000-0000-0000-000000000002') as seen_a from journal_entries;
\echo == branch user company reports (expected ERROR)
select * from rep_journal('c0000000-0000-0000-0000-000000000001', :'fy', '2026-01-01','2026-12-31') limit 1;
\echo == branch user sees no lines of branch B
select count(*) as b_lines from journal_lines where entry_id = 'e4200000-0000-0000-0000-00000000000b';
\echo == branch user unposts branch B entry (expected ERROR)
select unpost_entry('e4200000-0000-0000-0000-00000000000b');
\echo == branch user writes in other branch (expected ERROR)
insert into journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, department_id) values ('c0000000-0000-0000-0000-000000000001',:'fy','journal','2026-02-02','x','d4200000-0000-0000-0000-000000000003');
reset role;
update user_groups set permissions = permissions || '{"branch_reports":{"view":true}}' where id = (select group_id from user_companies where user_id = '22222222-2222-2222-2222-222222222222' and company_id = 'c0000000-0000-0000-0000-000000000001');
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
\echo == branch user TB forced to branch A even when asking for B
select coalesce(sum(period_debit) filter (where account_id = :'a1'), 0) as forced from rep_trial_balance('c0000000-0000-0000-0000-000000000001', :'fy', '2026-02-01','2026-02-01', array['d4200000-0000-0000-0000-000000000003']::uuid[]);
reset role;
update user_companies set branch_only = false where user_id = '22222222-2222-2222-2222-222222222222';
\echo == pos settings other company warehouse (expected ERROR)
update departments set pos = jsonb_build_object('warehouse_id', gen_random_uuid()) where id = 'd4200000-0000-0000-0000-000000000002';
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\echo == whatif
select count(*) > 0 as rows, round(sum(net),3) as net, round(sum(cost),3) as cost from whatif_sales('c0000000-0000-0000-0000-000000000001','2026-01-01','2026-12-31');
reset role;
