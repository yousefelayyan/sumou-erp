-- =====================================================================
--  السمو ERP — المرحلة 15: تصليحات المراجعة
-- =====================================================================

-- حذف مستخدم أنشأ شركة: الشركة بتضل وبينفضى «أنشأها»
alter table public.companies drop constraint if exists companies_created_by_fkey;
alter table public.companies add constraint companies_created_by_fkey foreign key (created_by) references auth.users(id) on delete set null;

-- المسيّر الملغى ما بيقفل الشهر: بتقدر تعمل مسيّر جديد لنفس الشهر
alter table public.payroll_runs drop constraint if exists payroll_runs_company_id_period_key;
create unique index if not exists payroll_runs_period_uq on public.payroll_runs (company_id, period) where status <> 'cancelled';

-- سطور التسوية البنكية والرواتب: العرض بصلاحية «عرض»، والتعديل والحذف بصلاحية «تعديل»
drop policy if exists bc_all on public.bank_cleared;
drop policy if exists bc_select on public.bank_cleared;
drop policy if exists bc_write on public.bank_cleared;
create policy bc_select on public.bank_cleared for select to authenticated using (public.can(company_id, 'bank_recon', 'view'));
create policy bc_write on public.bank_cleared for all to authenticated
  using (public.can(company_id, 'bank_recon', 'edit'))
  with check (exists (select 1 from public.bank_recons r where r.id = recon_id and public.can(r.company_id, 'bank_recon', 'edit')));

drop policy if exists pl_all on public.payroll_lines;
drop policy if exists pl_select on public.payroll_lines;
drop policy if exists pl_write on public.payroll_lines;
create policy pl_select on public.payroll_lines for select to authenticated
  using (exists (select 1 from public.payroll_runs r where r.id = run_id and public.can(r.company_id, 'payroll', 'view')));
create policy pl_write on public.payroll_lines for all to authenticated
  using (exists (select 1 from public.payroll_runs r where r.id = run_id and public.can(r.company_id, 'payroll', 'edit')))
  with check (exists (select 1 from public.payroll_runs r where r.id = run_id and public.can(r.company_id, 'payroll', 'edit')));

-- المرفقات: مرفقات الموظفين والرواتب والأصول لأصحاب صلاحيتها بس، والحذف لصاحب الملف أو المدير
create or replace function public.attachment_visible(p_company uuid, p_entity text) returns boolean
language sql stable security definer set search_path = public as $$
  select case p_entity when 'employee' then public.can(p_company, 'payroll', 'view')
                       when 'payroll'  then public.can(p_company, 'payroll', 'view')
                       when 'asset'    then public.can(p_company, 'fixed_assets', 'view')
                       else public.has_company(p_company) end;
$$;
drop policy if exists att_select on public.attachments;
create policy att_select on public.attachments for select to authenticated using (public.attachment_visible(company_id, entity));

do $$
begin
  if to_regclass('storage.objects') is not null then
    execute 'drop policy if exists sumou_att_select on storage.objects';
    execute 'drop policy if exists sumou_att_delete on storage.objects';
    execute $p$create policy sumou_att_select on storage.objects for select to authenticated
      using (bucket_id = 'attachments' and exists (select 1 from public.attachments a where a.path = name and public.attachment_visible(a.company_id, a.entity)))$p$;
    execute $p$create policy sumou_att_delete on storage.objects for delete to authenticated
      using (bucket_id = 'attachments' and public.has_company(((storage.foldername(name))[1])::uuid)
             and not exists (select 1 from public.attachments a where a.path = name and not (a.created_by = auth.uid() or public.is_admin())))$p$;
  end if;
end $$;
