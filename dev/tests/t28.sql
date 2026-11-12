\set ON_ERROR_STOP 0
-- المرحلة 28: المشتركين — العزل، الحدود، الأقسام، الانتهاء، الإيقاف
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select is_super() as yousef_is_super, (select code from tenants where id = my_tenant()) as yousef_tenant;
\echo == create tenant acme (2 users, sales only, 1 company)
select super_save_tenant(null, '{"code":"acme","name":"أكمي","max_users":2,"max_companies":1,"modules":["sales"],"expires_at":"2099-12-31"}') is not null as created;
\echo == reserved/duplicate code (expected ERROR)
select super_save_tenant(null, '{"code":"sumou","name":"x"}');
select super_save_tenant(null, '{"code":"acme","name":"x"}');
select super_create_tenant_admin((select id from tenants where code='acme'), 'boss', 'مدير أكمي', 'pass1') is not null as admin_created;
select email from profiles where username='boss';
select count(*) as acme_groups from user_groups;  -- Yousef sees only his groups
select (select count(*) from super_tenants()) as tenants_listed;
\set acme_admin `psql -h /tmp -p 5433 -U postgres -Atqc "select id from profiles where username='boss'"`
\set acme_t `psql -h /tmp -p 5433 -U postgres -Atqc "select id from tenants where code='acme'"`

-- ===== as acme admin
select set_config('request.jwt.claim.sub', :'acme_admin', false) \g /dev/null
select is_admin() as acme_is_admin, is_super() as acme_is_super;
select count(*) as sees_companies from companies;
select count(*) as sees_profiles from profiles;
select count(*) as sees_groups from user_groups;
select count(*) as sees_log from activity_log where tenant_id <> my_tenant();
select count(*) as sees_entries from journal_entries;
select count(*) as sees_tenants from tenants;
select has_company('c0000000-0000-0000-0000-000000000001') as has_sumou_company, can('c0000000-0000-0000-0000-000000000001','journal_entries','view') as can_sumou;
\echo == super functions (expected ERROR)
select * from super_tenants();
select super_add_payment(my_tenant(), 1, 12, 'x');
\echo == same company code as other tenant is fine
insert into companies(id,code,name) values ('c0000000-0000-0000-0000-00000000a001','Z','أكمي للتجارة');
select (tenant_id = my_tenant()) as company_in_acme from companies where id='c0000000-0000-0000-0000-00000000a001';
\echo == company limit (expected ERROR)
insert into companies(code,name) values ('Y','ثانية');
insert into fiscal_years(id,company_id,code,start_date,end_date) values ('f0000000-0000-0000-0000-00000000a001','c0000000-0000-0000-0000-00000000a001','2026','2026-01-01','2026-12-31');
\echo == modules
select can('c0000000-0000-0000-0000-00000000a001','sales_invoices','add') as sales, can('c0000000-0000-0000-0000-00000000a001','inventory','view') as inventory,
       can('c0000000-0000-0000-0000-00000000a001','payroll','view') as payroll, can('c0000000-0000-0000-0000-00000000a001','journal_entries','add') as core;
\echo == user on another tenant company (expected ERROR)
select admin_create_user('x1','x','pass1','{}','{c0000000-0000-0000-0000-000000000001}');
\echo == same username as in other tenant is fine, then user limit (expected ERROR on 2nd)
select admin_create_user('emp','موظف أكمي','pass1','{}','{c0000000-0000-0000-0000-00000000a001}') is not null as emp_created;
select admin_create_user('emp2','موظف 2','pass1');
select email from profiles where username='emp';
\echo == cannot touch other tenant users (expected ERROR)
select admin_update_user('22222222-2222-2222-2222-222222222222','hacked','x','pass1','{}','{}',true,true);
select admin_delete_user('22222222-2222-2222-2222-222222222222');
insert into user_companies(user_id,company_id) values ('22222222-2222-2222-2222-222222222222','c0000000-0000-0000-0000-00000000a001');
update profiles set is_admin = true where id = '22222222-2222-2222-2222-222222222222';
select is_admin from profiles where id = '22222222-2222-2222-2222-222222222222';
\echo == own tenant/super cannot be changed
update profiles set is_super = true, tenant_id = (select default_tenant_check from (select null::uuid default_tenant_check) x) where id = auth.uid();
select is_super, tenant_id = :'acme_t' as same_tenant from profiles where id = auth.uid();
\echo == backup/close of other tenant (expected ERROR)
select backup_company('c0000000-0000-0000-0000-000000000001');
select close_fiscal_year('f0000000-0000-0000-0000-000000000001', null, null);
select reopen_fiscal_year('f0000000-0000-0000-0000-000000000001');
select count(*) as names_other_tenant from user_names('{11111111-1111-1111-1111-111111111111}');
select (my_subscription() ->> 'users_used') as users_used, (my_subscription() ->> 'writable') as writable;
select count(*) as acme_payments from tenant_payments;

