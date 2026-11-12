-- =====================================================================
--  السمو ERP — المرحلة 17: فئات العملاء وفئات الموردين
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

create table if not exists public.party_categories (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  party_type text not null check (party_type in ('customer','supplier')),
  code       text not null,
  name       text not null,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, party_type, code)
);
alter table public.parties add column if not exists category_id uuid references public.party_categories(id) on delete restrict;
create index if not exists parties_cat_idx on public.parties (category_id) where category_id is not null;

-- الفئة لازم تكون لنفس الشركة ونفس النوع (فئة عملاء للعميل، وفئة موردين للمورد)
create or replace function public.parties_category_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.category_id is not null and not exists (select 1 from public.party_categories c
      where c.id = new.category_id and c.company_id = new.company_id and c.party_type = new.party_type) then
    raise exception 'الفئة مش لهالشركة أو مش من نفس النوع';
  end if;
  return new;
end $$;
drop trigger if exists parties_category_check on public.parties;
create trigger parties_category_check before insert or update of category_id, company_id, party_type on public.parties
  for each row execute function public.parties_category_check();
revoke execute on function public.parties_category_check() from public, anon, authenticated;

create or replace function public.party_categories_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then new.company_id := old.company_id; new.party_type := old.party_type; end if;
  new.code := btrim(new.code); new.name := btrim(new.name);
  if new.code = '' or new.name = '' then raise exception 'رمز الفئة واسمها مطلوبين'; end if;
  return new;
end $$;
drop trigger if exists party_categories_before on public.party_categories;
create trigger party_categories_before before insert or update on public.party_categories
  for each row execute function public.party_categories_before();
revoke execute on function public.party_categories_before() from public, anon, authenticated;

alter table public.party_categories enable row level security;
drop policy if exists pcat_select on public.party_categories;
create policy pcat_select on public.party_categories for select to authenticated using (public.has_company(company_id));
drop policy if exists pcat_insert on public.party_categories;
create policy pcat_insert on public.party_categories for insert to authenticated
  with check (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'add'));
drop policy if exists pcat_update on public.party_categories;
create policy pcat_update on public.party_categories for update to authenticated
  using (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'edit'))
  with check (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'edit'));
drop policy if exists pcat_delete on public.party_categories;
create policy pcat_delete on public.party_categories for delete to authenticated
  using (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'delete'));
grant select, insert, update, delete on public.party_categories to authenticated;
revoke all on public.party_categories from anon;
