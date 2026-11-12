-- =====================================================================
--  السمو ERP — المرحلة 21: الدوائر (فروع/أقسام الشركة على شكل شجرة)
--  الدائرة إما رئيسية (بيتفرّع منها) أو فرعية (بتنستعمل بالمستندات).
--  كل مستخدم إله دائرة افتراضية بكل شركة، والمستند بياخذها لحاله إذا ما انختارت.
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

create table if not exists public.departments (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies(id) on delete cascade,
  code           text not null,
  name           text not null,
  name2          text,
  kind           text not null default 'sub' check (kind in ('main','sub')),
  parent_id      uuid references public.departments(id) on delete restrict deferrable initially deferred,
  level          int not null default 1,
  is_active      boolean not null default true,
  sales_tax_no   text,
  income_tax_no  text,
  national_no    text,
  currency       text,
  city           text,
  address        text,
  phone          text,
  mobile         text,
  email          text,
  warehouse_id   uuid references public.warehouses(id) on delete set null,
  cost_center_id uuid references public.cost_centers(id) on delete set null,
  notes          text,
  created_by     uuid default auth.uid(),
  created_at     timestamptz default now(),
  updated_by     uuid,
  updated_at     timestamptz,
  unique (company_id, code)
);
create index if not exists departments_parent_idx on public.departments (parent_id);

create or replace function public.departments_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.departments; x uuid; n int := 0;
begin
  if tg_op = 'UPDATE' then new.company_id := old.company_id; end if;
  new.code := btrim(coalesce(new.code, ''));
  new.name := btrim(coalesce(new.name, ''));
  if new.code = '' then raise exception 'رمز الدائرة مطلوب'; end if;
  if new.name = '' then raise exception 'وصف الدائرة مطلوب'; end if;
  if new.parent_id is null then new.level := 1;
  else
    if new.parent_id = new.id then raise exception 'الدائرة ما بتكون أب لحالها'; end if;
    select * into p from public.departments where id = new.parent_id;
    if p.id is null or p.company_id <> new.company_id then raise exception 'الدائرة الرئيسية مش لهالشركة'; end if;
    if p.kind <> 'main' then raise exception 'الدائرة الأب لازم تكون رئيسية'; end if;
    -- منع الدوران
    x := p.parent_id;
    while x is not null loop
      if x = new.id then raise exception 'ما بصير الدائرة تكون تحت وحدة من فروعها'; end if;
      n := n + 1; if n > 50 then exit; end if;
      select parent_id into x from public.departments where id = x;
    end loop;
    new.level := p.level + 1;
  end if;
  if tg_op = 'UPDATE' and new.kind = 'sub' and old.kind = 'main'
     and exists (select 1 from public.departments where parent_id = new.id) then
    raise exception 'الدائرة إلها فروع، ما بتصير فرعية';
  end if;
  if new.warehouse_id is not null and not exists (select 1 from public.warehouses w where w.id = new.warehouse_id and w.company_id = new.company_id) then
    raise exception 'المستودع مش لهالشركة';
  end if;
  if new.cost_center_id is not null and not exists (select 1 from public.cost_centers c where c.id = new.cost_center_id and c.company_id = new.company_id) then
    raise exception 'مركز الكلفة مش لهالشركة';
  end if;
  return new;
end $$;
drop trigger if exists departments_before on public.departments;
create trigger departments_before before insert or update on public.departments
  for each row execute function public.departments_before();

-- لما يتغيّر مستوى الأب، الفروع بتتحدّث
create or replace function public.departments_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.level is distinct from old.level then
    update public.departments set level = new.level + 1 where parent_id = new.id;
  end if;
  -- دائرة انوقفت أو صارت رئيسية: بتنشال كافتراضية عن المستخدمين
  if (not new.is_active or new.kind <> 'sub') and (old.is_active and old.kind = 'sub') then
    update public.user_companies set department_id = null where department_id = new.id;
  end if;
  return null;
end $$;
drop trigger if exists departments_after on public.departments;
create trigger departments_after after update of level, is_active, kind on public.departments
  for each row execute function public.departments_after();

alter table public.departments enable row level security;
drop policy if exists dept_select on public.departments;
create policy dept_select on public.departments for select to authenticated using (public.has_company(company_id));
drop policy if exists dept_insert on public.departments;
create policy dept_insert on public.departments for insert to authenticated with check (public.can(company_id, 'departments', 'add'));
drop policy if exists dept_update on public.departments;
create policy dept_update on public.departments for update to authenticated
  using (public.can(company_id, 'departments', 'edit')) with check (public.can(company_id, 'departments', 'edit'));
drop policy if exists dept_delete on public.departments;
create policy dept_delete on public.departments for delete to authenticated using (public.can(company_id, 'departments', 'delete'));
grant select, insert, update, delete on public.departments to authenticated;

-- سجل التتبع
drop trigger if exists ac_audit_stamp on public.departments;
create trigger ac_audit_stamp before insert or update on public.departments for each row execute function public.ac_audit_stamp();
drop trigger if exists zy_audit_log on public.departments;
create trigger zy_audit_log after insert or update or delete on public.departments for each row execute function public.zy_audit_log();

