-- =====================================================================
--  نظام السمو ERP — إغلاق السنة المالية وتدوير الأرصدة
--  قيد إقفال الإيرادات والمصاريف للأرباح المدورة + قيد افتتاحي تلقائي للسنة الجديدة
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

alter table public.journal_entries drop constraint if exists journal_entries_entry_type_check;
alter table public.journal_entries add constraint journal_entries_entry_type_check
  check (entry_type in ('journal','receipt','payment','opening','invoice','closing','cheque','stock'));

create or replace function public.entry_screen(t text) returns text
language sql immutable as $$
  select case t when 'journal' then 'journal_entries' when 'receipt' then 'receipt_vouchers'
                when 'payment' then 'payment_vouchers' when 'opening' then 'opening_balances'
                when 'invoice' then 'journal_entries' when 'closing' then 'journal_entries' when 'cheque' then 'journal_entries' when 'stock' then 'journal_entries' end;
$$;

-- منع إنشاء قيد إقفال من برّا (بس من دالة الإغلاق)
create or replace function public.entries_type_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.entry_type = 'closing' and not public.is_internal() then raise exception 'قيد الإقفال بينعمل من زر «إغلاق السنة» بس'; end if;
  if new.entry_type = 'stock' and not public.is_internal() then raise exception 'قيد المخزون بينعمل من سند المخزون بس'; end if;
  return new;
end $$;
drop trigger if exists entries_type_guard on public.journal_entries;
create trigger entries_type_guard before insert or update on public.journal_entries
  for each row execute function public.entries_type_guard();

