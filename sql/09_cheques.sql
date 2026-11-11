-- =====================================================================
--  نظام السمو ERP — محفظة الشيكات
--  شيكات واردة (من العملاء) وصادرة (للموردين)، وكل حركة بتعمل قيد مرحّل تلقائياً
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

alter table public.company_settings add column if not exists cheques_in_account_id  uuid references public.accounts(id) on delete set null;  -- شيكات برسم التحصيل
alter table public.company_settings add column if not exists cheques_out_account_id uuid references public.accounts(id) on delete set null;  -- شيكات آجلة الدفع

create table if not exists public.cheques (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  direction     text not null check (direction in ('in','out')),
  cheque_no     text not null,
  bank_name     text,
  branch        text,
  issue_date    date not null default current_date,
  due_date      date not null,
  amount        numeric(18,3) not null check (amount > 0),
  party_id      uuid references public.parties(id) on delete restrict,
  account_id    uuid references public.accounts(id) on delete restrict,   -- الحساب المقابل إذا بدون عميل/مورد
  drawer_name   text,             -- اسم الساحب/المستفيد
  bank_account_id uuid references public.accounts(id) on delete set null,  -- البنك اللي انصرف/انحصّل عليه
  status        text not null default 'portfolio'
                check (status in ('portfolio','collected','returned','issued','paid','cancelled')),
  notes         text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now()
);
create index if not exists cheques_due_idx on public.cheques (company_id, status, due_date);

