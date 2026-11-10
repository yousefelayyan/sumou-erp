-- =====================================================================
--  نظام السمو ERP — المرحلة 4: الزبائن والموردين
--  بطاقات العملاء والموردين، ربطهم بسطور القيود، كشف حساب الطرف، أعمار الذمم
--  لازم ملفات المراحل 1 و2 و3 يكونوا مشغّلين قبله. آمن للتشغيل أكثر من مرة.
-- =====================================================================

create table if not exists public.parties (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references public.companies(id) on delete cascade,
  party_type         text not null check (party_type in ('customer','supplier')),
  code               text not null,
  name               text not null,
  trade_name         text,
  tax_no             text,              -- الرقم الضريبي
  national_no        text,              -- الرقم الوطني (منشأة أو شخص)
  contact_person     text,
  phone              text,
  mobile             text,
  email              text,
  city               text,
  address            text,
  account_id         uuid not null references public.accounts(id) on delete restrict,  -- الحساب الإجمالي (ذمم مدينة / دائنة)
  credit_limit       numeric(18,3) not null default 0,   -- سقف الائتمان (0 = بدون سقف)
  payment_terms_days int not null default 0,             -- مدة السداد بالأيام
  is_active          boolean not null default true,
  notes              text,
  created_at         timestamptz not null default now(),
  unique (company_id, party_type, code)
);
create index if not exists parties_company_idx on public.parties (company_id, party_type, code);

alter table public.journal_lines add column if not exists party_id uuid references public.parties(id) on delete restrict;
create index if not exists jl_party_idx on public.journal_lines (party_id);

-- رقم تلقائي للعميل/المورد + التحقق من الحساب
create or replace function public.parties_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare a public.accounts; n int;
begin
  select * into a from public.accounts where id = new.account_id;
  if a.id is null or a.company_id <> new.company_id then raise exception 'الحساب مش لهالشركة'; end if;
  if a.is_group then raise exception 'حساب الطرف لازم يكون حساب فرعي'; end if;
  if tg_op = 'INSERT' and (new.code is null or new.code = '') then
    select coalesce(max(nullif(regexp_replace(code, '\D', '', 'g'), '')::int), 0) + 1 into n
      from public.parties where company_id = new.company_id and party_type = new.party_type;
    new.code := case new.party_type when 'customer' then 'C' else 'S' end || lpad(n::text, 4, '0');
  end if;
  if tg_op = 'UPDATE' then new.company_id := old.company_id; new.party_type := old.party_type; end if;
  return new;
end $$;
drop trigger if exists parties_before on public.parties;
create trigger parties_before before insert or update on public.parties
  for each row execute function public.parties_before();

-- سطر القيد مع طرف: لازم الطرف من نفس الشركة
create or replace function public.lines_party_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.parties; e public.journal_entries;
begin
  if new.party_id is null then return new; end if;
  select * into p from public.parties where id = new.party_id;
  select * into e from public.journal_entries where id = new.entry_id;
  if p.id is null or p.company_id <> e.company_id then raise exception 'العميل/المورد مش لهالشركة'; end if;
  return new;
end $$;
drop trigger if exists lines_party_check on public.journal_lines;
create trigger lines_party_check before insert or update on public.journal_lines
  for each row execute function public.lines_party_check();

-- أرصدة الأطراف (مرحّل فقط)
create or replace view public.party_balances with (security_invoker = true) as
select e.company_id, e.fiscal_year_id, l.party_id, sum(l.debit) as debit, sum(l.credit) as credit
from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
where e.status in ('posted','reversed') and l.party_id is not null
group by e.company_id, e.fiscal_year_id, l.party_id;