-- ===== expiry → read only
reset role;
update tenants set expires_at = current_date - 1 where code='acme';
set role authenticated;
select can('c0000000-0000-0000-0000-00000000a001','journal_entries','view') as view_ok, can('c0000000-0000-0000-0000-00000000a001','journal_entries','add') as add_blocked,
       can('c0000000-0000-0000-0000-00000000a001','journal_entries','print') as print_ok, has_company('c0000000-0000-0000-0000-00000000a001') as still_sees;
\echo == expired writes (expected ERROR)
select admin_create_user('emp3','x','pass1');
insert into companies(code,name) values ('W','w');
insert into user_groups(name) values ('مجموعة');

-- ===== payment extends from today
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select super_add_payment(:'acme_t', 120, 12, 'كليك') = (current_date - 1 + interval '12 months')::date as extended_from_today;
select super_add_payment(:'acme_t', 120, 1, 'تحويل') = (current_date - 1 + interval '13 months')::date as extended_again;
select super_delete_payment((select id from tenant_payments where months=1));
select expires_at = (current_date - 1 + interval '12 months')::date as rolled_back from tenants where code='acme';
select set_config('request.jwt.claim.sub', :'acme_admin', false) \g /dev/null
select can('c0000000-0000-0000-0000-00000000a001','journal_entries','add') as add_back;
select count(*) as acme_sees_payments from tenant_payments;

-- ===== suspend
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select super_save_tenant(:'acme_t', '{"name":"أكمي","status":"suspended","max_users":2,"max_companies":1,"modules":["sales"],"expires_at":"2099-12-31"}') is not null;
\echo == default tenant cannot be suspended (expected ERROR)
select super_save_tenant(my_tenant(), '{"name":"x","status":"suspended"}');
select set_config('request.jwt.claim.sub', :'acme_admin', false) \g /dev/null
select is_active_user() as active, is_admin() as admin, has_company('c0000000-0000-0000-0000-00000000a001') as sees, count(*) as companies from companies;

-- ===== reactivate; super resets a password, user limit on reactivation
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select super_save_tenant(:'acme_t', '{"name":"أكمي","status":"active","max_users":2,"max_companies":1,"modules":["sales"],"expires_at":"2099-12-31"}') is not null;
select count(*) as acme_users from super_tenant_users(:'acme_t');
\set acme_emp `psql -h /tmp -p 5433 -U postgres -Atqc "select p.id from profiles p join tenants t on t.id=p.tenant_id where p.username='emp' and t.code='acme'"`
select super_set_user(:'acme_emp', 'newpass', false);
select super_set_user(:'acme_emp', null, true);
select is_active from super_tenant_users(:'acme_t') where username='emp';
\echo == Yousef cannot see acme company data
select has_company('c0000000-0000-0000-0000-00000000a001') as yousef_sees_acme, count(*) as yousef_companies from companies;
\echo == self-signup lands in default tenant, inactive
reset role;
insert into auth.users(id,email) values ('33333333-3333-3333-3333-333333333333','rand@x.com');
select is_active, is_admin, is_super, tenant_id = (select id from tenants where is_default) as default_tenant from profiles where id='33333333-3333-3333-3333-333333333333';
delete from auth.users where id='33333333-3333-3333-3333-333333333333'; delete from profiles where id='33333333-3333-3333-3333-333333333333';

