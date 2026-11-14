-- حذف الشركة التجريبية «عالم الشخصيات للاكسسوارات والهدايا» بكل بياناتها (بيتشغّل من محرر SQL)
-- نفس طريقة super_delete_trial: triggers المستخدم بتوقف جوّا العملية بس، وبأي خطأ بيرجع كل شي.
do $del$
declare cid uuid; r record;
begin
  select id into cid from public.companies
   where name = 'عالم الشخصيات للاكسسوارات والهدايا' and notes like 'شركة تجريبية للفحص%';
  if cid is null then raise notice 'الشركة التجريبية مش موجودة'; return; end if;
  for r in select distinct c.relname from pg_trigger g join pg_class c on c.oid = g.tgrelid join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and not g.tgisinternal loop
    execute format('alter table public.%I disable trigger user', r.relname);
  end loop;
  for r in select * from public.backup_tables() where tbl <> 'companies' order by ord desc loop
    execute format('delete from public.%I where %s', r.tbl, r.cond) using cid;
  end loop;
  for r in select c.table_name from information_schema.columns c join information_schema.tables x on x.table_schema = c.table_schema and x.table_name = c.table_name
            where c.table_schema = 'public' and c.column_name = 'company_id' and x.table_type = 'BASE TABLE' loop
    execute format('delete from public.%I where company_id = $1', r.table_name) using cid;
  end loop;
  delete from public.companies where id = cid;
  for r in select distinct c.relname from pg_trigger g join pg_class c on c.oid = g.tgrelid join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and not g.tgisinternal loop
    execute format('alter table public.%I enable trigger user', r.relname);
  end loop;
  raise notice 'انحذفت الشركة التجريبية';
end $del$;
select count(*) as remaining from public.companies where name = 'عالم الشخصيات للاكسسوارات والهدايا';
