-- =====================================================================
--  المرحلة 80: قفل الفترة لكل قسم
--  fiscal_periods.locked_sections = الأقسام المقفولة بالفترة:
--    sales (فواتير ومردودات البيع ونقطة البيع)، purchases (فواتير ومردودات الشراء)،
--    receipts (سندات القبض)، payments (سندات الصرف)، journal (سندات القيد والأرصدة الافتتاحية)،
--    cheques (قيود الشيكات)، payroll (مسيّرات الرواتب)، assets (قيود الاستهلاك والأصول)،
--    stock_docs (سندات المخزون)، orders (طلبات المبيعات والتزويد)
--  القسم المقفول: ما بينضاف ولا بينعدّل ولا بينحذف ولا بينرحّل/بينلغى ترحيل مستند تاريخه بالفترة.
--  التجميد والمتابعة والقيد العكسي بتاريخ مفتوح بيضلوا مسموحين.
--  القفل بصلاحية تعديل السنوات المالية، والفتح بـ «إلغاء ترحيل» أو المدير (زي قفل المالية والمخزون).
-- =====================================================================

alter table public.fiscal_periods add column if not exists locked_sections text[] not null default '{}';
alter table public.fiscal_periods drop constraint if exists fiscal_periods_sections_chk;
alter table public.fiscal_periods add constraint fiscal_periods_sections_chk check (
  locked_sections <@ array['sales','purchases','receipts','payments','journal','cheques','payroll','assets','stock_docs','orders']::text[]);

create or replace function public.fiscal_periods_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then return new; end if;
  if tg_op = 'INSERT' then raise exception 'الفترات بتتولّد لحالها مع السنة المالية'; end if;
  new.company_id := old.company_id; new.fiscal_year_id := old.fiscal_year_id; new.code := old.code;
  new.start_date := old.start_date; new.end_date := old.end_date;
  new.locked_sections := coalesce((select array_agg(distinct s order by s) from unnest(new.locked_sections) s where s is not null), '{}');
  if (old.gl_locked and not new.gl_locked) or (old.stock_locked and not new.stock_locked)
     or not (old.locked_sections <@ new.locked_sections) then
    if not (public.is_admin() or public.can(old.company_id, 'fiscal_years', 'unpost')) then
      raise exception 'فتح الفترة المقفولة بدها صلاحية «إلغاء ترحيل» على السنوات المالية';
    end if;
  end if;
  if (new.gl_locked, new.stock_locked, new.locked_sections) is distinct from (old.gl_locked, old.stock_locked, old.locked_sections) then
    new.locked_by := auth.uid(); new.locked_at := now();
  else new.locked_by := old.locked_by; new.locked_at := old.locked_at; end if;
  return new;
end $$;

-- 'gl' / 'stock' زي قبل، وأي اسم ثاني = قسم
create or replace function public.period_locked_(p_company uuid, p_date date, p_kind text) returns text
language sql stable security definer set search_path = public as $$
  select code from public.fiscal_periods
   where company_id = p_company and p_date between start_date and end_date
     and case when p_kind = 'gl' then gl_locked when p_kind = 'stock' then stock_locked else p_kind = any(locked_sections) end
   limit 1
$$;
revoke execute on function public.period_locked_(uuid, date, text) from public, anon, authenticated;

create or replace function public.section_label(p text) returns text language sql immutable as $$
  select case p when 'sales' then 'المبيعات' when 'purchases' then 'المشتريات' when 'receipts' then 'سندات القبض'
    when 'payments' then 'سندات الصرف' when 'journal' then 'سندات القيد' when 'cheques' then 'الشيكات'
    when 'payroll' then 'الرواتب' when 'assets' then 'الأصول الثابتة' when 'stock_docs' then 'سندات المخزون'
    when 'orders' then 'الطلبات' else p end
$$;

-- القسم حسب الجدول والسطر
create or replace function public.doc_section(p_table text, r jsonb) returns text language sql immutable as $$
  select case p_table
    when 'invoices' then case when r ->> 'inv_type' in ('sale','sale_return') then 'sales' else 'purchases' end
    when 'journal_entries' then case r ->> 'entry_type' when 'journal' then 'journal' when 'opening' then 'journal'
      when 'receipt' then 'receipts' when 'payment' then 'payments' when 'cheque' then 'cheques'
      when 'payroll' then 'payroll' when 'depreciation' then 'assets' end
    when 'stock_docs' then 'stock_docs'
    when 'orders' then 'orders'
    when 'payroll_runs' then 'payroll' end
