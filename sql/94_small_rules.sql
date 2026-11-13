-- =====================================================================
--  المرحلة 94: ضوابط أنواع السندات + دفعة مقدمة على طلب المبيعات + كوبونات السحب
--  doc_types.require_attach: ما بيترحّل السند إلا إذا عليه مرفق
--  doc_types.require_party:  سطر على حساب عملاء/موردين (account_type customer/supplier) لازم عليه طرف
--  doc_types.allowed_accounts: الحسابات (أو الحسابات الرئيسية وفروعها) المسموحة بسطور هالنوع
--  الفحص بـ post_entry (ترحيل المستخدم)، مش بالترحيل الداخلي (الرواتب، المندوب…)
-- =====================================================================
alter table public.doc_types add column if not exists require_attach boolean not null default false;
alter table public.doc_types add column if not exists require_party boolean not null default false;
alter table public.doc_types add column if not exists allowed_accounts uuid[];

create or replace function public.ad_doc_type_accounts_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.allowed_accounts is not null then
    new.allowed_accounts := nullif((select array_agg(distinct x) from unnest(new.allowed_accounts) x where x is not null), '{}');
    if cardinality(coalesce(new.allowed_accounts, '{}')) > 200 then raise exception 'الحسابات المسموحة كثير (200 كحد أقصى)'; end if;
    if exists (select 1 from unnest(coalesce(new.allowed_accounts, '{}')) x where not exists (select 1 from public.accounts a where a.id = x and a.company_id = new.company_id)) then
      raise exception 'الحسابات المسموحة لازم من نفس الشركة';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists ad_doc_type_accounts_check on public.doc_types;
create trigger ad_doc_type_accounts_check before insert or update of allowed_accounts on public.doc_types for each row execute function public.ad_doc_type_accounts_check();

create or replace function public.entry_doctype_check(p_id uuid) returns void
language plpgsql stable security definer set search_path = public as $$
declare e public.journal_entries; t public.doc_types; bad text;
begin
  select * into e from public.journal_entries where id = p_id;
  if e.doc_type_id is null then return; end if;
  select * into t from public.doc_types where id = e.doc_type_id;
  if t.id is null then return; end if;
  if t.require_attach and not exists (select 1 from public.attachments where company_id = e.company_id and entity = 'entry' and entity_id = p_id) then
    raise exception 'نوع السند «%» بدّه مرفق قبل الترحيل (📎 مرفقات)', t.name;
  end if;
  if t.require_party then
    select string_agg(distinct a.code || ' ' || a.name, '، ') into bad from public.journal_lines l join public.accounts a on a.id = l.account_id
     where l.entry_id = p_id and a.account_type in ('customer','supplier') and l.party_id is null;
    if bad is not null then raise exception 'سطر على حساب الذمم لازم يكون عليه عميل/مورد: %', bad; end if;
  end if;
  if t.allowed_accounts is not null then
    with recursive ok as (select a.id from public.accounts a where a.id = any(t.allowed_accounts)
                          union select c.id from public.accounts c join ok on c.parent_id = ok.id)
    select string_agg(distinct a.code || ' ' || a.name, '، ') into bad from public.journal_lines l join public.accounts a on a.id = l.account_id
     where l.entry_id = p_id and l.account_id not in (select id from ok);
    if bad is not null then raise exception 'حسابات مش مسموحة بنوع السند «%»: %', t.name, bad; end if;
  end if;
end $$;
revoke execute on function public.entry_doctype_check(uuid) from public, anon, authenticated;

create or replace function public.post_entry(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries; d numeric; c numeric; n int; fy public.fiscal_years;
begin
  select * into e from public.journal_entries where id = p_id for update;
  if e.id is null then raise exception 'القيد غير موجود'; end if;
  if not public.can(e.company_id, public.entry_screen(e.entry_type), 'post') then raise exception 'ما عندك صلاحية ترحيل'; end if;
  if e.status <> 'draft' then raise exception 'القيد مرحّل من قبل'; end if;
  select * into fy from public.fiscal_years where id = e.fiscal_year_id;
  if fy.is_closed then raise exception 'السنة المالية مغلقة'; end if;
  select coalesce(sum(debit),0), coalesce(sum(credit),0), count(*) into d, c, n from public.journal_lines where entry_id = p_id;
  if n < 2 then raise exception 'القيد لازم يكون فيه سطرين على الأقل'; end if;
  if d <> c then raise exception 'القيد مش متوازن: المدين % والدائن %', d, c; end if;
  if d = 0 then raise exception 'القيد بدون مبالغ'; end if;
  if e.order_id is not null and exists (select 1 from public.journal_lines l where l.entry_id = p_id and l.party_id is not null
       and l.party_id is distinct from (select party_id from public.orders where id = e.order_id)) then
    raise exception 'الدفعة المقدمة لازم تكون من عميل الطلب نفسه';
  end if;
  -- ضوابط نوع السند بس لما المستخدم يرحّل مباشرة (مش من دفعات المندوب والخصومات والتسويات)
  if position('post_entry' in lower(coalesce(current_query(), ''))) > 0 then perform public.entry_doctype_check(p_id); end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.journal_entries set status = 'posted', total = d, posted_by = auth.uid(), posted_at = now() where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), e.company_id, 'ترحيل', public.entry_screen(e.entry_type), p_id::text, jsonb_build_object('no', e.entry_no, 'total', d));
