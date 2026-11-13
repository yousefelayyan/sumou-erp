-- =====================================================================
--  السمو ERP — المرحلة 39: مراتب الولاء والاسترداد النقدي (Cashback)
--  المرتبة حسب مشتريات الزبون آخر 12 شهر، وكل مرتبة إلها نسبة استرداد.
--  الاسترداد بينحسب على كل فاتورة بيع مرحّلة (ناقص المرتجع) بنسبة مرتبة الزبون وقتها.
--  الصرف (استخدام الرصيد) بقيد: مدين مصروف الاسترداد، دائن حساب الزبون.
--  الصلاحية: شاشة marketing (العرض view، المراتب edit، الصرف post).
-- =====================================================================
create table if not exists public.loyalty_tiers (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  rank         int not null,
  name         text not null,
  min_spend    numeric(18,3) not null default 0 check (min_spend >= 0),
  cashback_pct numeric(6,3) not null default 0 check (cashback_pct >= 0 and cashback_pct <= 50),
  color        text,
  is_active    boolean not null default true,
  unique (company_id, rank)
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'loyalty_tiers_color_chk') then
    alter table public.loyalty_tiers add constraint loyalty_tiers_color_chk check (color is null or color ~ '^#[0-9A-Fa-f]{6}$');
  end if;
end $$;
alter table public.loyalty_tiers enable row level security;
grant select, insert, update, delete on public.loyalty_tiers to authenticated;
drop policy if exists lt_select on public.loyalty_tiers;
create policy lt_select on public.loyalty_tiers for select to authenticated using (public.can(company_id, 'marketing', 'view'));
drop policy if exists lt_write on public.loyalty_tiers;
create policy lt_write on public.loyalty_tiers for all to authenticated using (public.can(company_id, 'marketing', 'edit')) with check (public.can(company_id, 'marketing', 'edit'));

alter table public.company_settings add column if not exists cashback_account_id uuid references public.accounts(id) on delete set null;

create table if not exists public.loyalty_redemptions (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  party_id    uuid not null references public.parties(id),
  red_date    date not null,
  amount      numeric(18,3) not null check (amount > 0),
  entry_id    uuid references public.journal_entries(id) on delete set null,
  notes       text,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
alter table public.loyalty_redemptions enable row level security;
revoke insert, update, delete on public.loyalty_redemptions from authenticated;
grant select on public.loyalty_redemptions to authenticated;
drop policy if exists lr_select on public.loyalty_redemptions;
create policy lr_select on public.loyalty_redemptions for select to authenticated using (public.can(company_id, 'marketing', 'view'));

-- المرتبة لمبلغ مشتريات
create or replace function public.loyalty_tier_for(p_company uuid, p_spend numeric) returns public.loyalty_tiers
language sql stable security definer set search_path = public as $$
  select * from public.loyalty_tiers where company_id = p_company and is_active and min_spend <= coalesce(p_spend, 0) order by min_spend desc, rank desc limit 1;
$$;
revoke execute on function public.loyalty_tier_for(uuid, numeric) from public, anon, authenticated;

-- حالة الزبائن: مشتريات 12 شهر، المرتبة الحالية والجاية، المكتسب والمصروف والرصيد
create or replace function public.loyalty_cashback(p_company uuid, p_party uuid default null, p_date date default null)
returns table (party_id uuid, spend_12m numeric, tier_id uuid, tier_name text, tier_pct numeric, next_name text, next_min numeric, earned numeric, redeemed numeric, balance numeric)
language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_date, public.local_today());
begin
  if not public.can(p_company, 'marketing', 'view') then raise exception 'ما عندك صلاحية'; end if;
  return query
  with inv as (   -- فواتير البيع والمرتجع المرحّلة لحاملي البطاقات
    select v.party_id pid, v.inv_date, case when v.inv_type = 'sale_return' then -v.subtotal else v.subtotal end net
      from public.invoices v join public.parties p on p.id = v.party_id
     where v.company_id = p_company and v.status = 'posted' and v.inv_type in ('sale','sale_return') and v.inv_date <= d
       and p.party_type = 'customer' and p.loyalty_type_id is not null and (p_party is null or p.id = p_party)
  ), win as (     -- مشتريات الزبون بالسنة اللي قبل كل فاتورة (نافذة متحركة)
    select i.pid, i.net, coalesce(sum(i.net) over (partition by i.pid order by i.inv_date range between interval '364 days' preceding and interval '1 day' preceding), 0) prior
      from inv i
  ), earn as (    -- كل فاتورة بنسبة مرتبة الزبون وقتها
    select w.pid, w.net * coalesce(t.cashback_pct, 0) / 100 amt
      from win w left join lateral (select x.cashback_pct from public.loyalty_tiers x where x.company_id = p_company and x.is_active and x.min_spend <= w.prior
                                     order by x.min_spend desc, x.rank desc limit 1) t on true
  ), base as (
    select p.id pid,
           (select coalesce(sum(i.net), 0) from inv i where i.pid = p.id and i.inv_date > d - 365) s12,
           (select coalesce(sum(e.amt), 0) from earn e where e.pid = p.id) er,
           (select coalesce(sum(r.amount), 0) from public.loyalty_redemptions r where r.party_id = p.id and r.red_date <= d) rd
      from public.parties p
     where p.company_id = p_company and p.party_type = 'customer' and p.loyalty_type_id is not null and (p_party is null or p.id = p_party)
  )
  select b.pid, round(b.s12, 3), t.id, t.name, t.cashback_pct,
         (select n.name from public.loyalty_tiers n where n.company_id = p_company and n.is_active and n.min_spend > b.s12 order by n.min_spend limit 1),
         (select n.min_spend from public.loyalty_tiers n where n.company_id = p_company and n.is_active and n.min_spend > b.s12 order by n.min_spend limit 1),
         round(greatest(b.er, 0), 3), round(b.rd, 3), round(greatest(b.er, 0) - b.rd, 3)
    from base b left join lateral (select * from public.loyalty_tier_for(p_company, b.s12)) t on true;