-- ---------------------------------------------------------------------
--  إغلاق السنة
-- ---------------------------------------------------------------------
create or replace function public.close_fiscal_year(p_fy uuid, p_next_fy uuid, p_retained uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare fy public.fiscal_years; nfy public.fiscal_years; ra public.accounts; drafts int; cid uuid; nid uuid; oid uuid;
  ln int := 0; net numeric := 0; r record; old_open public.journal_entries; d numeric;
begin
  if not public.is_admin() then raise exception 'إغلاق السنة لمدير النظام بس'; end if;
  select * into fy from public.fiscal_years where id = p_fy;
  select * into nfy from public.fiscal_years where id = p_next_fy;
  if fy.id is null or nfy.id is null or nfy.company_id <> fy.company_id then raise exception 'اختار السنة الجديدة لنفس الشركة'; end if;
  if fy.is_closed then raise exception 'السنة مغلقة من قبل'; end if;
  if nfy.is_closed then raise exception 'السنة الجديدة مغلقة'; end if;
  if nfy.start_date <= fy.end_date then raise exception 'السنة الجديدة لازم تبلّش بعد نهاية السنة اللي بتنغلق'; end if;
  select * into ra from public.accounts where id = p_retained;
  if ra.id is null or ra.company_id <> fy.company_id or ra.is_group or ra.category <> 'equity' then
    raise exception 'حساب الأرباح المدورة لازم يكون حساب فرعي من حقوق الملكية';
  end if;
  select count(*) into drafts from public.journal_entries where fiscal_year_id = p_fy and status = 'draft';
  if drafts > 0 then raise exception 'في % قيد/سند مسودة بهالسنة. رحّلهم أو احذفهم قبل الإغلاق', drafts; end if;
  if to_regclass('public.invoices') is not null then
    select count(*) into drafts from public.invoices where fiscal_year_id = p_fy and status = 'draft';
    if drafts > 0 then raise exception 'في % فاتورة مسودة بهالسنة. رحّلها أو احذفها قبل الإغلاق', drafts; end if;
  end if;

  -- القيد الافتتاحي بالسنة الجديدة: إذا انعمل تلقائياً من قبل بنستبدله، وإذا يدوي ومرحّل بنوقف
  select * into old_open from public.journal_entries where fiscal_year_id = p_next_fy and entry_type = 'opening' and status <> 'reversed' order by created_at desc limit 1;
  if old_open.id is not null and old_open.status = 'posted' and coalesce(old_open.reference, '') <> 'AUTO-CLOSE' then
    raise exception 'السنة الجديدة إلها أرصدة افتتاحية مرحّلة (مدخلة يدوياً). احذفها أو اعكسها قبل التدوير';
  end if;

  perform set_config('sumou.internal', public.internal_token(), true);
  if old_open.id is not null then delete from public.journal_entries where id = old_open.id; end if;

  -- 1) قيد الإقفال: تصفير الإيرادات والمصاريف على الأرباح المدورة
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (fy.company_id, p_fy, 'closing', fy.end_date, 'قيد إقفال ' || coalesce(fy.name, fy.code), 'AUTO-CLOSE', 'draft')
  returning id into cid;
  for r in
    select l.account_id, l.party_id, sum(l.debit - l.credit) as bal
    from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
    where e.fiscal_year_id = p_fy and e.status in ('posted','reversed') and e.id <> cid and a.category in ('revenue','expenses')
    group by l.account_id, l.party_id having abs(sum(l.debit - l.credit)) > 0.0005
  loop
    ln := ln + 1; net := net + r.bal;
    insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
    values (cid, ln, r.account_id, r.party_id, 'إقفال', case when r.bal < 0 then -r.bal else 0 end, case when r.bal > 0 then r.bal else 0 end);
  end loop;
  if ln > 0 and abs(net) > 0.0005 then
    ln := ln + 1;   -- net موجب = مصاريف أكثر = خسارة
    insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit)
    values (cid, ln, p_retained, case when net > 0 then 'خسارة السنة' else 'ربح السنة' end,
            case when net > 0 then net else 0 end, case when net < 0 then -net else 0 end);
  end if;
  if ln = 0 then delete from public.journal_entries where id = cid; cid := null;
  else
    select coalesce(sum(debit), 0) into d from public.journal_lines where entry_id = cid;
    update public.journal_entries set status = 'posted', total = d, posted_by = auth.uid(), posted_at = now() where id = cid;
  end if;

  -- 2) القيد الافتتاحي للسنة الجديدة: أرصدة الموجودات والمطلوبات وحقوق الملكية (مع العملاء والموردين)
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (fy.company_id, p_next_fy, 'opening', nfy.start_date, 'أرصدة مدوّرة من ' || coalesce(fy.name, fy.code), 'AUTO-CLOSE', 'draft')
  returning id into oid;
  ln := 0;
  for r in
    select l.account_id, l.party_id, sum(l.debit - l.credit) as bal
    from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
    where e.fiscal_year_id = p_fy and e.status in ('posted','reversed') and a.category in ('assets','liabilities','equity')
    group by l.account_id, l.party_id having abs(sum(l.debit - l.credit)) > 0.0005
    order by 1
  loop
    ln := ln + 1;
    insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
    values (oid, ln, r.account_id, r.party_id, 'رصيد مدوّر', case when r.bal > 0 then r.bal else 0 end, case when r.bal < 0 then -r.bal else 0 end);
  end loop;
  if ln = 0 then delete from public.journal_entries where id = oid; oid := null;
  else
    select coalesce(sum(debit), 0) into d from public.journal_lines where entry_id = oid;
    if abs(d - (select coalesce(sum(credit), 0) from public.journal_lines where entry_id = oid)) > 0.0005 then
      raise exception 'الأرصدة المدوّرة مش متوازنة. راجع ميزان المراجعة للسنة';
    end if;
    update public.journal_entries set status = 'posted', total = d, posted_by = auth.uid(), posted_at = now() where id = oid;
  end if;

  update public.fiscal_years set is_closed = true where id = p_fy;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), fy.company_id, 'إغلاق السنة', 'fiscal_years', p_fy::text, jsonb_build_object('next', p_next_fy, 'net', -net));
  return jsonb_build_object('closing_entry', cid, 'opening_entry', oid, 'profit', -net);
end $$;

-- إعادة فتح سنة: بيحذف قيد الإقفال والأرصدة المدوّرة التلقائية بالسنة اللي بعدها
create or replace function public.reopen_fiscal_year(p_fy uuid) returns void
language plpgsql security definer set search_path = public as $$
declare fy public.fiscal_years;
begin
  if not public.is_admin() then raise exception 'إعادة فتح السنة لمدير النظام بس'; end if;
  select * into fy from public.fiscal_years where id = p_fy;
  if fy.id is null then raise exception 'السنة غير موجودة'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  delete from public.journal_entries where fiscal_year_id = p_fy and entry_type = 'closing';
  delete from public.journal_entries e using public.fiscal_years n
   where e.fiscal_year_id = n.id and n.company_id = fy.company_id and n.start_date > fy.end_date
     and e.entry_type = 'opening' and e.reference = 'AUTO-CLOSE' and e.description = 'أرصدة مدوّرة من ' || coalesce(fy.name, fy.code);
  update public.fiscal_years set is_closed = false where id = p_fy;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id)
  values (auth.uid(), fy.company_id, 'إعادة فتح السنة', 'fiscal_years', p_fy::text);
end $$;

grant execute on function public.close_fiscal_year(uuid, uuid, uuid), public.reopen_fiscal_year(uuid) to authenticated;

-- انتهى ✅
