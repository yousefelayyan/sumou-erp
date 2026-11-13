-- =====================================================================
--  السمو ERP — المرحلة 36: حقول إضافية لبطاقة العميل/المورد (مثل Stallion)
--  المرجع، الوصف #2 (اسم ثاني)، المسار (lookups kind = route)، الدائرة، العملة، وسيلة الدفع الافتراضية.
-- =====================================================================
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'public.lookups'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) like '%kind%' and pg_get_constraintdef(oid) not like '%route%' loop
    execute format('alter table public.lookups drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname in ('lookups_kind_chk3', 'lookups_kind_chk4')) then
    alter table public.lookups add constraint lookups_kind_chk3
      check (kind in ('payment_method','bank','bank_branch','country','region','cheque_type','sales_rep','loyalty_type','route'));
  end if;
end $$;

alter table public.parties add column if not exists reference text;
alter table public.parties add column if not exists name2 text;
alter table public.parties add column if not exists route_id uuid references public.lookups(id) on delete set null;
alter table public.parties add column if not exists department_id uuid references public.departments(id) on delete set null;
alter table public.parties add column if not exists currency text;
alter table public.parties add column if not exists payment_method_id uuid references public.lookups(id) on delete set null;

create or replace function public.ad_party_fields_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.route_id is not null and (tg_op = 'INSERT' or new.route_id is distinct from old.route_id)
     and not exists (select 1 from public.lookups where id = new.route_id and company_id = new.company_id and kind = 'route') then
    raise exception 'المسار مش من نفس الشركة';
  end if;
  if new.payment_method_id is not null and (tg_op = 'INSERT' or new.payment_method_id is distinct from old.payment_method_id)
     and not exists (select 1 from public.lookups where id = new.payment_method_id and company_id = new.company_id and kind = 'payment_method') then
    raise exception 'وسيلة الدفع مش من نفس الشركة';
  end if;
  if new.department_id is not null and (tg_op = 'INSERT' or new.department_id is distinct from old.department_id)
     and not exists (select 1 from public.departments where id = new.department_id and company_id = new.company_id and kind = 'sub') then
    raise exception 'الدائرة لازم تكون فرعية ومن نفس الشركة';
  end if;
  if new.currency is not null and (tg_op = 'INSERT' or new.currency is distinct from old.currency) then
    new.currency := nullif(upper(trim(new.currency)), '');
    if new.currency is not null and new.currency <> 'JOD' and not exists (select 1 from public.currencies where company_id = new.company_id and upper(code) = new.currency) then
      raise exception 'العملة «%» مش معرّفة بالشركة (مراكز الكلفة والعملات)', new.currency;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists ad_party_fields_check on public.parties;
create trigger ad_party_fields_check before insert or update on public.parties for each row execute function public.ad_party_fields_check();



-- نموذج الفاتورة ثنائي اللغة: اسم وعنوان الشركة بالإنجليزي، المشروع، وتفاصيل متعددة الأسطر لكل سطر
alter table public.companies add column if not exists name_en text;
alter table public.companies add column if not exists address_en text;
alter table public.invoices add column if not exists project text;
alter table public.orders add column if not exists project text;
alter table public.invoice_lines add column if not exists details text;
alter table public.order_lines add column if not exists details text;
