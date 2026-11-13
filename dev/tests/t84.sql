\set ON_ERROR_STOP 0
-- سياسة كلمات السر (المرحلة 84)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select set_password_policy('{"min_len":8,"require_digit":true,"require_letter":true,"expiry_days":90,"force_change":true}') ->> 'min_len' as min_len;
\echo == short password for new user (expected ERROR)
select admin_create_user('pw84', 'تجربة', 'abc12');
\echo == no digit (expected ERROR)
select admin_create_user('pw84', 'تجربة', 'abcdefgh');
select admin_create_user('pw84', 'تجربة', 'abcdefg8') is not null as created;
select must_change_password from profiles where username = 'pw84';
\echo == user cannot clear the flag himself
select set_config('request.jwt.claim.sub', (select id::text from profiles where username = 'pw84'), false) \g /dev/null
update profiles set must_change_password = false, password_changed_at = now() + interval '1 year' where id = auth.uid();
select must_change_password, password_changed_at < now() + interval '1 day' as stamp_kept from profiles where id = auth.uid();
select my_password_status() ->> 'must_change' as must_change;
\echo == wrong old password (expected ERROR)
select change_my_password('xxxxxxxx', 'newpass99');
\echo == weak new password (expected ERROR)
select change_my_password('abcdefg8', 'short');
select change_my_password('abcdefg8', 'newpass99');
select (my_password_status() ->> 'must_change')::boolean as must_change, (my_password_status() ->> 'expired')::boolean as expired;
\echo == employee cannot set the policy (expected ERROR)
select set_password_policy('{"min_len":4}');
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select set_password_policy('{}') ->> 'min_len' as reset_min;
select admin_delete_user((select id from profiles where username = 'pw84')) \g /dev/null
reset role;