create table if not exists public.cheque_events (
  id         uuid primary key default gen_random_uuid(),
  cheque_id  uuid not null references public.cheques(id) on delete cascade,
  action     text not null,
  event_date date not null,
  entry_id   uuid references public.journal_entries(id) on delete set null,
  note       text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

-- الشيك ما بيتعدّل مبلغه أو طرفه بعد ما ينسجّل (حالته بتتغير بس من الدالة)
create or replace function public.cheques_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then return case when tg_op = 'DELETE' then old else new end; end if;
  if tg_op = 'INSERT' then raise exception 'الشيك بينسجّل من شاشة الشيكات'; end if;
  if tg_op = 'DELETE' then raise exception 'الشيك المسجّل ما بينحذف. ألغيه أو رجّعه'; end if;
  if new.amount <> old.amount or new.party_id is distinct from old.party_id or new.account_id is distinct from old.account_id
     or new.status <> old.status or new.direction <> old.direction or new.company_id <> old.company_id or new.bank_account_id is distinct from old.bank_account_id then
    raise exception 'ما بيصير تعديل المبلغ أو الطرف أو الحالة مباشرة';
  end if;
  return new;
end $$;
drop trigger if exists cheques_guard on public.cheques;
create trigger cheques_guard before insert or update or delete on public.cheques
  for each row execute function public.cheques_guard();

-- قيد داخلي من سطرين
create or replace function public.post_two_line(p_company uuid, p_date date, p_desc text, p_ref text,
  p_dr uuid, p_dr_party uuid, p_cr uuid, p_cr_party uuid, p_amount numeric) returns uuid
language plpgsql security definer set search_path = public as $$
declare fy public.fiscal_years; eid uuid;
begin
  select * into fy from public.fiscal_years where company_id = p_company and p_date between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy.id is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ %', p_date; end if;
  if p_dr is null or p_cr is null then raise exception 'حدّد حسابات الشيكات والبنك بشاشة «حسابات الربط»'; end if;
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (p_company, fy.id, 'cheque', p_date, p_desc, p_ref, 'draft') returning id into eid;
  insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
  values (eid, 1, p_dr, p_dr_party, p_desc, p_amount, 0), (eid, 2, p_cr, p_cr_party, p_desc, 0, p_amount);
  update public.journal_entries set status = 'posted', total = p_amount, posted_by = auth.uid(), posted_at = now() where id = eid;
  return eid;
end $$;
revoke execute on function public.post_two_line(uuid, date, text, text, uuid, uuid, uuid, uuid, numeric) from public, anon, authenticated;

-- تسجيل شيك جديد (وارد: من حـ/ شيكات برسم التحصيل إلى حـ/ العميل — صادر: من حـ/ المورد إلى حـ/ شيكات آجلة)
create or replace function public.register_cheque(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare st public.company_settings; cid uuid; pa public.parties; other uuid; ch uuid; eid uuid; dir text; amt numeric; d date; descr text;
begin
  cid := (p ->> 'company_id')::uuid; dir := p ->> 'direction'; amt := (p ->> 'amount')::numeric;
  d := coalesce((p ->> 'issue_date')::date, current_date);
  if not public.can(cid, 'cheques', 'add') then raise exception 'ما عندك صلاحية'; end if;
  if dir not in ('in','out') then raise exception 'نوع الشيك غلط'; end if;
  if amt is null or amt <= 0 then raise exception 'المبلغ لازم يكون أكبر من صفر'; end if;
  perform public.ensure_company_settings(cid);
  update public.company_settings s set
    cheques_in_account_id  = coalesce(s.cheques_in_account_id,  (select id from public.accounts where company_id = cid and code = '1104' and not is_group)),
    cheques_out_account_id = coalesce(s.cheques_out_account_id, (select id from public.accounts where company_id = cid and code = '2102' and not is_group))
  where s.company_id = cid;
  select * into st from public.company_settings where company_id = cid;
  if nullif(p ->> 'party_id', '') is not null then
    select * into pa from public.parties where id = (p ->> 'party_id')::uuid and company_id = cid;
    if pa.id is null then raise exception 'العميل/المورد مش لهالشركة'; end if;
    other := pa.account_id;
  else
    other := nullif(p ->> 'account_id', '')::uuid;
    if other is null or not exists (select 1 from public.accounts where id = other and company_id = cid and not is_group) then
      raise exception 'اختار العميل/المورد أو الحساب المقابل';
    end if;
  end if;
  descr := case dir when 'in' then 'شيك وارد رقم ' else 'شيك صادر رقم ' end || (p ->> 'cheque_no') || coalesce(' - ' || coalesce(pa.name, p ->> 'drawer_name'), '');

  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.cheques (company_id, direction, cheque_no, bank_name, branch, issue_date, due_date, amount, party_id, account_id, drawer_name, status, notes)
  values (cid, dir, p ->> 'cheque_no', p ->> 'bank_name', p ->> 'branch', d, (p ->> 'due_date')::date, amt, pa.id,
          case when pa.id is null then other end, coalesce(p ->> 'drawer_name', pa.name), case dir when 'in' then 'portfolio' else 'issued' end, p ->> 'notes')
  returning id into ch;
  if dir = 'in' then eid := public.post_two_line(cid, d, descr, p ->> 'cheque_no', st.cheques_in_account_id, null, other, pa.id, amt);
  else eid := public.post_two_line(cid, d, descr, p ->> 'cheque_no', other, pa.id, st.cheques_out_account_id, null, amt); end if;
  insert into public.cheque_events (cheque_id, action, event_date, entry_id) values (ch, case dir when 'in' then 'استلام' else 'إصدار' end, d, eid);
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details) values (auth.uid(), cid, 'إضافة', 'cheques', ch::text, jsonb_build_object('no', p ->> 'cheque_no', 'amount', amt));
  return ch;
end $$;

-- حركات الشيك: collect (تحصيل) / return (راجع) / pay (صرف من البنك) / cancel (إلغاء صادر)
create or replace function public.cheque_action(p_id uuid, p_action text, p_date date, p_bank uuid default null, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare c public.cheques; st public.company_settings; other uuid; eid uuid; descr text; newst text; pa public.parties;
begin
  select * into c from public.cheques where id = p_id for update;
  if c.id is null then raise exception 'الشيك غير موجود'; end if;
  if not public.can(c.company_id, 'cheques', 'post') then raise exception 'ما عندك صلاحية على حركات الشيكات'; end if;
  select * into st from public.company_settings where company_id = c.company_id;
  if c.party_id is not null then select * into pa from public.parties where id = c.party_id; other := pa.account_id; else other := c.account_id; end if;
  if p_bank is not null and not exists (select 1 from public.accounts where id = p_bank and company_id = c.company_id and not is_group) then raise exception 'حساب البنك غلط'; end if;
  descr := case p_action when 'collect' then 'تحصيل' when 'return' then 'إرجاع' when 'pay' then 'صرف' else 'إلغاء' end
           || ' شيك رقم ' || c.cheque_no || coalesce(' - ' || c.drawer_name, '');
  perform set_config('sumou.internal', public.internal_token(), true);
  if c.direction = 'in' and c.status = 'portfolio' and p_action = 'collect' then
    if p_bank is null then raise exception 'اختار البنك اللي انحصّل عليه الشيك'; end if;
    eid := public.post_two_line(c.company_id, p_date, descr, c.cheque_no, p_bank, null, st.cheques_in_account_id, null, c.amount); newst := 'collected';
  elsif c.direction = 'in' and c.status in ('portfolio','collected') and p_action = 'return' then
    -- الشيك الراجع: العميل بيرجع مديون. إذا كان محصّل، بنعكس من البنك
    eid := public.post_two_line(c.company_id, p_date, descr, c.cheque_no, other, c.party_id,
             case when c.status = 'collected' then coalesce(p_bank, c.bank_account_id) else st.cheques_in_account_id end, null, c.amount);
    newst := 'returned';
  elsif c.direction = 'out' and c.status = 'issued' and p_action = 'pay' then
    if p_bank is null then raise exception 'اختار البنك اللي انصرف منه الشيك'; end if;
    eid := public.post_two_line(c.company_id, p_date, descr, c.cheque_no, st.cheques_out_account_id, null, p_bank, null, c.amount); newst := 'paid';
  elsif c.direction = 'out' and c.status = 'issued' and p_action in ('cancel','return') then
    eid := public.post_two_line(c.company_id, p_date, descr, c.cheque_no, st.cheques_out_account_id, null, other, c.party_id, c.amount); newst := 'cancelled';
  else
    raise exception 'الحركة مش مسموحة لشيك حالته الحالية';
  end if;
  update public.cheques set status = newst, bank_account_id = coalesce(p_bank, bank_account_id) where id = p_id;
  insert into public.cheque_events (cheque_id, action, event_date, entry_id, note) values (p_id, descr, p_date, eid, p_note);
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details) values (auth.uid(), c.company_id, descr, 'cheques', p_id::text, jsonb_build_object('amount', c.amount));
end $$;

alter table public.cheques enable row level security;
alter table public.cheque_events enable row level security;
drop policy if exists ch_select on public.cheques;
create policy ch_select on public.cheques for select to authenticated using (public.can(company_id, 'cheques', 'view'));
drop policy if exists ch_update on public.cheques;
create policy ch_update on public.cheques for update to authenticated
  using (public.can(company_id, 'cheques', 'edit')) with check (public.can(company_id, 'cheques', 'edit'));
drop policy if exists che_select on public.cheque_events;
create policy che_select on public.cheque_events for select to authenticated
  using (exists (select 1 from public.cheques c where c.id = cheque_id and public.can(c.company_id, 'cheques', 'view')));

grant select, update on public.cheques to authenticated;
grant select on public.cheque_events to authenticated;
grant execute on function public.register_cheque(jsonb), public.cheque_action(uuid, text, date, uuid, text) to authenticated;

update public.user_groups set permissions = permissions || '{"cheques":{"view":true,"add":true,"edit":true,"print":true,"post":true}}'::jsonb
 where name = 'محاسب' and not (permissions ? 'cheques');
update public.user_groups set permissions = permissions || '{"cheques":{"view":true,"add":true}}'::jsonb
 where name = 'مدخل بيانات' and not (permissions ? 'cheques');
update public.user_groups set permissions = permissions || '{"cheques":{"view":true,"print":true}}'::jsonb
 where name = 'مشاهد' and not (permissions ? 'cheques');

-- انتهى ✅
