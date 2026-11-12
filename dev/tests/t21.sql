\set ON_ERROR_STOP 0
-- فحص الدوائر (المرحلة 21)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
insert into departments(id,company_id,code,name,kind) values
 ('d0000000-0000-0000-0000-000000000001',:'C','M','الإدارة العامة','main') returning code, level;
insert into departments(id,company_id,code,name,kind,parent_id) values
 ('d0000000-0000-0000-0000-000000000002',:'C','1','المالية','sub','d0000000-0000-0000-0000-000000000001'),
 ('d0000000-0000-0000-0000-000000000003',:'C','2','المبيعات','sub','d0000000-0000-0000-0000-000000000001') returning code, level;
\echo == parent must be main (expected ERROR)
insert into departments(company_id,code,name,kind,parent_id) values (:'C','3','غلط','sub','d0000000-0000-0000-0000-000000000002');
\echo == cycle (expected ERROR)
insert into departments(id,company_id,code,name,kind,parent_id) values ('d0000000-0000-0000-0000-000000000004',:'C','M2','فرع','main','d0000000-0000-0000-0000-000000000001');
update departments set parent_id='d0000000-0000-0000-0000-000000000004' where id='d0000000-0000-0000-0000-000000000001';
\echo == main with children cannot become sub (expected ERROR)
update departments set kind='sub' where id='d0000000-0000-0000-0000-000000000001';
\echo == duplicate code (expected ERROR)
insert into departments(company_id,code,name) values (:'C','1','مكرر');
\echo == user default department and document default
reset role;
insert into user_companies(user_id,company_id) values ('11111111-1111-1111-1111-111111111111',:'C') on conflict do nothing;
update user_companies set department_id='d0000000-0000-0000-0000-000000000002' where user_id='11111111-1111-1111-1111-111111111111' and company_id=:'C';
\echo == main as user department (expected ERROR)
update user_companies set department_id='d0000000-0000-0000-0000-000000000001' where user_id='11111111-1111-1111-1111-111111111111' and company_id=:'C';
set role authenticated;
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description) values (:'C','f0000000-0000-0000-0000-000000000001','journal','2026-02-02','قيد دائرة') returning (select code from departments where id=department_id) as dept;
\echo == main department on a document (expected ERROR)
insert into journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description,department_id) values (:'C','f0000000-0000-0000-0000-000000000001','journal','2026-02-02','x','d0000000-0000-0000-0000-000000000001');
\echo == used department cannot be deleted (expected ERROR)
delete from departments where id='d0000000-0000-0000-0000-000000000002';
\echo == employee cannot add departments (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
insert into departments(company_id,code,name) values (:'C','9','ممنوع');
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\echo == backup includes departments
select jsonb_array_length(backup_company(:'C') -> 'tables' -> 'departments') as depts;
reset role;
