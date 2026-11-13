-- التجربة المجانية
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
\echo == no template yet (expected ERROR)
set role anon; select trial_signup('{"name":"سامي","company":"محل سامي","phone":"0791234567","username":"sami","password":"123456"}');
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
\echo == real company as template (expected ERROR)
select super_set_demo_template('c0000000-0000-0000-0000-000000000001');
reset role; update companies set name = name || ' (عرض)' where id = 'c0000000-0000-0000-0000-000000000001';
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select super_set_demo_template('c0000000-0000-0000-0000-000000000001');
reset role; update companies set name = replace(name, ' (عرض)', '') where id = 'c0000000-0000-0000-0000-000000000001';
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
\echo == employee cannot set template (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select super_set_demo_template('c0000000-0000-0000-0000-000000000001');
set role anon;
select trial_signup('{"name":"سامي","company":"محل سامي","phone":"0791234567","username":"sami","password":"123456"}') ->> 'code' as code \gset
\echo == same phone again (expected ERROR)
select trial_signup('{"name":"سامي","company":"محل سامي","phone":"0791234567","username":"sami2","password":"123456"}');
\echo == bad phone (expected ERROR)
select trial_signup('{"name":"x","company":"y","phone":"12","username":"abc","password":"123456"}');
reset role;
select id as tuid from profiles where username='sami' \gset
set role authenticated; select set_config('request.jwt.claim.sub', :'tuid', false);
select trial_setup() as tcid \gset
select trial_setup() = :'tcid'::uuid as idempotent;
select (select count(*) from invoices where company_id = :'tcid') as invs, (select count(*) from journal_entries where company_id = :'tcid') as jes,
       (select count(*) from companies) as visible_companies, trial_status() ->> 'docs_used' as used;
\echo == trial cannot see template company
select count(*) as other_co from invoices where company_id = 'c0000000-0000-0000-0000-000000000001';
\echo == second company (expected ERROR)
insert into companies(name) values ('ثانية');
reset role;
update tenants set max_docs = 1 where code = :'code';
set role authenticated; select set_config('request.jwt.claim.sub', :'tuid', false);
select id as fy from fiscal_years where company_id = :'tcid' order by start_date desc limit 1 \gset
insert into journal_entries(company_id, fiscal_year_id, entry_type, entry_date, description) values (:'tcid', :'fy', 'journal', (select start_date from fiscal_years where id = :'fy'), 'أول');
\echo == over doc limit (expected ERROR)
insert into journal_entries(company_id, fiscal_year_id, entry_type, entry_date, description) values (:'tcid', :'fy', 'journal', (select start_date from fiscal_years where id = :'fy'), 'ثاني');
\echo == reverse chain over limit (expected ERROR)
select reverse_entry((select id from journal_entries where company_id = :'tcid' and status = 'posted' and entry_type = 'journal' and reversed_by is null limit 1), (select start_date from fiscal_years where id = :'fy'));
\echo == restore in trial (expected ERROR)
select restore_company(jsonb_build_object('app','sumou-erp','company_id', gen_random_uuid(), 'tables', jsonb_build_object('companies', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'code','99','name','x')))));
\echo == trial user cannot delete trials (expected ERROR)
select super_delete_trial((select id from tenants where code = :'code'));
reset role;
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select super_delete_trial((select id from tenants where code = :'code'));
reset role;
select (select count(*) from tenants where code = :'code') as t_left, (select count(*) from companies where id = :'tcid') as co_left, (select count(*) from auth.users where id = :'tuid') as u_left,
       (select count(*) from invoices where company_id = 'c0000000-0000-0000-0000-000000000001') > 0 as template_ok;