end $$;
revoke execute on function public.loyalty_cashback(uuid, uuid, date) from public, anon;
grant execute on function public.loyalty_cashback(uuid, uuid, date) to authenticated;

-- صرف رصيد الاسترداد للزبون (بيخفّض ذمته): مدين مصروف الاسترداد، دائن حساب الزبون
create or replace function public.loyalty_redeem(p_party uuid, p_amount numeric, p_date date default null, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare p public.parties; st public.company_settings; bal numeric; fy uuid; eid uuid; d date := coalesce(p_date, public.local_today()); rid uuid;
  prev text := current_setting('sumou.internal', true); amt numeric := round(coalesce(p_amount, 0), 3);
begin
  select * into p from public.parties where id = p_party for update;
  if p.id is null or p.party_type <> 'customer' then raise exception 'الزبون مش موجود'; end if;
  if not public.can(p.company_id, 'marketing', 'post') then raise exception 'ما عندك صلاحية صرف الاسترداد النقدي'; end if;
  if amt <= 0 then raise exception 'المبلغ لازم أكبر من صفر'; end if;
  if exists (select 1 from public.loyalty_redemptions where party_id = p.id and red_date > d) then raise exception 'في صرف بتاريخ أحدث؛ اختار تاريخ بعده'; end if;
  -- المكتسب لتاريخ الصرف ناقص كل المصروف (بأي تاريخ)، وكمان الرصيد لليوم
  select earned into bal from public.loyalty_cashback(p.company_id, p.id, d);
  bal := coalesce(bal, 0) - coalesce((select sum(amount) from public.loyalty_redemptions where party_id = p.id), 0);
  bal := least(bal, coalesce((select balance from public.loyalty_cashback(p.company_id, p.id, greatest(d, public.local_today()))), 0));
  if bal < amt then raise exception 'رصيد الاسترداد (%) أقل من المبلغ', round(greatest(bal, 0), 3); end if;
  select * into st from public.company_settings where company_id = p.company_id;
  if st.cashback_account_id is null then raise exception 'حدّد حساب «مصروف الاسترداد النقدي» بحسابات الربط'; end if;
  if not exists (select 1 from public.accounts where id = st.cashback_account_id and company_id = p.company_id and not is_group and is_active and category = 'expenses') then
    raise exception 'حساب الاسترداد النقدي لازم يكون حساب مصاريف فرعي وفعّال من نفس الشركة';
  end if;
  if p.account_id is null then raise exception 'الزبون ما إله حساب'; end if;
  select id into fy from public.fiscal_years where company_id = p.company_id and d between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy is null then raise exception 'ما في سنة مالية مفتوحة بالتاريخ'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (p.company_id, fy, 'journal', d, 'صرف استرداد نقدي للزبون ' || p.name || coalesce(' — ' || nullif(trim(p_notes), ''), ''), 'استرداد نقدي', 'draft') returning id into eid;
  insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, 1, st.cashback_account_id, 'استرداد نقدي ' || p.name, amt, 0);
  insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, party_id) values (eid, 2, p.account_id, 'استرداد نقدي', 0, amt, p.id);
  update public.journal_entries set status = 'posted', total = amt, posted_by = auth.uid(), posted_at = now() where id = eid;
  insert into public.loyalty_redemptions (company_id, party_id, red_date, amount, entry_id, notes) values (p.company_id, p.id, d, amt, eid, nullif(trim(p_notes), '')) returning id into rid;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), p.company_id, 'ترحيل', 'loyalty_redemptions', rid::text, jsonb_build_object('party', p.name, 'amount', amt));
  return rid;
