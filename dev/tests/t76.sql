\set ON_ERROR_STOP 0
-- عمولات المندوبين (المرحلة 76)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
insert into commission_plans (id, company_id, code, name, basis, tiers, no_target_rate, bonus_at_pct, bonus_amount)
values ('76000000-0000-0000-0000-0000000000f1', :'C', 'P1', 'خطة المبيعات', 'sales', '[{"min_pct":0,"rate":0},{"min_pct":80,"rate":2},{"min_pct":100,"rate":3}]', 1, 100, 50);
\echo == bad tier (expected ERROR)
insert into commission_plans (company_id, code, name, tiers) values (:'C', 'P2', 'غلط', '[{"min_pct":"x","rate":2}]');
insert into lookups (id, company_id, kind, code, name, rate, commission_plan_id, user_id) values ('76000000-0000-0000-0000-0000000000e1', :'C', 'sales_rep', 'R76', 'مندوب 76', 1, '76000000-0000-0000-0000-0000000000f1', '22222222-2222-2222-2222-222222222222') on conflict do nothing;
insert into rep_targets (company_id, rep_id, month, target) values (:'C', '76000000-0000-0000-0000-0000000000e1', '2026-08-01', 1000), (:'C', '76000000-0000-0000-0000-0000000000e1', '2026-09-01', 1000);
select id as cu from parties where company_id = :'C' and party_type = 'customer' and account_id is not null and not stop_credit and not stop_if_debit order by code limit 1 \gset
insert into invoices (id, company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id, sales_rep_id) values
 ('76000000-0000-0000-0000-0000000000a1', :'C', :'F', 'sale', '2026-08-10', 'credit', :'cu', '76000000-0000-0000-0000-0000000000e1'),
 ('76000000-0000-0000-0000-0000000000a2', :'C', :'F', 'sale', '2026-09-10', 'credit', :'cu', '76000000-0000-0000-0000-0000000000e1');
insert into invoice_lines (invoice_id, description, qty, unit_price, tax_rate) values ('76000000-0000-0000-0000-0000000000a1', 'خدمة', 1, 1100, 16), ('76000000-0000-0000-0000-0000000000a2', 'خدمة', 1, 850, 16);
select post_invoice('76000000-0000-0000-0000-0000000000a1') is not null and post_invoice('76000000-0000-0000-0000-0000000000a2') is not null as posted;
-- آب: 1100 = 110% → 3% = 33 + مكافأة 50 = 83؛ أيلول: 850 = 85% → 2% = 17
select month, target, net_sales, achieved_pct, rate, commission, bonus, total from rep_commissions(:'C', '2026-08-01', '2026-09-30') where rep_id = '76000000-0000-0000-0000-0000000000e1' order by month;
-- المندوب المربوط بالمستخدم بيشوف حاله بس
reset role;
update user_groups set permissions = permissions - 'rep_commissions' where id = (select group_id from user_companies where user_id = '22222222-2222-2222-2222-222222222222' and company_id = :'C');
update user_companies set branch_only = false where user_id = '22222222-2222-2222-2222-222222222222';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select count(distinct rep_id) as own_reps, sum(total) as own_total from rep_commissions(:'C', '2026-08-01', '2026-09-30');
\echo == employee edits targets (expected ERROR)
update rep_targets set target = 1 where rep_id = '76000000-0000-0000-0000-0000000000e1' returning id;
insert into rep_targets (company_id, rep_id, month, target) values (:'C', '76000000-0000-0000-0000-0000000000e1', '2026-10-01', 5);
reset role;
