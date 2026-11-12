-- =====================================================================
--  السمو ERP — المرحلة 20: بطاقات المصاريف (أستاذ مساعد للمصاريف مثل العملاء)
--  كل بطاقة مصروف (كهرباء، إيجار، صيانة سيارات…) مربوطة على حساب مصاريف،
--  وبتنختار بسطور السندات مثل العميل/المورد، وإلها كشف حساب وأستاذ مساعد.
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

-- نوع الطرف صار: عميل، مورد، مصروف
do $$
declare c record;
begin
  for c in select con.conname, rel.relname from pg_constraint con join pg_class rel on rel.oid = con.conrelid
           join pg_namespace n on n.oid = rel.relnamespace
           where n.nspname = 'public' and rel.relname in ('parties','party_categories') and con.contype = 'c'
             and pg_get_constraintdef(con.oid) like '%party_type%' and pg_get_constraintdef(con.oid) not like '%expense%' loop
    execute format('alter table public.%I drop constraint %I', c.relname, c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'parties_party_type_chk') then
    alter table public.parties add constraint parties_party_type_chk check (party_type in ('customer','supplier','expense'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'party_categories_party_type_chk') then
    alter table public.party_categories add constraint party_categories_party_type_chk check (party_type in ('customer','supplier','expense'));
  end if;
end $$;

-- الشاشة (للصلاحيات) لكل نوع طرف
create or replace function public.party_screen(p_type text) returns text
language sql immutable as $$
  select case p_type when 'customer' then 'customers' when 'supplier' then 'suppliers' else 'expense_cards' end
$$;

-- رمز تلقائي: C للعملاء، S للموردين، E للمصاريف. وبطاقة المصروف لازم على حساب مصاريف
create or replace function public.parties_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare a public.accounts; n int;
begin
  select * into a from public.accounts where id = new.account_id;
  if a.id is null or a.company_id <> new.company_id then raise exception 'الحساب مش لهالشركة'; end if;
  if a.is_group then raise exception 'حساب الطرف لازم يكون حساب فرعي'; end if;
  if tg_op = 'UPDATE' then new.company_id := old.company_id; new.party_type := old.party_type; end if;
  if new.party_type = 'expense' and a.category <> 'expenses' then raise exception 'بطاقة المصروف لازم تكون على حساب من المصاريف'; end if;
  if tg_op = 'INSERT' and (new.code is null or new.code = '') then
    select coalesce(max(nullif(regexp_replace(code, '\D', '', 'g'), '')::int), 0) + 1 into n
      from public.parties where company_id = new.company_id and party_type = new.party_type;
    new.code := case new.party_type when 'customer' then 'C' when 'supplier' then 'S' else 'E' end || lpad(n::text, 4, '0');
  end if;
  return new;
end $$;

drop policy if exists parties_select on public.parties;
create policy parties_select on public.parties for select to authenticated
  using (public.can(company_id, public.party_screen(party_type), 'view') or public.has_company(company_id));
drop policy if exists parties_insert on public.parties;
create policy parties_insert on public.parties for insert to authenticated
  with check (public.can(company_id, public.party_screen(party_type), 'add'));
drop policy if exists parties_update on public.parties;
create policy parties_update on public.parties for update to authenticated
  using (public.can(company_id, public.party_screen(party_type), 'edit'))
  with check (public.can(company_id, public.party_screen(party_type), 'edit'));
drop policy if exists parties_delete on public.parties;
create policy parties_delete on public.parties for delete to authenticated
  using (public.can(company_id, public.party_screen(party_type), 'delete'));

drop policy if exists pcat_insert on public.party_categories;
create policy pcat_insert on public.party_categories for insert to authenticated
  with check (public.can(company_id, public.party_screen(party_type), 'add'));
drop policy if exists pcat_update on public.party_categories;
create policy pcat_update on public.party_categories for update to authenticated
  using (public.can(company_id, public.party_screen(party_type), 'edit'))
  with check (public.can(company_id, public.party_screen(party_type), 'edit'));
drop policy if exists pcat_delete on public.party_categories;
create policy pcat_delete on public.party_categories for delete to authenticated
  using (public.can(company_id, public.party_screen(party_type), 'delete'));
