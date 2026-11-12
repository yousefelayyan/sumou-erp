\set ON_ERROR_STOP 0
-- فحص فئات العملاء والموردين (المرحلة 17)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
insert into party_categories(id,company_id,party_type,code,name) values
 ('9c000000-0000-0000-0000-000000000001',:'C','customer','1','جملة'),
 ('9c000000-0000-0000-0000-000000000002',:'C','supplier','1','استيراد') returning party_type, code, name;
\echo == customer gets a customer category
insert into parties(company_id,party_type,code,name,account_id,category_id) values (:'C','customer','PC1','عميل فئة',(select id from accounts where company_id=:'C' and account_type='customer' and not exists (select 1 from accounts c where c.parent_id=accounts.id) limit 1),'9c000000-0000-0000-0000-000000000001') returning code;
\echo == supplier category on a customer rejected (expected ERROR)
update parties set category_id='9c000000-0000-0000-0000-000000000002' where code='PC1';
\echo == empty name rejected (expected ERROR)
insert into party_categories(company_id,party_type,code,name) values (:'C','customer','2',' ');
\echo == used category cannot be deleted (expected ERROR)
delete from party_categories where id='9c000000-0000-0000-0000-000000000001';
\echo == employee without customers rights cannot add (expected ERROR or 0 rows)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
insert into party_categories(company_id,party_type,code,name) values (:'C','customer','9','ممنوع');
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\echo == backup includes party categories
select jsonb_array_length(backup_company(:'C') -> 'tables' -> 'party_categories') >= 2 as in_backup;
reset role;
