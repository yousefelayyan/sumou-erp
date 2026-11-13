-- =====================================================================
--  السمو ERP — المرحلة 45: التحقق من الكمية (مثل «تجاهل تتبع الكمية» بستاليون)
--  company_settings.block_negative_stock: منع الطلوع من المخزون بأكثر من المتوفر بالمستودع
--  items.qty_check_ignore: أنواع المستندات اللي ما بيتفحص فيها رصيد هالصنف
--    (sale, sale_return, purchase, purchase_return, pos, stock_out, stock_transfer, production, sales_order)
-- =====================================================================
alter table public.company_settings add column if not exists block_negative_stock boolean not null default false;
alter table public.items add column if not exists qty_check_ignore text[] not null default '{}';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'items_qty_check_ignore_chk') then
    alter table public.items add constraint items_qty_check_ignore_chk check (qty_check_ignore <@ array['sale','sale_return','purchase','purchase_return','pos','stock_out','stock_transfer','production','sales_order']::text[]);
  end if;
end $$;

create or replace function public.ab_stock_negative_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare kind text; ign text[]; bal numeric; it public.items; wn text;
begin
  if new.qty >= 0 then return new; end if;
  if new.created_at < now() - interval '2 minutes' then return new; end if;   -- استرجاع نسخة/تجربة: الحركات القديمة ما بتتفحص
  if not coalesce((select block_negative_stock from public.company_settings where company_id = new.company_id), false) then return new; end if;
  select * into it from public.items where id = new.item_id;
  if it.item_type <> 'goods' then return new; end if;
  if new.source_type = 'invoice' then
    select case when coalesce(pos, false) then 'pos' else inv_type end into kind from public.invoices where id = new.source_id;
  else
    select case when production_id is not null then 'production' when doc_type = 'out' then 'stock_out' when doc_type = 'transfer' then 'stock_transfer' else 'stock_' || doc_type end
      into kind from public.stock_docs where id = new.source_id;
  end if;
  if kind = any (coalesce(it.qty_check_ignore, '{}')) then return new; end if;
  perform pg_advisory_xact_lock(hashtext('stk:' || new.item_id || ':' || new.warehouse_id));
  select coalesce(sum(qty), 0) into bal from public.stock_moves where company_id = new.company_id and item_id = new.item_id and warehouse_id = new.warehouse_id and move_date <= new.move_date;
  if bal + new.qty < -0.0005 then
    select name into wn from public.warehouses where id = new.warehouse_id;
    raise exception 'الكمية المتوفرة من «%» بمستودع «%» (%) أقل من المطلوب (%). البيع بالسالب ممنوع بإعدادات الشركة', it.name, wn, round(bal, 3), round(-new.qty, 3);
  end if;
  return new;
end $$;
drop trigger if exists ab_stock_negative_guard on public.stock_moves;
create trigger ab_stock_negative_guard before insert on public.stock_moves for each row execute function public.ab_stock_negative_guard();