-- كشف حساب عميل/مورد
create or replace function public.rep_party_ledger(p_company uuid, p_fy uuid, p_party uuid, p_from date, p_to date)
returns table (entry_id uuid, entry_type text, entry_no int, entry_date date, description text, line_description text,
               reference text, debit numeric, credit numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  select e.id, e.entry_type, e.entry_no, e.entry_date, e.description, l.description, e.reference, l.debit, l.credit
  from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
  where l.party_id = p_party and e.company_id = p_company and e.fiscal_year_id = p_fy
    and e.status in ('posted','reversed') and e.entry_date between p_from and p_to
  order by e.entry_date, case e.entry_type when 'opening' then 0 else 1 end, e.created_at, l.line_no;
end $$;

create or replace function public.rep_party_balance_before(p_company uuid, p_fy uuid, p_party uuid, p_date date)
returns numeric
language plpgsql stable security definer set search_path = public as $$
declare r numeric;
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  select coalesce(sum(l.debit - l.credit), 0) into r
  from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
  where l.party_id = p_party and e.company_id = p_company and e.fiscal_year_id = p_fy
    and e.status in ('posted','reversed') and e.entry_date < p_date;
  return r;
end $$;

-- حركات كل الأطراف من نوع معيّن لغاية تاريخ (لحساب أعمار الذمم بالواجهة)
create or replace function public.rep_party_movements(p_company uuid, p_fy uuid, p_type text, p_to date)
returns table (party_id uuid, entry_date date, debit numeric, credit numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  select l.party_id, e.entry_date, sum(l.debit), sum(l.credit)
  from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
  join public.parties p on p.id = l.party_id
  where p.party_type = p_type and e.company_id = p_company and e.fiscal_year_id = p_fy
    and e.status in ('posted','reversed') and e.entry_date <= p_to
  group by l.party_id, e.entry_date
  order by l.party_id, e.entry_date;
end $$;

-- القيد العكسي لازم ينسخ الطرف كمان
create or replace function public.reverse_entry(p_id uuid, p_date date default current_date, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries; fy public.fiscal_years; new_id uuid; d numeric;
begin
  select * into e from public.journal_entries where id = p_id for update;
  if e.id is null then raise exception 'القيد غير موجود'; end if;
  if not public.can(e.company_id, public.entry_screen(e.entry_type), 'post') then raise exception 'ما عندك صلاحية'; end if;
  if e.status <> 'posted' then raise exception 'بس القيود المرحّلة بتنعكس'; end if;
  if e.entry_type = 'opening' then raise exception 'القيد الافتتاحي ما بينعكس. عدّل الأرصدة بقيد يومية'; end if;
  select * into fy from public.fiscal_years
   where company_id = e.company_id and p_date between start_date and end_date and not is_closed
   order by start_date desc limit 1;
  if fy.id is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ %', p_date; end if;

  perform set_config('sumou.internal', 'on', true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, party_name, cash_account_id, status, reversal_of)
  values (e.company_id, fy.id, e.entry_type, p_date,
          coalesce(p_note, 'قيد عكسي للقيد رقم ' || e.entry_no || coalesce(' - ' || e.description, '')),
          e.reference, e.party_name, e.cash_account_id, 'draft', e.id)
  returning id into new_id;
  insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
  select new_id, line_no, account_id, party_id, description, credit, debit from public.journal_lines where entry_id = p_id;
  select coalesce(sum(debit),0) into d from public.journal_lines where entry_id = new_id;
  update public.journal_entries set status = 'posted', total = d, posted_by = auth.uid(), posted_at = now() where id = new_id;
  update public.journal_entries set status = 'reversed', reversed_by = new_id where id = p_id;
  perform set_config('sumou.internal', '', true);

  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), e.company_id, 'قيد عكسي', public.entry_screen(e.entry_type), p_id::text, jsonb_build_object('no', e.entry_no, 'reversal', new_id));
  return new_id;
end $$;

-- الحماية
alter table public.parties enable row level security;
drop policy if exists parties_select on public.parties;
create policy parties_select on public.parties for select to authenticated
  using (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'view')
         or public.has_company(company_id));
drop policy if exists parties_insert on public.parties;
create policy parties_insert on public.parties for insert to authenticated
  with check (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'add'));
drop policy if exists parties_update on public.parties;
create policy parties_update on public.parties for update to authenticated
  using (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'edit'))
  with check (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'edit'));
drop policy if exists parties_delete on public.parties;
create policy parties_delete on public.parties for delete to authenticated
  using (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'delete'));

grant select, insert, update, delete on public.parties to authenticated;
grant select on public.party_balances to authenticated;
grant execute on function public.rep_party_ledger(uuid, uuid, uuid, date, date), public.rep_party_balance_before(uuid, uuid, uuid, date),
  public.rep_party_movements(uuid, uuid, text, date) to authenticated;

-- صلاحيات جاهزة
update public.user_groups set permissions = permissions
  || '{"customers":{"view":true,"add":true,"edit":true,"print":true},"suppliers":{"view":true,"add":true,"edit":true,"print":true}}'::jsonb
 where name in ('محاسب', 'مدخل بيانات') and not (permissions ? 'customers');
update public.user_groups set permissions = permissions
  || '{"customers":{"view":true,"print":true},"suppliers":{"view":true,"print":true}}'::jsonb
 where name = 'مشاهد' and not (permissions ? 'customers');

-- انتهى ✅
