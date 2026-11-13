-- =====================================================================
--  السمو ERP — المرحلة 74: البونص (الكمية المجانية) والعروض بالشرائح
--  invoice_lines.is_bonus: سطر مجاني (سعر وخصم وضريبة ومجاميع = صفر)؛ بيطلع/بيدخل المخزون عادي بكلفته،
--  فالبيع: كلفته على كلفة المبيعات، والشراء: بينزّل متوسط الكلفة. ضوابط السعر ما بتنطبق عليه.
--  promotions: buy_qty/free_qty/free_repeat (اشترِ N خذ M، ومضاعفاتها) والخصم صار اختياري؛ الشرائح = أكثر من عرض بأقل كمية مختلفة.
-- =====================================================================
alter table public.invoice_lines add column if not exists is_bonus boolean not null default false;

create or replace function public.ab_invoice_bonus() returns trigger
language plpgsql as $$
begin
  if new.is_bonus then
    new.unit_price := 0; new.discount := 0; new.tax_rate := 0; new.subtotal := 0; new.tax_amount := 0; new.line_total := 0;
  end if;
  return new;
end $$;
drop trigger if exists ab_invoice_bonus on public.invoice_lines;
create trigger ab_invoice_bonus before insert or update on public.invoice_lines for each row execute function public.ab_invoice_bonus();

-- ضوابط سعر البيع (المرحلة 50) بتتخطّى سطر البونص
create or replace function public.ab_sale_price_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv public.invoices; it public.items; cat public.item_categories; net_unit numeric; gross numeric; disc_pct numeric; maxd numeric; minp numeric; cost numeric; blk boolean;
begin
  if public.is_internal() or new.item_id is null or coalesce(new.is_bonus, false) then return new; end if;
  if tg_op = 'UPDATE' and new.unit_price = old.unit_price and new.discount = old.discount and new.qty = old.qty and new.item_id is not distinct from old.item_id then return new; end if;
  select * into inv from public.invoices where id = new.invoice_id;
  if inv.inv_type <> 'sale' then return new; end if;
  if public.is_admin() or public.can(inv.company_id, 'price_override', 'edit') then return new; end if;
  select * into it from public.items where id = new.item_id;
  select * into cat from public.item_categories where id = it.category_id;
  gross := new.qty * new.unit_price;
  net_unit := case when new.qty > 0 then (gross - new.discount) / new.qty else 0 end;
  -- السعر اللي داخل بالفاتورة ممكن يكون شامل الضريبة؛ الفحص على السعر قبل الضريبة
  if inv.prices_include_tax and new.tax_rate > 0 then net_unit := net_unit / (1 + new.tax_rate / 100); end if;
  disc_pct := case when gross > 0 then new.discount * 100 / gross else 0 end;
  maxd := coalesce(it.max_discount_pct, cat.max_discount_pct);
  if maxd is not null and disc_pct > maxd + 0.0005 then
    raise exception 'الخصم على «%» (% %%) أكثر من المسموح (% %%)', it.name, round(disc_pct, 2), maxd;
  end if;
  minp := it.min_price;
  if minp is not null and net_unit + 0.0005 < minp then
    raise exception 'سعر «%» بعد الخصم (%) أقل من أقل سعر بيع (%)', it.name, round(net_unit, 3), minp;
  end if;
  select block_below_cost into blk from public.company_settings where company_id = inv.company_id;
  if coalesce(blk, false) or cat.min_margin_pct is not null then
    cost := public.item_avg_cost(inv.company_id, new.item_id, inv.inv_date);
    if coalesce(cost, 0) > 0 then
      if coalesce(blk, false) and net_unit + 0.0005 < cost then
        raise exception 'سعر «%» بعد الخصم (%) أقل من الكلفة (%)', it.name, round(net_unit, 3), round(cost, 3);
      end if;
      if cat.min_margin_pct is not null and net_unit + 0.0005 < cost * (1 + cat.min_margin_pct / 100) then
        raise exception 'سعر «%» أقل من هامش الربح الأدنى لفئته (% %%)', it.name, cat.min_margin_pct;
      end if;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists ab_sale_price_guard on public.invoice_lines;
create trigger ab_sale_price_guard before insert or update on public.invoice_lines for each row execute function public.ab_sale_price_guard();

alter table public.promotions add column if not exists buy_qty numeric(18,3);
alter table public.promotions add column if not exists free_qty numeric(18,3);
alter table public.promotions add column if not exists free_repeat boolean not null default true;
alter table public.promotions drop constraint if exists promotions_discount_pct_check;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'promotions_offer_chk') then
    alter table public.promotions add constraint promotions_offer_chk check (
      discount_pct >= 0 and discount_pct <= 100
      and (buy_qty is null) = (free_qty is null) and (buy_qty is null or (buy_qty > 0 and free_qty > 0))
      and (discount_pct > 0 or free_qty is not null));
  end if;
end $$;