end $$;

-- =====================================================================
--  دفعة مقدمة على طلب المبيعات: journal_entries.order_id (سند قبض بس، نفس الشركة، نفس العميل)
-- =====================================================================
alter table public.journal_entries add column if not exists order_id uuid;
do $$ begin
  if exists (select 1 from pg_constraint where conname = 'journal_entries_order_id_fkey' and not condeferrable) then
    alter table public.journal_entries drop constraint journal_entries_order_id_fkey;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'journal_entries_order_id_fkey') then
    alter table public.journal_entries add constraint journal_entries_order_id_fkey foreign key (order_id) references public.orders(id) on delete set null deferrable initially deferred;
  end if;
end $$;
create index if not exists journal_entries_order on public.journal_entries (order_id) where order_id is not null;
create or replace function public.ad_entry_order_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  if new.order_id is null or (tg_op = 'UPDATE' and new.order_id is not distinct from old.order_id) then return new; end if;
  if public.is_internal() and tg_op = 'INSERT' then return new; end if;
  if new.entry_type <> 'receipt' then raise exception 'الدفعة المقدمة بسند قبض بس'; end if;
  select * into o from public.orders where id = new.order_id;
  if o.id is null or o.company_id <> new.company_id or o.order_type <> 'sales_order' then raise exception 'الطلب مش من هالشركة'; end if;
  if not public.can(o.company_id, 'sales_orders', 'view') then raise exception 'ما عندك صلاحية على طلبات المبيعات'; end if;
  if o.status = 'cancelled' or o.closed then raise exception 'الطلب ملغى أو مغلق'; end if;
  if not public.dept_ok(o.company_id, o.department_id) then raise exception 'الطلب من فرع ثاني'; end if;
  return new;
end $$;
drop trigger if exists ad_entry_order_check on public.journal_entries;
create trigger ad_entry_order_check before insert or update of order_id on public.journal_entries for each row execute function public.ad_entry_order_check();

-- مجموع الدفعات المقدمة الفعّالة لكل طلب
create or replace function public.order_advances(p_company uuid, p_orders uuid[] default null)
returns table (order_id uuid, posted numeric, draft numeric, entries int)
language sql stable security definer set search_path = public as $$
  select e.order_id, coalesce(sum(e.total) filter (where e.status = 'posted' and e.reversed_by is null), 0),
         coalesce(sum((select sum(l.debit) from public.journal_lines l where l.entry_id = e.id)) filter (where e.status = 'draft'), 0), count(*)::int
    from public.journal_entries e
   where e.company_id = p_company and e.order_id is not null and (p_orders is null or e.order_id = any(p_orders))
     and e.status in ('draft','posted') and public.can(p_company, 'sales_orders', 'view')
     and public.dept_ok(p_company, e.department_id)
   group by e.order_id;
$$;
revoke execute on function public.order_advances(uuid, uuid[]) from public, anon;
grant execute on function public.order_advances(uuid, uuid[]) to authenticated;

-- =====================================================================
--  كوبونات السحب: كوبون لكل X دينار من صافي مشتريات العميل المرحّلة بالفترة (بعد المرتجع)
-- =====================================================================
create or replace function public.coupon_counts(p_company uuid, p_from date, p_to date, p_per numeric, p_category uuid default null)
returns table (party_id uuid, code text, name text, mobile text, net numeric, coupons int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'marketing', 'view') then raise exception 'ما عندك صلاحية'; end if;
  if coalesce(p_per, 0) <= 0 then raise exception 'اكتب قيمة الكوبون'; end if;
  if p_to < p_from or p_to - p_from > 400 then raise exception 'الفترة غلط'; end if;
  return query
  select p.id, p.code, p.name, coalesce(p.mobile, p.phone), round(s.net, 3), floor(s.net / p_per)::int
    from (select i.party_id pid, sum(case when i.inv_type = 'sale' then i.subtotal else -i.subtotal end) net
            from public.invoices i
           where i.company_id = p_company and i.status = 'posted' and i.inv_type in ('sale','sale_return')
             and i.inv_date between p_from and p_to and i.party_id is not null and public.dept_ok(p_company, i.department_id)
           group by i.party_id) s
    join public.parties p on p.id = s.pid
   where s.net >= p_per and p.is_active and (p_category is null or p.category_id = p_category)
   order by 6 desc, 3;
end $$;
revoke execute on function public.coupon_counts(uuid, date, date, numeric, uuid) from public, anon;
grant execute on function public.coupon_counts(uuid, date, date, numeric, uuid) to authenticated;
