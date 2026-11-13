-- استيراد حركات أجهزة البصمة
\set ON_ERROR_STOP 0
\set C 'c0000000-0000-0000-0000-000000000001'
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select id as e1, code as c1 from employees where company_id = :'C' order by code limit 1 \gset
select id as e2, code as c2 from employees where company_id = :'C' order by code offset 1 limit 1 \gset
update employees set device_code = ' 101 ' where id = :'e1';
select device_code from employees where id = :'e1';
\echo == duplicate device code (expected ERROR)
update employees set device_code = '101' where id = :'e2';
-- e1 برقم البصمة، e2 برمزه، 999 مش معروف، تاريخ مستقبلي وسطر خربان
select attendance_import(:'C', jsonb_build_array(
  jsonb_build_object('code','101','ts','2026-09-01 08:05:00'), jsonb_build_object('code','101','ts','2026-09-01 12:00:00'), jsonb_build_object('code','101','ts','2026-09-01 16:10:00'),
  jsonb_build_object('code','101','ts','2026-09-02 07:58:00'),
  jsonb_build_object('code',:'c2','ts','2026-09-01 09:00'), jsonb_build_object('code',:'c2','ts','2026-09-01 17:00'),
  jsonb_build_object('code','999','ts','2026-09-01 08:00:00'), jsonb_build_object('code','101','ts','2099-01-01 08:00:00'),
  jsonb_build_object('code','101','ts','زبالة')));
select day, to_char(check_in at time zone 'Asia/Amman','HH24:MI') i, to_char(check_out at time zone 'Asia/Amman','HH24:MI') o, source from attendance where employee_id in (:'e1',:'e2') and day between '2026-09-01' and '2026-09-02' order by employee_id = :'e2', day;
-- دمج: بصمة انصراف لليوم الثاني + تعديل مشرف ما بيتغيّر
select attendance_set(jsonb_build_object('company_id',:'C','employee_id',:'e2','day','2026-09-01','check_in','08:30','check_out','17:00')) \g /dev/null
select attendance_import(:'C', jsonb_build_array(jsonb_build_object('code','101','ts','2026-09-02 16:30:00'), jsonb_build_object('code',:'c2','ts','2026-09-01 07:00')));
select day, to_char(check_in at time zone 'Asia/Amman','HH24:MI') i, to_char(check_out at time zone 'Asia/Amman','HH24:MI') o, source from attendance where employee_id in (:'e1',:'e2') and day between '2026-09-01' and '2026-09-02' order by employee_id = :'e2', day;
select attendance_import(:'C', jsonb_build_array(jsonb_build_object('code',:'c2','ts','2026-09-01 07:00'), jsonb_build_object('code',:'c2','ts','2026-09-01 15:00')), true) ->> 'updated' as overwrite_upd;
\echo == user without rights (expected ERROR)
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false) \g /dev/null
select attendance_import(:'C', '[]'::jsonb);
reset role;
delete from attendance where day between '2026-09-01' and '2026-09-02' and company_id = :'C';
update employees set device_code = null where company_id = :'C';
