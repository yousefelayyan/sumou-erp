-- =====================================================================
--  السمو ERP — المرحلة 23: قوائم الإعداد (مثل «إعداد» بستاليون)
--  وسائل الدفع (مربوطة على حساب صندوق/بنك)، البنوك، فروع البنوك، الدول، المناطق، أنواع الأوراق التجارية.
--  القوائم بتعبّي اختيارات جاهزة بالشاشات (البنك بالشيك، المدينة بالعميل، وسيلة الدفع بالفاتورة والسند).
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

create table if not exists public.lookups (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  kind       text not null check (kind in ('payment_method','bank','bank_branch','country','region','cheque_type')),
  code       text not null,
  name       text not null,
  name2      text,
  parent_id  uuid references public.lookups(id) on delete restrict deferrable initially deferred,
  account_id uuid references public.accounts(id) on delete set null,   -- لوسائل الدفع
  is_active  boolean not null default true,
  notes      text,
  created_by uuid default auth.uid(),
  created_at timestamptz default now(),
  updated_by uuid,
  updated_at timestamptz,
  unique (company_id, kind, code)
);
create index if not exists lookups_kind_idx on public.lookups (company_id, kind, code);

create or replace function public.lookups_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.lookups; a public.accounts;
begin
  if tg_op = 'UPDATE' then new.company_id := old.company_id; new.kind := old.kind; end if;
  new.code := btrim(coalesce(new.code, '')); new.name := btrim(coalesce(new.name, ''));
  if new.code = '' then raise exception 'الرمز مطلوب'; end if;
  if new.name = '' then raise exception 'الاسم مطلوب'; end if;
  if new.parent_id is not null then
    select * into p from public.lookups where id = new.parent_id;
    if p.id is null or p.company_id <> new.company_id
       or (new.kind = 'bank_branch' and p.kind <> 'bank') or (new.kind = 'region' and p.kind <> 'country')
       or new.kind not in ('bank_branch', 'region') then
      raise exception 'الأب مش مناسب (فرع البنك تحت بنك، والمنطقة تحت دولة)';
    end if;
  end if;
  if new.account_id is not null then
    select * into a from public.accounts where id = new.account_id;
    if a.id is null or a.company_id <> new.company_id or a.is_group then raise exception 'الحساب لازم يكون فرعي ومن نفس الشركة'; end if;
    if new.kind <> 'payment_method' then new.account_id := null; end if;
  end if;
  return new;
end $$;
drop trigger if exists lookups_before on public.lookups;
create trigger lookups_before before insert or update on public.lookups
  for each row execute function public.lookups_before();

alter table public.lookups enable row level security;
drop policy if exists lk_select on public.lookups;
create policy lk_select on public.lookups for select to authenticated using (public.has_company(company_id));
drop policy if exists lk_insert on public.lookups;
create policy lk_insert on public.lookups for insert to authenticated with check (public.can(company_id, 'lookups', 'add'));
drop policy if exists lk_update on public.lookups;
create policy lk_update on public.lookups for update to authenticated
  using (public.can(company_id, 'lookups', 'edit')) with check (public.can(company_id, 'lookups', 'edit'));
drop policy if exists lk_delete on public.lookups;
create policy lk_delete on public.lookups for delete to authenticated using (public.can(company_id, 'lookups', 'delete'));
grant select, insert, update, delete on public.lookups to authenticated;

drop trigger if exists ac_audit_stamp on public.lookups;
create trigger ac_audit_stamp before insert or update on public.lookups for each row execute function public.ac_audit_stamp();
drop trigger if exists zy_audit_log on public.lookups;
create trigger zy_audit_log after insert or update or delete on public.lookups for each row execute function public.zy_audit_log();

-- النسخ الاحتياطي
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
   (13, 'lookups',            'company_id = $1', 'parent_id nulls first, kind, code'),
   (14, 'journal_entries',    'company_id = $1', 'created_at'),
   (15, 'journal_lines',      'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (16, 'invoices',           'company_id = $1', 'created_at'),
   (17, 'invoice_lines',      'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (18, 'cheques',            'company_id = $1', 'created_at'),
   (19, 'cheque_events',      'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (20, 'stock_docs',         'company_id = $1', 'created_at'),
   (21, 'stock_doc_lines',    'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (22, 'stock_moves',        'company_id = $1', 'created_at'),
   (23, 'obligations',        'company_id = $1', 'due_date'),
   (24, 'recurring_entries',  'company_id = $1', 'created_at'),
   (25, 'employees',          'company_id = $1', 'code'),
   (26, 'payroll_runs',       'company_id = $1', 'period'),
   (27, 'payroll_lines',      'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (28, 'fixed_assets',       'company_id = $1', 'code'),
   (29, 'depreciation_runs',  'company_id = $1', 'created_at'),
   (30, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (31, 'bank_recons',        'company_id = $1', 'created_at'),
   (32, 'bank_cleared',       'company_id = $1', 'line_id'),
   (33, 'attachments',        'company_id = $1', 'created_at'),
   (34, 'fiscal_periods',     'company_id = $1', 'start_date');
$$;
