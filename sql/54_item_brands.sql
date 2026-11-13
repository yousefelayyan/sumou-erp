-- =====================================================================
--  السمو ERP — المرحلة 54: الماركات وبيانات الصنف الإضافية (مثل Stallion «معلومات #1»)
--  الماركة (lookups kind = brand)، المنشأ (دولة من lookups kind = country)، اللون، المقاس، الطراز/الموديل.
-- =====================================================================
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'public.lookups'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) like '%kind%' and pg_get_constraintdef(oid) not like '%brand%' loop
    execute format('alter table public.lookups drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'lookups_kind_chk4') then
    alter table public.lookups add constraint lookups_kind_chk4
      check (kind in ('payment_method','bank','bank_branch','country','region','cheque_type','sales_rep','loyalty_type','route','brand'));
  end if;
end $$;

alter table public.items add column if not exists brand_id uuid references public.lookups(id) on delete set null;
alter table public.items add column if not exists origin_id uuid references public.lookups(id) on delete set null;
alter table public.items add column if not exists model text;
alter table public.items add column if not exists color text;
alter table public.items add column if not exists size text;
create index if not exists items_brand_idx on public.items(brand_id) where brand_id is not null;

create or replace function public.ad_item_brand_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.brand_id is not null and (tg_op = 'INSERT' or new.brand_id is distinct from old.brand_id)
     and not exists (select 1 from public.lookups where id = new.brand_id and company_id = new.company_id and kind = 'brand') then
    raise exception 'الماركة مش من نفس الشركة';
  end if;
  if new.origin_id is not null and (tg_op = 'INSERT' or new.origin_id is distinct from old.origin_id)
     and not exists (select 1 from public.lookups where id = new.origin_id and company_id = new.company_id and kind = 'country') then
    raise exception 'بلد المنشأ مش من نفس الشركة';
  end if;
  if length(coalesce(new.model, '')) > 200 or length(coalesce(new.color, '')) > 100 or length(coalesce(new.size, '')) > 100 then
    raise exception 'الطراز أو اللون أو المقاس طويل كثير';
  end if;
  return new;
end $$;
drop trigger if exists ad_item_brand_check on public.items;
create trigger ad_item_brand_check before insert or update on public.items
  for each row execute function public.ad_item_brand_check();
