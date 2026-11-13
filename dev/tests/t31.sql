\set ON_ERROR_STOP 0
-- المرحلة 31: لون الواجهة
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
update profiles set theme = 'jcpa' where id = auth.uid() returning theme;
\echo == bad theme (expected ERROR)
update profiles set theme = '<x>' where id = auth.uid();
reset role;
select count(*) filter (where permissions ? 'theme') = count(*) as all_groups_have_theme from user_groups where name in ('محاسب','مدخل بيانات','مشاهد');
