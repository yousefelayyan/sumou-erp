-- =====================================================================
--  المرحلة 83: ملخص نهاية اليوم للكاشير وإغلاق الصندوق
--  pos_day_summary(company, day, user) → jsonb لكل كاشير: عدد الفواتير، المبيعات، الخصم، الضريبة، حسب وسيلة الدفع،
--    النقد المتوقع (وسائل حسابها نوعه cash)، الآجل، الملغى، المرتجعات اللي عملها بنفس اليوم، والإغلاق إذا انعمل.
--    الكاشير بيشوف حاله بس (pos add)، والمشرف (pos edit أو sales_invoices view) بيشوف الكل.
--  pos_closings: إغلاق صندوق لكل كاشير ويوم (المعدود، المتوقع، الفرق، تفاصيل الوسائل). بعد الإغلاق
--    ما بيقدر الكاشير يبيع من نقطة البيع بنفس اليوم (ab_pos_closed_check) لحد ما المشرف يفتحه (pos_reopen_day).
-- =====================================================================

create table if not exists public.pos_closings (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  cashier_id    uuid not null,
  day           date not null,
  invoices      int not null default 0,
  sales_total   numeric(18,3) not null default 0,
  expected_cash numeric(18,3) not null default 0,
  counted_cash  numeric(18,3) not null default 0,
  difference    numeric(18,3) not null default 0,
  details       jsonb not null default '{}',
  notes         text,
  closed_by     uuid not null default auth.uid(),
  closed_at     timestamptz not null default now(),
  unique (company_id, cashier_id, day)
);
alter table public.pos_closings enable row level security;
revoke insert, update, delete on public.pos_closings from authenticated;
grant select on public.pos_closings to authenticated;
drop policy if exists posc_select on public.pos_closings;
create policy posc_select on public.pos_closings for select to authenticated using (
  public.has_company(company_id) and (cashier_id = auth.uid() or public.can(company_id, 'pos', 'edit') or public.can(company_id, 'sales_invoices', 'view')));

create or replace function public.pos_sup(p_company uuid) returns boolean language sql stable security definer set search_path = public as $$
  select public.can(p_company, 'pos', 'edit') or public.can(p_company, 'sales_invoices', 'view')
$$;

create or replace function public.pos_day_rows(p_company uuid, p_day date, p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with inv as (
    select i.*, a.account_type = 'cash' as is_cash_acc
    from public.invoices i left join public.accounts a on a.id = i.cash_account_id
    where i.company_id = p_company and i.inv_date = p_day and i.pos and i.inv_type = 'sale'
      and (p_user is null or i.created_by = p_user)
  ), ret as (
    select r.created_by, count(*) n, sum(r.total) t from public.invoices r
    where r.company_id = p_company and r.inv_date = p_day and r.inv_type = 'sale_return' and r.status = 'posted'
      and (p_user is null or r.created_by = p_user) group by r.created_by
  ), u as (select distinct created_by uid from inv union select created_by from ret)
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', u.uid,
    'name', (select coalesce(nullif(full_name, ''), username) from public.profiles where id = u.uid),
    'invoices', (select count(*) from inv where created_by = u.uid and status = 'posted'),
    'cancelled', (select count(*) from inv where created_by = u.uid and status = 'cancelled'),
    'gross', (select coalesce(sum(subtotal + discount_total), 0) from inv where created_by = u.uid and status = 'posted'),
    'discount', (select coalesce(sum(discount_total), 0) from inv where created_by = u.uid and status = 'posted'),
    'tax', (select coalesce(sum(tax_total), 0) from inv where created_by = u.uid and status = 'posted'),
    'total', (select coalesce(sum(total), 0) from inv where created_by = u.uid and status = 'posted'),
    'credit', (select coalesce(sum(total), 0) from inv where created_by = u.uid and status = 'posted' and payment_type = 'credit'),
    'expected_cash', (select coalesce(sum(total), 0) from inv where created_by = u.uid and status = 'posted' and payment_type = 'cash' and is_cash_acc),
    'first_at', (select min(created_at) from inv where created_by = u.uid), 'last_at', (select max(created_at) from inv where created_by = u.uid),
    'methods', (select coalesce(jsonb_agg(jsonb_build_object('method', m, 'count', n, 'total', t, 'cash', c) order by t desc), '[]') from (
        select coalesce(case when payment_type = 'credit' then 'آجل' end, nullif(pos_method, ''), 'نقدي') m, count(*) n, sum(total) t, bool_and(coalesce(is_cash_acc, false) and payment_type = 'cash') c
        from inv where created_by = u.uid and status = 'posted' group by 1) x),
    'returns', (select n from ret where created_by = u.uid), 'returns_total', (select t from ret where created_by = u.uid),
    'closing', (select to_jsonb(c) from public.pos_closings c where c.company_id = p_company and c.cashier_id = u.uid and c.day = p_day)
  ) order by 2), '[]')
  from u where u.uid is not null
