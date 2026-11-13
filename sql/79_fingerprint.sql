-- =====================================================================
--  المرحلة 79: استيراد حركات أجهزة البصمة
--  employees.device_code = رقم الموظف على الجهاز (فريد بالشركة)
--  attendance.source صار فيه 'device'
--  attendance_import(company, rows, overwrite): rows = [{code, ts}] بالتوقيت المحلي (عمّان)
--    الدخول = أول بصمة باليوم، الانصراف = آخر بصمة (إذا بصمة وحدة بيضل فاضي)
--    بيندمج مع الموجود (الأبكر والأخير)، وسطر المشرف ما بيتغيّر إلا إذا overwrite
-- =====================================================================

alter table public.employees add column if not exists device_code text;
create unique index if not exists employees_device_code_uq on public.employees (company_id, device_code) where device_code is not null;

create or replace function public.ad_employee_device_code() returns trigger
language plpgsql as $$
begin
  new.device_code := nullif(trim(new.device_code), '');
  if new.device_code is not null and length(new.device_code) > 30 then raise exception 'رقم البصمة طويل'; end if;
  return new;
end $$;
drop trigger if exists ad_employee_device_code on public.employees;
create trigger ad_employee_device_code before insert or update of device_code on public.employees
  for each row execute function public.ad_employee_device_code();

alter table public.attendance drop constraint if exists attendance_source_check;
alter table public.attendance add constraint attendance_source_check check (source in ('self','supervisor','device'));

create or replace function public.attendance_import(p_company uuid, p_rows jsonb, p_overwrite boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  n int; r record; ins int := 0; upd int := 0; skip_sup int := 0; fut int := 0; bad int := 0; matched int := 0;
  unm text[]; ex public.attendance; ci timestamptz; co timestamptz; lo timestamptz; hi timestamptz;
begin
  if not public.can(p_company, 'payroll', 'edit') or not public.tenant_writable() then raise exception 'استيراد البصمة للمشرف (تعديل الرواتب)'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'البيانات مش صحيحة'; end if;
  n := jsonb_array_length(p_rows);
  if n > 50000 then raise exception 'الملف كبير: أقصى 50000 بصمة بالمرة'; end if;

  create temp table if not exists _fp (code text, ts timestamp) on commit drop;
  truncate _fp;
  insert into _fp (code, ts)
  select nullif(trim(x ->> 'code'), ''),
         case when (x ->> 'ts') ~ '^\d{4}-\d{2}-\d{2}[ T]\d{1,2}:\d{2}(:\d{2})?$' then (x ->> 'ts')::timestamp end
  from jsonb_array_elements(p_rows) x;
  select count(*) into bad from _fp where code is null or ts is null;
  delete from _fp where code is null or ts is null;
  select count(*) into fut from _fp where ts::date > public.local_today();
  delete from _fp where ts::date > public.local_today();

  -- المطابقة: رقم البصمة، وإذا الموظف ما إله رقم بصمة على رمزه
  create temp table if not exists _fpm (employee_id uuid, day date, lo timestamp, hi timestamp, cnt int) on commit drop;
  truncate _fpm;
  insert into _fpm
  select e.id, f.ts::date, min(f.ts), max(f.ts), count(*)::int
  from _fp f
  join public.employees e on e.company_id = p_company
   and (e.device_code = f.code or (e.device_code is null and e.code = f.code
        and not exists (select 1 from public.employees e2 where e2.company_id = p_company and e2.device_code = f.code)))
  group by e.id, f.ts::date;
  select coalesce(sum(cnt), 0) into matched from _fpm;
  select coalesce(array_agg(distinct f.code order by f.code), '{}') into unm from _fp f
   where not exists (select 1 from public.employees e where e.company_id = p_company and (e.device_code = f.code or (e.device_code is null and e.code = f.code)));

  for r in select * from _fpm order by employee_id, day loop
    lo := r.lo at time zone 'Asia/Amman'; hi := r.hi at time zone 'Asia/Amman';
    select * into ex from public.attendance where employee_id = r.employee_id and day = r.day;
    if not found then
      insert into public.attendance (company_id, employee_id, day, check_in, check_out, source, updated_by)
      values (p_company, r.employee_id, r.day, lo, case when hi > lo + interval '1 minute' then hi end, 'device', auth.uid());
      ins := ins + 1;
    elsif ex.source = 'supervisor' and not p_overwrite then
      skip_sup := skip_sup + 1;
    else
      if p_overwrite and ex.source = 'supervisor' then
        ci := lo; co := case when hi > lo + interval '1 minute' then hi end;
      else
        ci := least(lo, ex.check_in);
        co := greatest(hi, ex.check_out, ex.check_in);
        if co <= ci + interval '1 minute' then co := null; end if;
      end if;
      update public.attendance set check_in = ci, check_out = co, source = 'device', updated_by = auth.uid(), updated_at = now()
       where id = ex.id and (check_in is distinct from ci or check_out is distinct from co or source <> 'device');
      if found then upd := upd + 1; end if;
    end if;
  end loop;

  return jsonb_build_object('rows', n, 'matched', matched, 'days', (select count(*) from _fpm), 'inserted', ins, 'updated', upd,
    'skipped_supervisor', skip_sup, 'future', fut, 'invalid', bad, 'unmatched', to_jsonb(unm));
end $$;

revoke execute on function public.attendance_import(uuid, jsonb, boolean) from public, anon;
grant execute on function public.attendance_import(uuid, jsonb, boolean) to authenticated;