$$;
create or replace function public.doc_section_date(p_table text, r jsonb) returns date language sql immutable as $$
  select (case p_table when 'invoices' then r ->> 'inv_date' when 'journal_entries' then r ->> 'entry_date'
    when 'stock_docs' then r ->> 'doc_date' when 'orders' then r ->> 'order_date' when 'payroll_runs' then r ->> 'run_date' end)::date
$$;

create or replace function public.section_lock_check(p_table text, r jsonb) returns void
language plpgsql stable security definer set search_path = public as $$
declare s text := public.doc_section(p_table, r); d date := public.doc_section_date(p_table, r); p text;
begin
  if s is null or d is null then return; end if;
  if not exists (select 1 from public.fiscal_periods where company_id = (r ->> 'company_id')::uuid and locked_sections <> '{}') then return; end if;
  p := public.period_locked_((r ->> 'company_id')::uuid, d, s);
  if p is not null then raise exception 'الفترة % مقفولة لقسم «%»، ما بينضاف أو بينعدّل فيها شي', p, public.section_label(s); end if;
end $$;
revoke execute on function public.section_lock_check(text, jsonb) from public, anon, authenticated;

-- رأس المستند
create or replace function public.ae_section_lock() returns trigger
language plpgsql security definer set search_path = public as $$
declare o jsonb; n jsonb; ign text[] := array['is_frozen','updated_by','updated_at','created_by','created_at','seq_key','doc_code','doc_type_id','posting_ready'];
begin
  if tg_op = 'DELETE' then
    if exists (select 1 from public.companies where id = old.company_id) then perform public.section_lock_check(tg_table_name, to_jsonb(old)); end if;
    return old;
  end if;
  n := to_jsonb(new);
  if tg_op = 'INSERT' then perform public.section_lock_check(tg_table_name, n); return new; end if;
  o := to_jsonb(old);
  if tg_table_name = 'journal_entries' then ign := ign || array['reversal_of','reversed_by'];
  elsif tg_table_name = 'invoices' then ign := ign || array['original_invoice_id'];
  elsif tg_table_name = 'orders' then ign := ign || array['invoice_id','status','delivered','delivered_date','closed'];
  end if;
  -- العكس/الإلغاء بقيد بتاريخ مفتوح مسموح (القيد الجديد بيتفحص لحاله)
  if (o ->> 'status') = 'posted' and (n ->> 'status') in ('reversed', 'cancelled') then
    ign := ign || array['status','cancel_entry_id','reversed_by'];
  end if;
  if (o - ign) = (n - ign) then return new; end if;
  perform public.section_lock_check(tg_table_name, o);
  perform public.section_lock_check(tg_table_name, n);
  return new;
end $$;

-- السطور: بتتفحص على رأسها
create or replace function public.ae_section_lock_line() returns trigger
language plpgsql security definer set search_path = public as $$
declare pt text; pid uuid; h jsonb;
begin
  pt := case tg_table_name when 'invoice_lines' then 'invoices' when 'journal_lines' then 'journal_entries'
    when 'stock_doc_lines' then 'stock_docs' when 'order_lines' then 'orders' when 'payroll_lines' then 'payroll_runs' end;
  for pid in select distinct x from unnest(array[
      case when tg_op <> 'INSERT' then (to_jsonb(old) ->> case pt when 'invoices' then 'invoice_id' when 'journal_entries' then 'entry_id' when 'stock_docs' then 'doc_id' when 'orders' then 'order_id' else 'run_id' end)::uuid end,
      case when tg_op <> 'DELETE' then (to_jsonb(new) ->> case pt when 'invoices' then 'invoice_id' when 'journal_entries' then 'entry_id' when 'stock_docs' then 'doc_id' when 'orders' then 'order_id' else 'run_id' end)::uuid end]) x where x is not null loop
    execute format('select to_jsonb(t) from public.%I t where id = $1', pt) into h using pid;
    if h is not null then perform public.section_lock_check(pt, h); end if;
  end loop;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

do $$ declare t text; begin
  foreach t in array array['invoices','journal_entries','stock_docs','orders','payroll_runs'] loop
    execute format('drop trigger if exists ae_section_lock on public.%I', t);
    execute format('create trigger ae_section_lock before insert or update or delete on public.%I for each row execute function public.ae_section_lock()', t);
  end loop;
  foreach t in array array['invoice_lines','journal_lines','stock_doc_lines','order_lines','payroll_lines'] loop
    execute format('drop trigger if exists ae_section_lock on public.%I', t);
    execute format('create trigger ae_section_lock before insert or update or delete on public.%I for each row execute function public.ae_section_lock_line()', t);
  end loop;
end $$;