-- ---------------------------------------------------------------------
--  دائرة المستخدم الافتراضية بكل شركة + «إخفاء الدوائر»
-- ---------------------------------------------------------------------
alter table public.user_companies add column if not exists department_id uuid references public.departments(id) on delete set null;
alter table public.user_companies add column if not exists hide_departments boolean not null default false;

create or replace function public.user_companies_dept_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.department_id is not null and not exists (
       select 1 from public.departments d where d.id = new.department_id and d.company_id = new.company_id and d.kind = 'sub') then
    raise exception 'الدائرة لازم تكون فرعية ومن نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists user_companies_dept_check on public.user_companies;
create trigger user_companies_dept_check before insert or update of department_id, company_id on public.user_companies
  for each row execute function public.user_companies_dept_check();

create or replace function public.my_department(p_company uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select department_id from public.user_companies where user_id = auth.uid() and company_id = p_company
$$;
grant execute on function public.my_department(uuid) to authenticated;

-- ---------------------------------------------------------------------
--  الدائرة على المستندات: القيود، الفواتير، سندات المخزون
-- ---------------------------------------------------------------------
alter table public.journal_entries add column if not exists department_id uuid references public.departments(id) on delete restrict;
alter table public.invoices        add column if not exists department_id uuid references public.departments(id) on delete restrict;
alter table public.stock_docs      add column if not exists department_id uuid references public.departments(id) on delete restrict;
create index if not exists journal_entries_dept_idx on public.journal_entries (company_id, department_id);
create index if not exists invoices_dept_idx on public.invoices (company_id, department_id);

create or replace function public.ad_doc_department() returns trigger
language plpgsql security definer set search_path = public as $$
declare cid uuid; uc public.user_companies; def uuid;
begin
  if public.is_internal() then
    -- القيد العكسي بياخذ دائرة القيد الأصلي
    if tg_table_name = 'journal_entries' and tg_op = 'INSERT' and new.department_id is null then
      -- (to_jsonb عشان الدالة نفسها على الفواتير وسندات المخزون، وما فيهم reversal_of)
      if (to_jsonb(new) ->> 'reversal_of') is not null then
        select department_id into new.department_id from public.journal_entries where id = (to_jsonb(new) ->> 'reversal_of')::uuid;
      end if;
    end if;
    return new;
  end if;
  cid := case when tg_op = 'UPDATE' then old.company_id else new.company_id end;   -- الشركة ما بتتغيّر
  select * into uc from public.user_companies where user_id = auth.uid() and company_id = cid;
  def := uc.department_id;
  if def is not null and not exists (select 1 from public.departments d where d.id = def and d.company_id = cid and d.kind = 'sub' and d.is_active) then
    def := null;   -- الدائرة الافتراضية انوقفت: المستند بينحفظ بدون دائرة
  end if;
  -- «إخفاء الدوائر»: المستخدم ما بيختار، بتنحط دائرته
  if coalesce(uc.hide_departments, false) and not public.is_admin() then
    new.department_id := case when tg_op = 'UPDATE' then old.department_id else def end;
    return new;
  end if;
  if tg_op = 'INSERT' and new.department_id is null then new.department_id := def; end if;
  if new.department_id is not null and (tg_op = 'INSERT' or new.department_id is distinct from old.department_id)
     and not exists (select 1 from public.departments d where d.id = new.department_id and d.company_id = cid
                       and d.kind = 'sub' and d.is_active) then
    raise exception 'الدائرة لازم تكون فرعية وفعّالة ومن نفس الشركة';
  end if;
  return new;
end $$;
do $$
declare t text;
begin
  foreach t in array array['journal_entries','invoices','stock_docs'] loop
    execute format('drop trigger if exists ad_doc_department on public.%I', t);
    execute format('create trigger ad_doc_department before insert or update of department_id on public.%I for each row execute function public.ad_doc_department()', t);
  end loop;
end $$;

-- قيد الفاتورة وسند المخزون (من النظام) بياخذ دائرة المستند
create or replace function public.zx_entry_department_sync() returns trigger
language plpgsql security definer set search_path = public as $$
declare prev text := current_setting('sumou.internal', true); ids uuid[];
begin
  if new.department_id is null then return null; end if;
  if tg_table_name = 'invoices' then ids := array[new.entry_id, new.cogs_entry_id, new.cancel_entry_id];
  else ids := array[new.entry_id]; end if;
  if not exists (select 1 from public.journal_entries where id = any(ids) and department_id is distinct from new.department_id) then return null; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.journal_entries set department_id = new.department_id
   where id = any(ids) and department_id is distinct from new.department_id;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  return null;
end $$;
revoke execute on function public.zx_entry_department_sync() from public, anon, authenticated;
drop trigger if exists zx_entry_department_sync on public.invoices;
create trigger zx_entry_department_sync after insert or update of entry_id, cogs_entry_id, cancel_entry_id, department_id on public.invoices
  for each row execute function public.zx_entry_department_sync();
drop trigger if exists zx_entry_department_sync on public.stock_docs;
create trigger zx_entry_department_sync after insert or update of entry_id, department_id on public.stock_docs
  for each row execute function public.zx_entry_department_sync();

-- النسخ الاحتياطي: الدوائر قبل المستندات
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
   (32, 'attachments',        'company_id = $1', 'created_at');
$$;
