\set ON_ERROR_STOP 0
-- مراقبة تصوير الشاشة (المرحلة 96)
\set C 'c0000000-0000-0000-0000-000000000001'
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\echo == bad limits (expected ERROR)
select set_screen_guard('{"warn":5,"block":3}');
select set_screen_guard('{"warn":2,"block":3}');
select (screen_guard() ->> 'block')::int = 3 as cfg_saved;
-- الموظف: 3 محاولات (فرق 3 ثواني بينهم محاكاة بتعديل الوقت)
reset role;
delete from screen_events; delete from activity_log where entity = 'screen';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select (screen_event(:'C', 'printscreen', 'invoices') ->> 'count')::int = 1 as first;
select (screen_event(:'C', 'printscreen', 'invoices') ->> 'count')::int = 1 as dedup_3s;
reset role; update screen_events set created_at = created_at - interval '10 seconds'; set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select (screen_event(:'C', 'snip', 'invoices') ->> 'warn')::boolean as warned;
reset role; update screen_events set created_at = created_at - interval '10 seconds'; set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select (screen_event(:'C', 'print', 'invoices') ->> 'blocked')::boolean as blocked;
\echo == employee cannot insert directly (expected ERROR)
insert into screen_events (kind) values ('other');
reset role;
select is_active = false as employee_blocked from profiles where id = '22222222-2222-2222-2222-222222222222';
select count(*) >= 3 as logged from activity_log where entity = 'screen';
-- المدير ما بيتوقّف
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select count(*) >= 1 as admin_sees from screen_alerts(1);
reset role; update screen_events set created_at = created_at - interval '10 seconds'; set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select screen_event(:'C', 'printscreen', 'x') ->> 'blocked' as admin_s1;
reset role; update screen_events set created_at = created_at - interval '10 seconds'; set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select screen_event(:'C', 'printscreen', 'x') ->> 'blocked' as admin_s2;
reset role; update screen_events set created_at = created_at - interval '10 seconds'; set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select screen_event(:'C', 'printscreen', 'x') ->> 'blocked' as admin_not_blocked;
reset role;
update profiles set is_active = true where id = '22222222-2222-2222-2222-222222222222';
-- بعد إعادة التفعيل العدّ بيبلّش من جديد، والنسخ ما بينحسب
update screen_events set created_at = created_at - interval '10 seconds';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select (screen_event(:'C', 'copy', 'x') ->> 'count')::int = 0 as copy_not_counted;
reset role; update screen_events set created_at = created_at - interval '10 seconds';
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select (screen_event(:'C', 'printscreen', 'x') ->> 'blocked')::boolean = false as not_reblocked;
reset role;
update tenants set settings = settings - 'screen_guard';
delete from screen_events;
