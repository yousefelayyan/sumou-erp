\set ON_ERROR_STOP 0
-- العقود والرسوم المتكررة (المرحلة 70)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set K '70000000-0000-0000-0000-000000000701'
select id as cu from parties where company_id = :'C' and party_type = 'customer' and account_id is not null order by code limit 1 \gset
select id as su from parties where company_id = :'C' and party_type = 'supplier' order by code limit 1 \gset
select start_date as fs from fiscal_years where id = 'f0000000-0000-0000-0000-000000000001' \gset
-- عقد كل 3 شهور يوم 5، ترحيل تلقائي
insert into contracts (id, company_id, party_id, title, every_months, day_of_month, start_date, end_date, auto_post)
values (:'K', :'C', :'cu', 'أتعاب تدقيق ربعية', 3, 5, :'fs', (:'fs'::date + 300), true);
select contract_no >= 1 as numbered, next_date = (:'fs'::date + 4) as next_ok from contracts where id = :'K';
insert into contract_lines (contract_id, line_no, description, qty, unit_price, tax_rate) values (:'K', 1, 'أتعاب', 1, 300, 16), (:'K', 2, 'رسوم', 2, 25, 0);
select count(*) as due, sum(amount) as amt from contract_due(:'C', (:'fs'::date + 200));
select contract_generate(:'C', (:'fs'::date + 200)) ->> 'made' as made;
select count(*) as invs, sum(total) as tot, bool_and(status = 'posted') as posted, min(contract_period) as p1 from invoices where contract_id = :'K';
select next_date = (:'fs'::date + 4 + 0) + interval '9 months' as next9 from contracts where id = :'K';
-- مرة ثانية ما بيكرر
select contract_generate(:'C', (:'fs'::date + 200)) ->> 'made' as again;
\echo == reset next_date to start (expected ERROR)
update contracts set next_date = :'fs' where id = :'K';
update contracts set next_date = null where id = :'K';
select next_date > (:'fs'::date + 200) as kept from contracts where id = :'K';
-- لحد نهاية العقد بيصير منتهي
select contract_generate(:'C', (:'fs'::date + 400)) ->> 'made' as rest;
-- عقد بدون سطور بيرجع بالأخطاء والباقي بيكمل
\echo == day 31 (expected ERROR)
insert into contracts (company_id, party_id, title, start_date, day_of_month) values (:'C', :'cu', 'بدون سطور', :'fs', 31);
insert into contracts (company_id, party_id, title, start_date, day_of_month, next_date) values (:'C', :'cu', 'بدون سطور', :'fs', 10, (:'fs'::date + 14)) returning extract(day from next_date) as snapped_day;
select jsonb_array_length(contract_generate(:'C', (:'fs'::date + 60)) -> 'failed') as failed;
select status, (select count(*) from invoices where contract_id = :'K') as invs from contracts where id = :'K';
\echo == contract on a supplier (expected ERROR)
insert into contracts (company_id, party_id, title, start_date) values (:'C', :'su', 'x', :'fs');
\echo == manual contract_id on invoice (ignored)
insert into invoices (company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id, contract_id) values (:'C', 'f0000000-0000-0000-0000-000000000001', 'sale', :'fs', 'credit', :'cu', :'K') returning contract_id is null as ignored;
\echo == delete contract with invoices (0 rows)
delete from contracts where id = :'K';
select count(*) as still from contracts where id = :'K';
-- الموظف بدون صلاحية
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
\echo == employee generate (expected ERROR)
select contract_generate(:'C', current_date);
reset role;
