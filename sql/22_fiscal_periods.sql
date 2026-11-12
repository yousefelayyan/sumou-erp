-- =====================================================================
--  السمو ERP — المرحلة 22: فترات السنة المالية (12 شهر لكل سنة)
--  كل فترة بتنقفل للمالية أو للمخزون أو الاثنين: ما بينرحّل عليها ولا بينلغى ترحيل.
--  القفل بصلاحية «تعديل» على السنوات المالية، والفتح من جديد بصلاحية «إلغاء ترحيل» (أو المدير).
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

create table if not exists public.fiscal_periods (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies(id) on delete cascade,
  fiscal_year_id uuid not null references public.fiscal_years(id) on delete cascade,
  code           text not null,          -- 01.26
  name           text,
  start_date     date not null,
  end_date       date not null,
  gl_locked      boolean not null default false,   -- مقفولة للمالية
  stock_locked   boolean not null default false,   -- مقفولة للمخزون
  locked_by      uuid,
  locked_at      timestamptz,
  created_at     timestamptz default now(),
  unique (fiscal_year_id, code),
  check (end_date >= start_date)
);
create index if not exists fiscal_periods_lookup on public.fiscal_periods (company_id, start_date, end_date);

-- توليد الفترات الشهرية لسنة (ما بيكرر الموجود)
create or replace function public.ensure_fiscal_periods(p_fy uuid) returns int
language plpgsql security definer set search_path = public as $$
declare fy public.fiscal_years; d date; e date; n int := 0; prev text := current_setting('sumou.internal', true);
begin
  select * into fy from public.fiscal_years where id = p_fy;
  if fy.id is null then return 0; end if;
  if not public.is_internal() and not public.has_company(fy.company_id) then raise exception 'ما إلك صلاحية على هالشركة'; end if;
  if exists (select 1 from public.fiscal_periods where fiscal_year_id = p_fy) then return 0; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  d := fy.start_date;
  while d <= fy.end_date loop
    e := least((date_trunc('month', d) + interval '1 month - 1 day')::date, fy.end_date);
    insert into public.fiscal_periods (company_id, fiscal_year_id, code, name, start_date, end_date)
    values (fy.company_id, fy.id, to_char(d, 'MM.YY'), to_char(d, 'MM.YY'), d, e)
    on conflict do nothing;
    n := n + 1; d := e + 1;
  end loop;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  return n;
end $$;
grant execute on function public.ensure_fiscal_periods(uuid) to authenticated;

-- سنة جديدة = فترات جديدة (الاسترجاع بيرجّع فتراته من النسخة)
create or replace function public.fiscal_years_periods() returns trigger
language plpgsql security definer set search_path = public as $$
declare prev text := current_setting('sumou.internal', true);
begin
  if public.is_internal() then return null; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  perform public.ensure_fiscal_periods(new.id);
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  return null;
end $$;
drop trigger if exists fiscal_years_periods on public.fiscal_years;
create trigger fiscal_years_periods after insert on public.fiscal_years
  for each row execute function public.fiscal_years_periods();

-- السنوات الموجودة
do $$ declare r record; begin
  perform set_config('sumou.internal', public.internal_token(), true);
  for r in select id from public.fiscal_years loop perform public.ensure_fiscal_periods(r.id); end loop;
  perform set_config('sumou.internal', '', true);
end $$;

-- التعديل: بس القفل والاسم. القفل بصلاحية تعديل، والفتح بصلاحية إلغاء الترحيل
create or replace function public.fiscal_periods_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then return new; end if;
  if tg_op = 'INSERT' then raise exception 'الفترات بتتولّد لحالها مع السنة المالية'; end if;
  new.company_id := old.company_id; new.fiscal_year_id := old.fiscal_year_id; new.code := old.code;
  new.start_date := old.start_date; new.end_date := old.end_date;
  if (old.gl_locked and not new.gl_locked) or (old.stock_locked and not new.stock_locked) then
    if not (public.is_admin() or public.can(old.company_id, 'fiscal_years', 'unpost')) then
      raise exception 'فتح الفترة المقفولة بدها صلاحية «إلغاء ترحيل» على السنوات المالية';
    end if;
  end if;
  if (new.gl_locked, new.stock_locked) is distinct from (old.gl_locked, old.stock_locked) then
    new.locked_by := auth.uid(); new.locked_at := now();
  else new.locked_by := old.locked_by; new.locked_at := old.locked_at; end if;
  return new;
