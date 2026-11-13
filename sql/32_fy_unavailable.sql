-- =====================================================================
--  السمو ERP — المرحلة 32: السنوات المالية «غير المتاحة»
--  فتح السنة الجاية بدري (عقود، موازنات، أرصدة) بدون ما ينتقل المستخدمين لها.
--  السنة «غير المتاحة» بتشتغل حسب التاريخ، بس ما بتنختار تلقائياً، وبتبيّن بس
--  لمين إله صلاحية شاشة fy_unavailable. ممنوع على السنة اللي فيها تاريخ اليوم.
--  بتصير متاحة لحالها لما يبدأ تاريخها (company_settings.fy_auto_release).
-- =====================================================================
alter table public.fiscal_years add column if not exists unavailable boolean not null default false;
alter table public.company_settings add column if not exists fy_auto_release boolean not null default true;

create or replace function public.fy_unavailable_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.unavailable and (tg_op = 'INSERT' or not old.unavailable or new.start_date is distinct from old.start_date or new.end_date is distinct from old.end_date)
     and public.local_today() between new.start_date and new.end_date and not public.is_internal() then
    raise exception 'تاريخ اليوم داخل هالسنة المالية: ما بتصير «غير متاحة» (المستخدمين رح يضلّوا بدون سنة)';
  end if;
  return new;
end $$;
drop trigger if exists ad_fy_unavailable_check on public.fiscal_years;
create trigger ad_fy_unavailable_check before insert or update on public.fiscal_years
  for each row execute function public.fy_unavailable_check();

-- لما يبدأ تاريخ السنة «غير المتاحة» بتصير متاحة (عند دخول أي مستخدم للشركة)
create or replace function public.fy_release_started(p_company uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; y record;
begin
  if not public.has_company(p_company) then return 0; end if;
  if not coalesce((select fy_auto_release from public.company_settings where company_id = p_company), true) then return 0; end if;
  for y in select id, code from public.fiscal_years
            where company_id = p_company and unavailable and start_date <= public.local_today() and not is_closed loop
    update public.fiscal_years set unavailable = false where id = y.id;
    insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
    values (auth.uid(), p_company, 'تعديل', 'fiscal_years', y.id, jsonb_build_object('code', y.code, 'auto_available', true));
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.fy_release_started(uuid) from public, anon;
grant execute on function public.fy_release_started(uuid) to authenticated;
