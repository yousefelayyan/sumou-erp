-- =====================================================================
--  السمو ERP — المرحلة 44: إيداع الشيكات وبيان القيود
--  1) مرحلة «مودع» للشيك الوارد: من صندوق الشيكات لحساب «شيكات برسم التحصيل» عند البنك، ومنه التحصيل أو الإرجاع.
--  2) نصوص البيان لكل عملية (استلام، إصدار، إيداع، تحصيل وارد/صادر، إرجاع وارد/صادر) بكلمات مفتاحية:
--     [رقم الشيك] [الطرف] [البنك] [الاستحقاق] [المبلغ] [ملاحظات] — بـ company_settings.cheque_templates
-- =====================================================================
alter table public.cheques add column if not exists deposit_account_id uuid references public.accounts(id) on delete restrict;
alter table public.company_settings add column if not exists cheque_templates jsonb not null default '{}'::jsonb;
do $$
begin
  if exists (select 1 from pg_constraint where conname = 'cheques_status_check') then
    alter table public.cheques drop constraint cheques_status_check;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'cheques_status_chk2') then
    alter table public.cheques add constraint cheques_status_chk2 check (status in ('portfolio','deposited','collected','returned','issued','paid','cancelled'));
  end if;
end $$;

-- حماية: حساب الإيداع ما بيتغيّر إلا من الدالة
create or replace function public.ab_cheque_deposit_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then return new; end if;
  if new.deposit_account_id is distinct from old.deposit_account_id then raise exception 'حساب الإيداع بيتغيّر من حركات الشيك بس'; end if;
  return new;
end $$;
drop trigger if exists ab_cheque_deposit_guard on public.cheques;
create trigger ab_cheque_deposit_guard before update of deposit_account_id on public.cheques for each row execute function public.ab_cheque_deposit_guard();

create or replace function public.cheque_desc(p_company uuid, p_op text, p_no text, p_party text, p_bank text, p_due date, p_amount numeric, p_notes text, p_default text)
returns text language plpgsql stable security definer set search_path = public as $$
declare t text;
begin
  select nullif(trim(cheque_templates ->> p_op), '') into t from public.company_settings where company_id = p_company;
  if t is null then return p_default; end if;
  t := replace(t, '[رقم الشيك]', coalesce(p_no, ''));
  t := replace(t, '[الطرف]', coalesce(p_party, ''));
  t := replace(t, '[البنك]', coalesce(p_bank, ''));
  t := replace(t, '[الاستحقاق]', coalesce(to_char(p_due, 'DD/MM/YYYY'), ''));
  t := replace(t, '[المبلغ]', coalesce(to_char(p_amount, 'FM999,999,999,990.000'), ''));
  t := replace(t, '[ملاحظات]', coalesce(p_notes, ''));
  return left(t, 500);
end $$;
revoke execute on function public.cheque_desc(uuid, text, text, text, text, date, numeric, text, text) from public, anon, authenticated;

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
  descr := public.cheque_desc(cid, case dir when 'in' then 'receive' else 'issue' end, p ->> 'cheque_no', coalesce(pa.name, p ->> 'drawer_name'), p ->> 'bank_name', (p ->> 'due_date')::date, amt, p ->> 'notes', descr);

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