end $$;
drop trigger if exists fiscal_periods_before on public.fiscal_periods;
create trigger fiscal_periods_before before insert or update on public.fiscal_periods
  for each row execute function public.fiscal_periods_before();

alter table public.fiscal_periods enable row level security;
drop policy if exists fp_select on public.fiscal_periods;
create policy fp_select on public.fiscal_periods for select to authenticated using (public.has_company(company_id));
drop policy if exists fp_update on public.fiscal_periods;
create policy fp_update on public.fiscal_periods for update to authenticated
  using (public.can(company_id, 'fiscal_years', 'edit')) with check (public.can(company_id, 'fiscal_years', 'edit'));
grant select, update on public.fiscal_periods to authenticated;

-- هل التاريخ بفترة مقفولة؟ kind = 'gl' أو 'stock'
create or replace function public.period_locked_(p_company uuid, p_date date, p_kind text) returns text
language sql stable security definer set search_path = public as $$
  select code from public.fiscal_periods
   where company_id = p_company and p_date between start_date and end_date
     and case when p_kind = 'gl' then gl_locked else stock_locked end
   limit 1
$$;
revoke execute on function public.period_locked_(uuid, date, text) from public, anon, authenticated;
create or replace function public.period_locked(p_company uuid, p_date date, p_kind text) returns text
language sql stable security definer set search_path = public as $$
  select case when public.has_company(p_company) then public.period_locked_(p_company, p_date, p_kind) end
$$;
grant execute on function public.period_locked(uuid, date, text) to authenticated;

-- المالية: ترحيل قيد أو إلغاء ترحيله أو حذفه بفترة مقفولة ممنوع (قيد الإقفال من النظام مستثنى)
create or replace function public.ae_entry_period_lock() returns trigger
language plpgsql security definer set search_path = public as $$
declare p text;
begin
  if tg_op = 'DELETE' then
    if old.status = 'posted' and old.entry_type <> 'closing' and exists (select 1 from public.companies where id = old.company_id) then
      p := public.period_locked_(old.company_id, old.entry_date, 'gl');
      if p is not null then raise exception 'الفترة % مقفولة للمالية، ما بينلغى الترحيل فيها', p; end if;
    end if;
    return old;
  end if;
  if new.entry_type = 'closing' then return new; end if;
  if (tg_op = 'INSERT' and new.status = 'posted')
     or (tg_op = 'UPDATE' and new.status = 'posted' and old.status = 'draft') then
    p := public.period_locked_(new.company_id, new.entry_date, 'gl');
    if p is not null then raise exception 'الفترة % مقفولة للمالية، ما بينرحّل عليها', p; end if;
  elsif tg_op = 'UPDATE' and old.status = 'posted' and new.status = 'draft' then
    p := public.period_locked_(old.company_id, old.entry_date, 'gl');
    if p is not null then raise exception 'الفترة % مقفولة للمالية، ما بينلغى الترحيل فيها', p; end if;
  end if;
  return new;
end $$;
drop trigger if exists ae_entry_period_lock on public.journal_entries;
create trigger ae_entry_period_lock before insert or update of status or delete on public.journal_entries
  for each row execute function public.ae_entry_period_lock();