$$;
revoke execute on function public.pos_day_rows(uuid, date, uuid) from public, anon, authenticated;

create or replace function public.pos_day_summary(p_company uuid, p_day date, p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_company(p_company) then raise exception 'ما عندك صلاحية'; end if;
  if public.pos_sup(p_company) then return public.pos_day_rows(p_company, p_day, p_user); end if;
  if not public.can(p_company, 'pos', 'add') then raise exception 'ما عندك صلاحية'; end if;
  return public.pos_day_rows(p_company, p_day, auth.uid());   -- الكاشير: حاله بس
end $$;

create or replace function public.pos_close_day(p_company uuid, p_day date, p_counted numeric, p_notes text default null, p_user uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare u uuid := coalesce(p_user, auth.uid()); r jsonb; cid uuid;
begin
  if not public.tenant_writable() then raise exception 'الاشتراك منتهي'; end if;
  if u = auth.uid() then
    if not (public.can(p_company, 'pos', 'add') or public.pos_sup(p_company)) then raise exception 'ما عندك صلاحية'; end if;
  elsif not public.can(p_company, 'pos', 'edit') then raise exception 'إغلاق صندوق كاشير ثاني للمشرف (تعديل نقطة البيع)'; end if;
  if p_day is null or p_day > public.local_today() then raise exception 'التاريخ مش صحيح'; end if;
  if p_counted is null or p_counted < 0 then raise exception 'المبلغ المعدود مش صحيح'; end if;
  if exists (select 1 from public.pos_closings where company_id = p_company and cashier_id = u and day = p_day) then raise exception 'الصندوق مسكّر لهاليوم'; end if;
  r := public.pos_day_rows(p_company, p_day, u) -> 0;
  insert into public.pos_closings (company_id, cashier_id, day, invoices, sales_total, expected_cash, counted_cash, difference, details, notes, closed_by)
  values (p_company, u, p_day, coalesce((r ->> 'invoices')::int, 0), coalesce((r ->> 'total')::numeric, 0), coalesce((r ->> 'expected_cash')::numeric, 0),
          round(p_counted, 3), round(p_counted - coalesce((r ->> 'expected_cash')::numeric, 0), 3), coalesce(r - 'closing', '{}'), left(nullif(trim(p_notes), ''), 500), auth.uid())
  returning id into cid;
  return cid;
end $$;

create or replace function public.pos_reopen_day(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c public.pos_closings;
begin
  select * into c from public.pos_closings where id = p_id;
  if c.id is null then raise exception 'الإغلاق مش موجود'; end if;
  if not public.can(c.company_id, 'pos', 'edit') or not public.tenant_writable() then raise exception 'فتح الصندوق للمشرف (تعديل نقطة البيع)'; end if;
  delete from public.pos_closings where id = p_id;
end $$;

-- بعد الإغلاق ما في بيع من نقطة البيع لنفس الكاشير بنفس اليوم
create or replace function public.ab_pos_closed_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.pos and new.inv_type = 'sale' and exists (select 1 from public.pos_closings
      where company_id = new.company_id and cashier_id = coalesce(auth.uid(), new.created_by) and day = new.inv_date) then
    raise exception 'سكّرت صندوق اليوم. اطلب من المشرف يفتحه إذا بدك تبيع';
  end if;
  return new;
end $$;
drop trigger if exists ab_pos_closed_check on public.invoices;
create trigger ab_pos_closed_check before insert on public.invoices for each row execute function public.ab_pos_closed_check();

revoke execute on function public.ab_pos_closed_check(), public.pos_sup(uuid) from public, anon, authenticated;
revoke execute on function public.pos_day_summary(uuid, date, uuid), public.pos_close_day(uuid, date, numeric, text, uuid), public.pos_reopen_day(uuid) from public, anon;
grant execute on function public.pos_day_summary(uuid, date, uuid), public.pos_close_day(uuid, date, numeric, text, uuid), public.pos_reopen_day(uuid) to authenticated;
