-- =====================================================================
--  السمو ERP — المرحلة 62: عدد الخانات العشرية بالعرض والطباعة لكل نوع حقل
--  company_settings.decimals = {amount, qty, price} كل وحدة من 0 لـ 3 (التخزين بيضل 3 خانات).
-- =====================================================================
alter table public.company_settings add column if not exists decimals jsonb not null default '{}'::jsonb;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'company_settings_decimals_chk') then
    alter table public.company_settings add constraint company_settings_decimals_chk check (
      jsonb_typeof(decimals) = 'object'
      and coalesce((decimals ->> 'amount')::int, 3) between 0 and 3
      and coalesce((decimals ->> 'qty')::int, 3) between 0 and 3
      and coalesce((decimals ->> 'price')::int, 3) between 0 and 3);
  end if;
end $$;
