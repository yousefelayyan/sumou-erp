-- إيداع الشيكات وبيان القيود
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select id as cust from parties where company_id = 'c0000000-0000-0000-0000-000000000001' and party_type = 'customer' order by code limit 1 \gset
update company_settings set cheque_templates = '{"deposit":"إيداع شيك وارد رقم: [رقم الشيك] / [البنك] حق [الاستحقاق]"}' where company_id = 'c0000000-0000-0000-0000-000000000001';
select register_cheque(jsonb_build_object('company_id','c0000000-0000-0000-0000-000000000001','direction','in','party_id', :'cust','cheque_no','D44','amount',50,'due_date','2026-03-01','issue_date','2026-02-01','bank_name','العربي')) as ch \gset
select id as dep from accounts where company_id = 'c0000000-0000-0000-0000-000000000001' and not is_group and category = 'assets' and code <> '1104' order by code desc limit 1 \gset
select id as bank from accounts where company_id = 'c0000000-0000-0000-0000-000000000001' and not is_group and account_type in ('bank','cash') order by code limit 1 \gset
\echo == deposit into cheques box itself (expected ERROR)
select cheque_action(:'ch', 'deposit', '2026-02-02', (select id from accounts where company_id = 'c0000000-0000-0000-0000-000000000001' and code = '1104'));
select cheque_action(:'ch', 'deposit', '2026-02-02', :'dep');
select status, deposit_account_id = :'dep' as dep_ok from cheques where id = :'ch';
select description from journal_entries e join cheque_events v on v.entry_id = e.id where v.cheque_id = :'ch' order by v.created_at desc limit 1;
\echo == direct deposit account change (expected ERROR)
update cheques set deposit_account_id = null where id = :'ch';
select cheque_action(:'ch', 'collect', '2026-03-01', :'bank');
select status from cheques where id = :'ch';
\echo == deposit balance cleared
select coalesce(sum(l.debit - l.credit), 0) as dep_balance from journal_lines l join journal_entries e on e.id = l.entry_id
 where e.company_id = 'c0000000-0000-0000-0000-000000000001' and l.account_id = :'dep' and e.reference = 'D44';
reset role;
