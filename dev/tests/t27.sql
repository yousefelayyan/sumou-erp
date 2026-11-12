\set ON_ERROR_STOP 0
-- فحص حساب الإنتاج تحت التشغيل (المرحلة 27) — بعد t26
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
select (select code from accounts where id=ensure_wip_account(:'C')) as wip_code, (select name from accounts a join company_settings s on s.wip_account_id=a.id where s.company_id=:'C') as wip_name;
\echo == second call returns the same account
select ensure_wip_account(:'C') = (select wip_account_id from company_settings where company_id=:'C') as same;
\echo == new production docs take the WIP account
select create_production('1b000000-0000-0000-0000-000000000001',1,'2026-05-11',(select id from warehouses where company_id=:'C' limit 1)) is not null as created;
select doc_type, account_id = (select wip_account_id from company_settings where company_id=:'C') as wip from stock_docs where production_id = (select id from productions order by prod_no desc limit 1) order by doc_type;
\echo == perpetual: post both, WIP nets to minus extra cost only
update company_settings set perpetual_inventory=true where company_id=:'C';
select post_production((select id from productions order by prod_no desc limit 1)) as cost;
select post_stock_doc_gl(id) from stock_docs where production_id = (select id from productions order by prod_no desc limit 1) order by doc_type desc;
select sum(l.debit) - sum(l.credit) as wip_balance from journal_lines l join journal_entries e on e.id=l.entry_id
 where l.account_id=(select wip_account_id from company_settings where company_id=:'C') and e.status='posted';
\echo == employee cannot create it (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select ensure_wip_account(:'C');
reset role;