-- ===== review fixes
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select super_save_tenant(:'acme_t', '{"name":"أكمي","status":"active","max_users":2,"max_companies":3,"modules":["sales"],"expires_at":"2099-12-31"}') is not null;
select set_config('request.jwt.claim.sub', :'acme_admin', false) \g /dev/null
\echo == restore injecting rows into another tenant company (expected ERROR)
select restore_company(jsonb_build_object('app','sumou-erp','company_id','c0000000-0000-0000-0000-00000000b999','tables',jsonb_build_object(
 'companies',jsonb_build_array(jsonb_build_object('id','c0000000-0000-0000-0000-00000000b999','code','EV','name','evil')),
 'lookups',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'company_id','c0000000-0000-0000-0000-000000000001','kind','payment_method','code','HACK1','name','x')))));
\echo == restore with no foreign links is fine; linking to another tenant account (expected ERROR)
select restore_company(jsonb_build_object('app','sumou-erp','company_id','c0000000-0000-0000-0000-00000000b998','tables',jsonb_build_object(
 'companies',jsonb_build_array(jsonb_build_object('id','c0000000-0000-0000-0000-00000000b998','code','EV2','name','evil')),
 'lookups',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'company_id','c0000000-0000-0000-0000-00000000b998','kind','payment_method','code','P1','name','x',
    'account_id',(select null::uuid)))) ));
reset role;
\set sumou_acc `psql -h /tmp -p 5433 -U postgres -Atqc "select id from accounts where company_id='c0000000-0000-0000-0000-000000000001' and code='1101'"`
set role authenticated;
select restore_company(jsonb_build_object('app','sumou-erp','company_id','c0000000-0000-0000-0000-00000000b997','tables',jsonb_build_object(
 'companies',jsonb_build_array(jsonb_build_object('id','c0000000-0000-0000-0000-00000000b997','code','EV3','name','evil')),
 'lookups',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'company_id','c0000000-0000-0000-0000-00000000b997','kind','payment_method','code','P1','name','x','account_id',:'sumou_acc')))));
select count(*) as evil_companies from companies where code like 'EV%';
\echo == clean restore still works
select restore_company(jsonb_build_object('app','sumou-erp','company_id','c0000000-0000-0000-0000-00000000b996','tables',jsonb_build_object(
 'companies',jsonb_build_array(jsonb_build_object('id','c0000000-0000-0000-0000-00000000b996','code','OK','name','سليمة'))))) is not null as restored;
\echo == attachment pointing at other company file (expected ERROR)
insert into attachments(company_id,entity,entity_id,path,file_name) values ('c0000000-0000-0000-0000-00000000a001','journal',gen_random_uuid(),'c0000000-0000-0000-0000-000000000001/journal/x/secret.pdf','x');
\echo == reactivation over user limit (expected ERROR)
update profiles set is_active=false where id=:'acme_emp';
select admin_create_user('emp9','x','pass1') is not null as emp9;
update profiles set is_active=true where id=:'acme_emp';
select count(*) filter (where is_active) as active_users from profiles;
\echo == default-tenant admin cannot lock out the super
reset role;
insert into auth.users(id,email) values ('44444444-4444-4444-4444-444444444444','admin2@x.com');
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
update profiles set is_active=true, is_admin=true where id='44444444-4444-4444-4444-444444444444'; select set_config('request.jwt.claim.sub','44444444-4444-4444-4444-444444444444',false) \g /dev/null
update profiles set is_active=false, is_admin=false where id='11111111-1111-1111-1111-111111111111';
delete from profiles where id='11111111-1111-1111-1111-111111111111';
select admin_update_user('11111111-1111-1111-1111-111111111111',null,'x','','{}','{}',false,false);
select is_active, is_admin from profiles where id='11111111-1111-1111-1111-111111111111';
\echo == employee cannot read tenant row
select set_config('request.jwt.claim.sub', :'acme_emp', false) \g /dev/null
select count(*) as emp_sees_tenant from tenants;
\echo == self signup with internal email (expected ERROR)
reset role;
insert into auth.users(id,email) values ('55555555-5555-5555-5555-555555555555','boss2@acme.sumou.local');
