-- =====================================================================
--  المرحلة 85: حجز الكميات بطلبات المبيعات
--  orders.reserve (الطلب بيحجز كمياته) و orders.warehouse_id (مستودع الحجز؛ الفاضي = المستودع الافتراضي).
--  الطلب بيحجز إذا: طلب مبيعات، مفتوح، مش مغلق، reserve، وصلاحيته (valid_until) ما خلصت.
--  company_settings.reserve_orders = الافتراضي للطلبات الجديدة (بالواجهة).
--  items_available صار فيه reserved و free (= المتوفر − المحجوز). items_reservations للتقرير.
-- =====================================================================
alter table public.orders add column if not exists reserve boolean not null default false;
alter table public.orders add column if not exists warehouse_id uuid references public.warehouses(id) on delete set null;
alter table public.company_settings add column if not exists reserve_orders boolean not null default false;
create index if not exists orders_reserving on public.orders (company_id) where reserve and status = 'open' and not closed;

create or replace function public.ad_order_reserve_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.warehouse_id is not null and (tg_op = 'INSERT' or new.warehouse_id is distinct from old.warehouse_id)
     and not exists (select 1 from public.warehouses where id = new.warehouse_id and company_id = new.company_id) then
    raise exception 'المستودع مش من نفس الشركة';
  end if;
  if new.order_type <> 'sales_order' then new.reserve := false; end if;
  return new;
end $$;
drop trigger if exists ad_order_reserve_check on public.orders;
create trigger ad_order_reserve_check before insert or update on public.orders for each row execute function public.ad_order_reserve_check();

create or replace function public.reserve_default_wh(p_company uuid) returns uuid language sql stable set search_path = public as $$
  select id from public.warehouses where company_id = p_company and is_active order by code limit 1
$$;

-- المحجوز لكل صنف ومستودع (داخلية)
create or replace function public.reserved_rows(p_company uuid) returns table (item_id uuid, warehouse_id uuid, reserved numeric, orders bigint)
language sql stable security definer set search_path = public as $$
  select l.item_id, coalesce(o.warehouse_id, public.reserve_default_wh(p_company)), sum(l.qty), count(distinct o.id)
  from public.orders o join public.order_lines l on l.order_id = o.id
  where o.company_id = p_company and o.order_type = 'sales_order' and o.status = 'open' and not o.closed and o.reserve
    and (o.valid_until is null or o.valid_until >= public.local_today()) and l.item_id is not null and l.qty > 0
  group by 1, 2
$$;

drop function if exists public.items_available(uuid, uuid, date, uuid[]);
create or replace function public.items_available(p_company uuid, p_warehouse uuid, p_date date, p_items uuid[])
returns table (item_id uuid, code text, name text, available numeric, reserved numeric, free numeric)
language plpgsql stable security definer set search_path = public as $$
declare w uuid := p_warehouse;
begin
  if not (public.can(p_company, 'items', 'view') or public.can(p_company, 'inventory', 'view') or public.can(p_company, 'sales_invoices', 'add')
          or public.can(p_company, 'sales_invoices', 'edit') or public.can(p_company, 'sales_orders', 'add') or public.can(p_company, 'sales_orders', 'edit')) then
    raise exception 'ما عندك صلاحية';
  end if;
  if w is null then w := public.reserve_default_wh(p_company); end if;
  if w is null or not exists (select 1 from public.warehouses x where x.id = w and x.company_id = p_company) then return; end if;
  return query
  with r as (select * from public.reserved_rows(p_company) x where x.warehouse_id = w)
  select i.id, i.code, i.name, q.av, coalesce(r.reserved, 0), q.av - coalesce(r.reserved, 0)
    from public.items i
    cross join lateral (select public.stock_qty(i.id, w, coalesce(p_date, public.local_today())) av) q
    left join r on r.item_id = i.id
   where i.company_id = p_company and i.id = any(p_items) and i.item_type = 'goods' and i.track_stock;
end $$;

-- تقرير الحجوزات: لكل صنف ومستودع (الرصيد، المحجوز، الحر، عدد الطلبات)
create or replace function public.items_reservations(p_company uuid) returns table (item_id uuid, warehouse_id uuid, on_hand numeric, reserved numeric, free numeric, orders bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.can(p_company, 'inventory', 'view') or public.can(p_company, 'sales_orders', 'view')) then raise exception 'ما عندك صلاحية'; end if;
  return query
  select r.item_id, r.warehouse_id, public.stock_qty(r.item_id, r.warehouse_id, public.local_today()), r.reserved,
         public.stock_qty(r.item_id, r.warehouse_id, public.local_today()) - r.reserved, r.orders
  from public.reserved_rows(p_company) r where r.warehouse_id is not null;
end $$;

revoke execute on function public.ad_order_reserve_check(), public.reserved_rows(uuid) from public, anon, authenticated;
revoke execute on function public.reserve_default_wh(uuid) from public, anon;
revoke execute on function public.items_available(uuid, uuid, date, uuid[]), public.items_reservations(uuid) from public, anon;
grant execute on function public.items_available(uuid, uuid, date, uuid[]), public.items_reservations(uuid) to authenticated;
