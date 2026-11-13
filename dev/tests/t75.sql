\set ON_ERROR_STOP 0
-- قوالب العقود (المرحلة 75)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
insert into contract_templates (company_id, code, name, body) values (:'C', 'T1', 'عقد مسك دفاتر', 'بين [الشركة] و [العميل]') returning code;
select id as tpl from contract_templates where company_id = :'C' and code = 'T1' \gset
update contracts set template_id = :'tpl', terms = 'نص خاص' where company_id = :'C' returning template_id is not null as linked;
reset role;
insert into companies (id, code, name) values ('c7500000-0000-0000-0000-000000000001', '75', 'شركة 75') on conflict do nothing;
insert into contract_templates (id, company_id, code, name) values ('c7500000-0000-0000-0000-0000000000f1', 'c7500000-0000-0000-0000-000000000001', 'X', 'غريب') on conflict do nothing;
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\echo == template from another company (expected ERROR)
update contracts set template_id = 'c7500000-0000-0000-0000-0000000000f1' where company_id = :'C';
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
reset role;
update user_groups set permissions = (permissions - 'contracts') || '{"contracts":{"view":true}}' where id = (select group_id from user_companies where user_id = '22222222-2222-2222-2222-222222222222' and company_id = :'C');
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select count(*) > 0 as can_read from contract_templates where company_id = :'C';
\echo == view-only edits template (expected ERROR)
insert into contract_templates (company_id, code, name) values (:'C', 'T2', 'ممنوع');
reset role;
