-- =====================================================================
--  السمو ERP — المرحلة 24: مندوبي المبيعات
--  المندوب بيتعرّف بقوائم الإعداد (kind = sales_rep) مع نسبة عمولة،
--  وبينربط على العميل (افتراضي) وعلى الفاتورة. تقرير مبيعات وتحصيلات المندوبين من الواجهة.
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

alter table public.lookups add column if not exists rate numeric(9,3);   -- نسبة العمولة % للمندوب
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'public.lookups'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) like '%kind%' and pg_get_constraintdef(oid) not like '%sales_rep%' loop
    execute format('alter table public.lookups drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname in ('lookups_kind_chk', 'lookups_kind_chk2')) then
    alter table public.lookups add constraint lookups_kind_chk
      check (kind in ('payment_method','bank','bank_branch','country','region','cheque_type','sales_rep'));
  end if;
end $$;

alter table public.parties  add column if not exists sales_rep_id uuid references public.lookups(id) on delete set null;
alter table public.invoices add column if not exists sales_rep_id uuid references public.lookups(id) on delete restrict;
create index if not exists invoices_rep_idx on public.invoices (company_id, sales_rep_id);

create or replace function public.ad_sales_rep_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if public.is_internal() then return new; end if;
  cid := case when tg_op = 'UPDATE' then old.company_id else new.company_id end;
  if new.sales_rep_id is not null and (tg_op = 'INSERT' or new.sales_rep_id is distinct from old.sales_rep_id)
     and not exists (select 1 from public.lookups l where l.id = new.sales_rep_id and l.company_id = cid and l.kind = 'sales_rep' and l.is_active) then
    raise exception 'المندوب مش موجود أو مش فعّال بهالشركة';
  end if;
  return new;
end $$;
-- الفاتورة الجديدة بتاخذ مندوب العميل إذا ما انختار (قبل الفحص)
create or replace function public.ad_invoice_rep_default() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_internal() and new.sales_rep_id is null and new.party_id is not null then
    select p.sales_rep_id into new.sales_rep_id from public.parties p
     where p.id = new.party_id and p.company_id = new.company_id and p.party_type = 'customer';
  end if;
  return new;
end $$;
drop trigger if exists ad_invoice_rep_default on public.invoices;
create trigger ad_invoice_rep_default before insert on public.invoices
  for each row execute function public.ad_invoice_rep_default();
drop trigger if exists ad_sales_rep_check on public.invoices;
create trigger ad_sales_rep_check before insert or update of sales_rep_id on public.invoices
  for each row execute function public.ad_sales_rep_check();
drop trigger if exists ad_sales_rep_check on public.parties;
create trigger ad_sales_rep_check before insert or update of sales_rep_id on public.parties
  for each row execute function public.ad_sales_rep_check();