-- المخزون: حركة جديدة أو حذف حركة بفترة مقفولة ممنوع
create or replace function public.ae_stock_period_lock() returns trigger
language plpgsql security definer set search_path = public as $$
declare p text; r public.stock_moves;
begin
  r := case when tg_op = 'DELETE' then old else new end;
  if tg_op = 'UPDATE' and (new.qty, new.unit_cost, new.move_date, new.item_id, new.warehouse_id, new.company_id)
                       is not distinct from (old.qty, old.unit_cost, old.move_date, old.item_id, old.warehouse_id, old.company_id) then
    return new;   -- تعديل ما بيغيّر الحركة (مثل تعبئة أعمدة)
  end if;
  if tg_op = 'DELETE' and not exists (select 1 from public.companies where id = r.company_id) then return old; end if;  -- حذف الشركة كاملة
  p := public.period_locked_(r.company_id, r.move_date, 'stock');
  if p is not null then raise exception 'الفترة % مقفولة للمخزون', p; end if;
  if tg_op = 'UPDATE' and old.move_date <> new.move_date then
    p := public.period_locked_(old.company_id, old.move_date, 'stock');
    if p is not null then raise exception 'الفترة % مقفولة للمخزون', p; end if;
  end if;
  return r;
end $$;
drop trigger if exists ae_stock_period_lock on public.stock_moves;
create trigger ae_stock_period_lock before insert or update or delete on public.stock_moves
  for each row execute function public.ae_stock_period_lock();

-- النسخ الاحتياطي: الفترات آخر شي (بعد المستندات، عشان القفل ما يمنع الاسترجاع)
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1,  'companies',          'id = $1', 'code'),
   (2,  'fiscal_years',       'company_id = $1', 'start_date'),
   (3,  'accounts',           'company_id = $1', 'level, code'),
   (4,  'cost_centers',       'company_id = $1', 'code'),
   (5,  'currencies',         'company_id = $1', 'code'),
   (6,  'company_settings',   'company_id = $1', 'company_id'),
   (7,  'party_categories',   'company_id = $1', 'party_type, code'),
   (8,  'parties',            'company_id = $1', 'code'),
   (9,  'item_categories',    'company_id = $1', 'code'),
   (10, 'items',              'company_id = $1', 'code'),
   (11, 'warehouses',         'company_id = $1', 'code'),
   (12, 'departments',        'company_id = $1', 'level, code'),
   (13, 'journal_entries',    'company_id = $1', 'created_at'),
   (14, 'journal_lines',      'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (15, 'invoices',           'company_id = $1', 'created_at'),
   (16, 'invoice_lines',      'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (17, 'cheques',            'company_id = $1', 'created_at'),
   (18, 'cheque_events',      'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (19, 'stock_docs',         'company_id = $1', 'created_at'),
   (20, 'stock_doc_lines',    'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (21, 'stock_moves',        'company_id = $1', 'created_at'),
   (22, 'obligations',        'company_id = $1', 'due_date'),
   (23, 'recurring_entries',  'company_id = $1', 'created_at'),
   (24, 'employees',          'company_id = $1', 'code'),
   (25, 'payroll_runs',       'company_id = $1', 'period'),
   (26, 'payroll_lines',      'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (27, 'fixed_assets',       'company_id = $1', 'code'),
   (28, 'depreciation_runs',  'company_id = $1', 'created_at'),
   (29, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (30, 'bank_recons',        'company_id = $1', 'created_at'),
   (31, 'bank_cleared',       'company_id = $1', 'line_id'),
   (32, 'attachments',        'company_id = $1', 'created_at'),
   (33, 'fiscal_periods',     'company_id = $1', 'start_date');
$$;

-- تغيير تواريخ السنة: الفترات بتتولّد من جديد إذا ما في ولا وحدة مقفولة
create or replace function public.fiscal_years_redates() returns trigger
language plpgsql security definer set search_path = public as $$
declare prev text := current_setting('sumou.internal', true);
begin
  if (new.start_date, new.end_date) is not distinct from (old.start_date, old.end_date) then return null; end if;
  if exists (select 1 from public.fiscal_periods where fiscal_year_id = new.id and (gl_locked or stock_locked)) then
    raise exception 'في فترات مقفولة بهالسنة، افتحها أول قبل ما تغيّر التواريخ';
  end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  delete from public.fiscal_periods where fiscal_year_id = new.id;
  perform public.ensure_fiscal_periods(new.id);
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  return null;
end $$;
drop trigger if exists fiscal_years_redates on public.fiscal_years;
create trigger fiscal_years_redates after update of start_date, end_date on public.fiscal_years
  for each row execute function public.fiscal_years_redates();
