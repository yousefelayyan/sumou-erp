\set ON_ERROR_STOP 0
insert into auth.users(id,email) values ('11111111-1111-1111-1111-111111111111','admin@x.com'),('22222222-2222-2222-2222-222222222222','emp@x.com');
insert into companies(id,code,name) values ('c0000000-0000-0000-0000-000000000001','1','ش1'),('c0000000-0000-0000-0000-000000000002','2','ش2');
grant select on auth.users to authenticated;
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select admin_create_user('Hala','هالة','hala','{"sales_invoices":true,"customers":true}', array['c0000000-0000-0000-0000-000000000001']::uuid[]) as hid \gset
reset role;
select email, encrypted_password = extensions.crypt('hala', encrypted_password) pw_ok from auth.users where id=:'hid';
select username, full_name, is_active, permissions from profiles where id=:'hid';
set role authenticated; select set_config('request.jwt.claim.sub',:'hid',false) \g /dev/null
select can('c0000000-0000-0000-0000-000000000001','sales_invoices','delete') a, can('c0000000-0000-0000-0000-000000000001','purchase_invoices','view') b, can('c0000000-0000-0000-0000-000000000002','sales_invoices','view') c;
update profiles set permissions='{"accounts":true}', is_admin=true where id=:'hid';
select admin_create_user('x','x','xxxx');
reset role; select is_admin, permissions from profiles where id=:'hid';
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select admin_update_user(:'hid','hala2','هالة ع','newpass','{"accounts":true}', array['c0000000-0000-0000-0000-000000000002']::uuid[], false, true);
select admin_create_user('hala2','dup','1234');
select admin_create_user('bad name','x','1234');
reset role;
select u.email, u.encrypted_password = extensions.crypt('newpass', u.encrypted_password) pw_ok, p.username, p.full_name, p.permissions, (select array_agg(company_id) from user_companies where user_id=p.id) from auth.users u join profiles p using(id) where id=:'hid';
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select admin_delete_user(:'hid');
reset role; select count(*) from profiles where id=:'hid';