create or replace function public.cheque_action(p_id uuid, p_action text, p_date date, p_bank uuid default null, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare c public.cheques; st public.company_settings; other uuid; eid uuid; descr text; newst text; pa public.parties; op text; dep uuid;
begin
  select * into c from public.cheques where id = p_id for update;
  if c.id is null then raise exception 'الشيك غير موجود'; end if;
  if not public.can(c.company_id, 'cheques', 'post') then raise exception 'ما عندك صلاحية على حركات الشيكات'; end if;
  select * into st from public.company_settings where company_id = c.company_id;
  if c.party_id is not null then select * into pa from public.parties where id = c.party_id; other := pa.account_id; else other := c.account_id; end if;
  if p_bank is not null and not exists (select 1 from public.accounts where id = p_bank and company_id = c.company_id and not is_group) then raise exception 'حساب البنك غلط'; end if;
  op := case when p_action = 'deposit' then 'deposit' when p_action = 'undeposit' then 'undeposit'
             when p_action = 'collect' then 'collect_in' when p_action = 'pay' then 'collect_out'
             when p_action = 'return' and c.direction = 'in' then 'return_in' when p_action in ('return','cancel') then 'return_out' else 'other' end;
  descr := case p_action when 'collect' then 'تحصيل' when 'return' then 'إرجاع' when 'pay' then 'صرف' when 'deposit' then 'إيداع' when 'undeposit' then 'سحب من الإيداع' else 'إلغاء' end
           || ' شيك رقم ' || c.cheque_no || coalesce(' - ' || c.drawer_name, '');
  descr := public.cheque_desc(c.company_id, op, c.cheque_no, coalesce(pa.name, c.drawer_name), c.bank_name, c.due_date, c.amount, c.notes, descr);
  dep := c.deposit_account_id;
  perform set_config('sumou.internal', public.internal_token(), true);
  if c.direction = 'in' and c.status = 'portfolio' and p_action = 'deposit' then
    -- إيداع بالبنك: من حـ/ شيكات برسم التحصيل لدى البنك إلى حـ/ صندوق الشيكات
    if p_bank is null then raise exception 'اختار حساب «شيكات برسم التحصيل» عند البنك'; end if;
    if p_bank = st.cheques_in_account_id then raise exception 'حساب الإيداع لازم يكون غير حساب صندوق الشيكات'; end if;
    eid := public.post_two_line(c.company_id, p_date, descr, c.cheque_no, p_bank, null, st.cheques_in_account_id, null, c.amount);
    newst := 'deposited'; dep := p_bank;
  elsif c.direction = 'in' and c.status = 'deposited' and p_action = 'undeposit' then
    eid := public.post_two_line(c.company_id, p_date, descr, c.cheque_no, st.cheques_in_account_id, null, c.deposit_account_id, null, c.amount);
    newst := 'portfolio'; dep := null;
  elsif c.direction = 'in' and c.status in ('portfolio','deposited') and p_action = 'collect' then
    if p_bank is null then raise exception 'اختار البنك اللي انحصّل عليه الشيك'; end if;
    eid := public.post_two_line(c.company_id, p_date, descr, c.cheque_no, p_bank, null,
             case when c.status = 'deposited' then c.deposit_account_id else st.cheques_in_account_id end, null, c.amount);
    newst := 'collected';
  elsif c.direction = 'in' and c.status in ('portfolio','deposited','collected') and p_action = 'return' then
    -- الشيك الراجع: العميل بيرجع مديون، من الحساب اللي الشيك فيه هسا
    eid := public.post_two_line(c.company_id, p_date, descr, c.cheque_no, other, c.party_id,
             case c.status when 'collected' then coalesce(p_bank, c.bank_account_id) when 'deposited' then c.deposit_account_id else st.cheques_in_account_id end, null, c.amount);
    newst := 'returned';
  elsif c.direction = 'out' and c.status = 'issued' and p_action = 'pay' then
    if p_bank is null then raise exception 'اختار البنك اللي انصرف منه الشيك'; end if;
    eid := public.post_two_line(c.company_id, p_date, descr, c.cheque_no, st.cheques_out_account_id, null, p_bank, null, c.amount); newst := 'paid';
  elsif c.direction = 'out' and c.status = 'issued' and p_action in ('cancel','return') then
    eid := public.post_two_line(c.company_id, p_date, descr, c.cheque_no, st.cheques_out_account_id, null, other, c.party_id, c.amount); newst := 'cancelled';
  else
    raise exception 'الحركة مش مسموحة لشيك حالته الحالية';
  end if;
  update public.cheques set status = newst, deposit_account_id = dep,
         bank_account_id = case when p_action in ('collect','pay') then p_bank else bank_account_id end where id = p_id;
  insert into public.cheque_events (cheque_id, action, event_date, entry_id, note) values (p_id, descr, p_date, eid, p_note);
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details) values (auth.uid(), c.company_id, descr, 'cheques', p_id::text, jsonb_build_object('amount', c.amount));
end $$;

grant execute on function public.register_cheque(jsonb), public.cheque_action(uuid, text, date, uuid, text) to authenticated;
