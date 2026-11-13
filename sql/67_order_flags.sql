-- =====================================================================
--  السمو ERP — المرحلة 67: حقول الطلب الإضافية (زي ستاليون) ونوع الضريبة بالفاتورة
--  orders: payment_method_id، discount_pct (للعرض؛ الخصم بيتوزّع على السطور)، tax_mode، delivered/delivered_date، closed.
--  invoices.tax_mode: normal | exempt (معفى) | zero (نسبة صفر) | export (تصدير) — غير العادي سطوره بنسبة صفر.
--  order_set_flags(id, jsonb): «تم التسليم» و«مغلق» حتى بعد التحويل لفاتورة (بصلاحية edit على شاشة الطلب).
-- =====================================================================
alter table public.orders add column if not exists payment_method_id uuid references public.lookups(id) on delete set null;
alter table public.orders add column if not exists discount_pct numeric(6,3) not null default 0;
alter table public.orders add column if not exists tax_mode text not null default 'normal';
alter table public.orders add column if not exists delivered boolean not null default false;
alter table public.orders add column if not exists delivered_date date;
alter table public.orders add column if not exists closed boolean not null default false;
alter table public.invoices add column if not exists tax_mode text not null default 'normal';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'orders_tax_mode_chk') then
    alter table public.orders add constraint orders_tax_mode_chk check (tax_mode in ('normal','exempt','zero','export'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'orders_discount_pct_chk') then
    alter table public.orders add constraint orders_discount_pct_chk check (discount_pct between 0 and 100);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'invoices_tax_mode_chk') then
    alter table public.invoices add constraint invoices_tax_mode_chk check (tax_mode in ('normal','exempt','zero','export'));
  end if;
end $$;

-- وسيلة الدفع لازم من نفس الشركة
create or replace function public.ad_order_extra_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.payment_method_id is not null and (tg_op = 'INSERT' or new.payment_method_id is distinct from old.payment_method_id)
     and not exists (select 1 from public.lookups where id = new.payment_method_id and company_id = new.company_id and kind = 'payment_method') then
    raise exception 'وسيلة الدفع مش من نفس الشركة';
  end if;
  if not public.is_internal() and tg_op = 'UPDATE' then   -- التسليم والإغلاق من order_set_flags بس
    new.delivered := old.delivered; new.delivered_date := old.delivered_date; new.closed := old.closed;
  end if;
  if tg_op = 'INSERT' and not public.is_internal() then new.delivered := false; new.delivered_date := null; new.closed := false; end if;
  return new;
end $$;
drop trigger if exists ad_order_extra_check on public.orders;
create trigger ad_order_extra_check before insert or update on public.orders for each row execute function public.ad_order_extra_check();
revoke execute on function public.ad_order_extra_check() from public, anon, authenticated;

create or replace function public.order_set_flags(p_id uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare o public.orders; prev text := current_setting('sumou.internal', true);
begin
  select * into o from public.orders where id = p_id for update;
  if o.id is null then raise exception 'الطلب مش موجود'; end if;
  if not public.can(o.company_id, public.order_screen(o.order_type), 'edit') or not public.tenant_writable() then raise exception 'ما عندك صلاحية'; end if;
  if not public.dept_ok(o.company_id, o.department_id) then raise exception 'هالمستند لفرع ثاني'; end if;
  if o.is_frozen then raise exception 'الطلب مجمّد'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.orders set
    delivered = coalesce((p->>'delivered')::boolean, delivered),
    delivered_date = case when coalesce((p->>'delivered')::boolean, delivered) then coalesce(nullif(p->>'delivered_date','')::date, delivered_date, public.local_today()) end,
    closed = coalesce((p->>'closed')::boolean, closed),
    updated_by = auth.uid(), updated_at = now()
   where id = p_id;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), o.company_id, 'تعديل', 'orders', p_id::text, jsonb_build_object('no', o.order_no, 'flags', p));
end $$;
revoke execute on function public.order_set_flags(uuid, jsonb) from public, anon;
grant execute on function public.order_set_flags(uuid, jsonb) to authenticated;