end $$;
revoke execute on function public.loyalty_redeem(uuid, numeric, date, text) from public, anon;
grant execute on function public.loyalty_redeem(uuid, numeric, date, text) to authenticated;

-- إلغاء صرف: قيد عكسي وبينحذف السطر من السجل
create or replace function public.loyalty_redeem_cancel(p_id uuid, p_date date default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.loyalty_redemptions; prev text := current_setting('sumou.internal', true);
begin
  select * into r from public.loyalty_redemptions where id = p_id for update;
  if r.id is null then raise exception 'مش موجود'; end if;
  if not public.can(r.company_id, 'marketing', 'post') then raise exception 'ما عندك صلاحية'; end if;
  if r.entry_id is not null and exists (select 1 from public.journal_entries where id = r.entry_id and status = 'posted') then
    perform set_config('sumou.loyalty', public.internal_token(), true);
    perform public.reverse_internal(r.entry_id, greatest(coalesce(p_date, public.local_today()), r.red_date), 'إلغاء صرف استرداد نقدي');
    perform set_config('sumou.loyalty', '', true);
    perform set_config('sumou.internal', coalesce(prev, ''), true);
  end if;
  delete from public.loyalty_redemptions where id = p_id;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), r.company_id, 'إلغاء', 'loyalty_redemptions', p_id::text, jsonb_build_object('amount', r.amount));
end $$;
revoke execute on function public.loyalty_redeem_cancel(uuid, date) from public, anon;
grant execute on function public.loyalty_redeem_cancel(uuid, date) to authenticated;

-- قيد الاسترداد ما بينعكس/بينلغى ترحيله من شاشة القيود (من شاشة الولاء بس)
create or replace function public.ab_loyalty_entry_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('sumou.loyalty', true), '') = public.internal_token() then return new; end if;
  if old.status = 'posted' and new.status is distinct from old.status
     and exists (select 1 from public.loyalty_redemptions where entry_id = old.id) then
    raise exception 'قيد الاسترداد النقدي بينلغى من شاشة بطاقات الولاء';
  end if;
  return new;
end $$;
drop trigger if exists ab_loyalty_entry_guard on public.journal_entries;
create trigger ab_loyalty_entry_guard before update of status on public.journal_entries for each row execute function public.ab_loyalty_entry_guard();

-- النسخ الاحتياطي
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1, 'companies', 'id = $1', 'code'),
   (2, 'fiscal_years', 'company_id = $1', 'start_date'),
   (3, 'accounts', 'company_id = $1', 'level, code'),
   (4, 'cost_centers', 'company_id = $1', 'code'),
   (5, 'currencies', 'company_id = $1', 'code'),
   (6, 'company_settings', 'company_id = $1', 'company_id'),
   (7, 'lookups', 'company_id = $1', 'parent_id nulls first, kind, code'),
   (8, 'custom_fields', 'company_id = $1', 'entity, sort'),
   (9, 'party_categories', 'company_id = $1', 'party_type, code'),
   (10, 'parties', 'company_id = $1', 'code'),
   (11, 'item_categories', 'company_id = $1', 'code'),
   (12, 'items', 'company_id = $1', 'code'),
   (13, 'promotions', 'company_id = $1', 'date_from'),
   (14, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (15, 'warehouses', 'company_id = $1', 'code'),
   (16, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (17, 'departments', 'company_id = $1', 'level, code'),
   (18, 'boms', 'company_id = $1', 'code'),
   (19, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (20, 'journal_entries', 'company_id = $1', 'created_at'),
   (21, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (22, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (23, 'invoices', 'company_id = $1', 'created_at'),
   (24, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (25, 'orders', 'company_id = $1', 'created_at'),
   (26, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (27, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (28, 'cheques', 'company_id = $1', 'created_at'),
   (29, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (30, 'supply_requests', 'company_id = $1', 'req_no'),
   (31, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (32, 'stock_docs', 'company_id = $1', 'created_at'),
   (33, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (34, 'stock_moves', 'company_id = $1', 'created_at'),
   (35, 'productions', 'company_id = $1', 'prod_no'),
   (36, 'obligations', 'company_id = $1', 'due_date'),
   (37, 'recurring_entries', 'company_id = $1', 'created_at'),
   (38, 'employees', 'company_id = $1', 'code'),
   (39, 'payroll_runs', 'company_id = $1', 'period'),
   (40, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (41, 'asset_custodians', 'company_id = $1', 'code'),
   (42, 'fixed_assets', 'company_id = $1', 'code'),
   (43, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (44, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (45, 'asset_movements', 'company_id = $1', 'mov_no'),
   (46, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (47, 'custody_docs', 'company_id = $1', 'doc_no'),
   (48, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (49, 'bank_recons', 'company_id = $1', 'created_at'),
   (50, 'bank_cleared', 'company_id = $1', 'line_id'),
   (51, 'attachments', 'company_id = $1', 'created_at'),
   (52, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
