-- =====================================================================
--  السمو ERP — المرحلة 16: طريقة الترقيم (تنسيق أرقام المستندات)
--  لكل شركة ولكل نوع مستند: يدوي/تلقائي، يبدأ من جديد كل سنة أو كل شهر أو ما بيبدأ،
--  تسلسل منفصل لكل مركز كلفة أو مستودع، وشكل الرقم: عدد الخانات، حرف التنقيع، الفاصل،
--  نص سابق ولاحق، وإضافة رمز السنة/الشهر/الفرع للرقم.
--  الإعدادات بـ company_settings.numbering (jsonb)، والرقم المنسّق بعمود doc_code.
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

alter table public.company_settings add column if not exists numbering jsonb not null default '{}'::jsonb;

alter table public.journal_entries add column if not exists seq_key text;
alter table public.journal_entries add column if not exists doc_code text;
alter table public.invoices        add column if not exists seq_key text;
alter table public.invoices        add column if not exists doc_code text;
alter table public.stock_docs      add column if not exists seq_key text;
alter table public.stock_docs      add column if not exists doc_code text;

-- تعبئة المستندات القديمة بنفس ترقيمها الحالي (القيود والفواتير لكل سنة، والمخزون مستمر)
do $$
begin
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.journal_entries set seq_key = 'Y' || fiscal_year_id, doc_code = coalesce(doc_code, entry_no::text) where seq_key is null;
  update public.invoices        set seq_key = 'Y' || fiscal_year_id, doc_code = coalesce(doc_code, inv_no::text)   where seq_key is null;
  update public.stock_docs      set seq_key = '',                    doc_code = coalesce(doc_code, doc_no::text)   where seq_key is null;
  perform set_config('sumou.internal', '', true);
end $$;

alter table public.journal_entries alter column seq_key set default '';
alter table public.invoices        alter column seq_key set default '';
alter table public.stock_docs      alter column seq_key set default '';
alter table public.journal_entries alter column seq_key set not null;
alter table public.invoices        alter column seq_key set not null;
alter table public.stock_docs      alter column seq_key set not null;

-- القيد الفريد القديم (لكل سنة) بيتبدّل بقيد على مفتاح التسلسل
do $$
declare c record;
begin
  for c in
    select con.conname, rel.relname from pg_constraint con join pg_class rel on rel.oid = con.conrelid
    join pg_namespace n on n.oid = rel.relnamespace
    where n.nspname = 'public' and con.contype = 'u'
      and ((rel.relname = 'journal_entries' and pg_get_constraintdef(con.oid) = 'UNIQUE (company_id, fiscal_year_id, entry_type, entry_no)')
        or (rel.relname = 'invoices'        and pg_get_constraintdef(con.oid) = 'UNIQUE (company_id, fiscal_year_id, inv_type, inv_no)')
        or (rel.relname = 'stock_docs'      and pg_get_constraintdef(con.oid) = 'UNIQUE (company_id, doc_type, doc_no)'))
  loop
    execute format('alter table public.%I drop constraint %I', c.relname, c.conname);
  end loop;
end $$;
create unique index if not exists je_seq_uq  on public.journal_entries (company_id, entry_type, seq_key, entry_no);
create unique index if not exists inv_seq_uq on public.invoices (company_id, inv_type, seq_key, inv_no);
create unique index if not exists sd_seq_uq  on public.stock_docs (company_id, doc_type, seq_key, doc_no);

-- ---------------------------------------------------------------------
-- القاعدة: الافتراضي + المحفوظ للشركة، بعد التنظيف
-- ---------------------------------------------------------------------
create or replace function public.numbering_rule(p_company uuid, p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d jsonb; u jsonb; r jsonb;
begin
  d := jsonb_build_object('mode', 'auto', 'reset', case when p_key like 'stock_%' then 'none' else 'year' end, 'split', 'none',
         'digits', 0, 'pad', '0', 'sep', '-', 'prefix', '', 'suffix', '',
         'add_year', false, 'year_digits', 4, 'add_month', false, 'add_split', false);
  if p_key is null then return d; end if;
  select s.numbering -> p_key into u from public.company_settings s where s.company_id = p_company;
  if u is null or jsonb_typeof(u) <> 'object' then return d; end if;
  r := d || u;
  -- تنظيف القيم
  if r->>'mode'  not in ('auto','manual') then r := r || '{"mode":"auto"}'; end if;
  if r->>'reset' not in ('none','year','month') then r := r || jsonb_build_object('reset', d->>'reset'); end if;
  if not ((p_key in ('sale','sale_return','purchase','purchase_return') and r->>'split' in ('none','cost_center','warehouse'))
       or (p_key like 'stock_%' and r->>'split' in ('none','warehouse'))) then r := r || '{"split":"none"}'; end if;
  r := r || jsonb_build_object(
    'digits', least(greatest(coalesce(case when (r->>'digits') ~ '^\d{1,3}$' then (r->>'digits')::int end, 0), 0), 12),
    'pad', left(regexp_replace(coalesce(r->>'pad', '0'), '[<>"''&\s]', '', 'g'), 1),
    'sep', left(regexp_replace(coalesce(r->>'sep', ''), '[<>"''&]', '', 'g'), 3),
    'prefix', left(regexp_replace(coalesce(r->>'prefix', ''), '[<>"''&]', '', 'g'), 15),
    'suffix', left(regexp_replace(coalesce(r->>'suffix', ''), '[<>"''&]', '', 'g'), 15),
    'year_digits', case when r->>'year_digits' = '2' then 2 else 4 end,
    'add_year',  coalesce(case when jsonb_typeof(r->'add_year')  = 'boolean' then (r->>'add_year')::boolean end, false),
    'add_month', coalesce(case when jsonb_typeof(r->'add_month') = 'boolean' then (r->>'add_month')::boolean end, false),
    'add_split', coalesce(case when jsonb_typeof(r->'add_split') = 'boolean' then (r->>'add_split')::boolean end, false));
  return r;
end $$;

-- مفتاح التسلسل حسب القاعدة
create or replace function public.numbering_key(r jsonb, p_date date, p_fy uuid, p_split uuid) returns text
language sql immutable as $$
  select concat_ws('|',
    case r->>'reset' when 'year'  then 'Y' || coalesce(p_fy::text, extract(year from p_date)::text)
                     when 'month' then 'Y' || coalesce(p_fy::text, extract(year from p_date)::text) || 'M' || to_char(p_date, 'YYYY-MM') end,
    case when r->>'split' <> 'none' then 'S' || coalesce(p_split::text, '-') end)
$$;

-- الرقم المنسّق: النص السابق + رمز الفرع + السنة + الشهر + الرقم + النص اللاحق
create or replace function public.numbering_format(r jsonb, p_no int, p_date date, p_fy uuid, p_split_code text) returns text
language plpgsql stable security definer set search_path = public as $$
declare parts text[] := '{}'; y int; n text; dg int := (r->>'digits')::int;
begin
  if p_no is null then return null; end if;
  if (r->>'add_split')::boolean and r->>'split' <> 'none' and nullif(regexp_replace(coalesce(p_split_code, ''), '[<>"''&]', '', 'g'), '') is not null then
    parts := parts || left(regexp_replace(p_split_code, '[<>"''&]', '', 'g'), 15);
  end if;
  if (r->>'add_year')::boolean then
    select extract(year from start_date)::int into y from public.fiscal_years where id = p_fy;
    y := coalesce(y, extract(year from p_date)::int);
    parts := parts || case when (r->>'year_digits')::int = 2 then lpad((y % 100)::text, 2, '0') else y::text end;
  end if;
  if (r->>'add_month')::boolean then parts := parts || to_char(p_date, 'MM'); end if;
  n := p_no::text;
  if dg > length(n) then n := lpad(n, dg, coalesce(nullif(r->>'pad', ''), '0')); end if;
  parts := parts || n;
  return coalesce(r->>'prefix', '') || array_to_string(parts, coalesce(r->>'sep', '')) || coalesce(r->>'suffix', '');
end $$;

-- ---------------------------------------------------------------------
-- الـ triggers: اسمها بيبدأ بـ aa_ عشان تشتغل قبل باقي الـ triggers
-- ---------------------------------------------------------------------
create or replace function public.aa_number_entries() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb; sp uuid; spc text; fy uuid; k text; co uuid; ty text; chg boolean := false; intl boolean := public.is_internal();
begin
  if tg_op = 'UPDATE' then co := old.company_id; ty := old.entry_type; else co := new.company_id; ty := new.entry_type; end if;
  r := public.numbering_rule(co, case when ty in ('journal','receipt','payment') then ty end);
  fy := new.fiscal_year_id;
  k := public.numbering_key(r, new.entry_date, fy, sp);
  if tg_op = 'INSERT' then
    -- الاسترجاع من نسخة احتياطية: الرقم والتسلسل بيرجعوا مثل ما كانوا
    if intl and new.doc_code is not null and new.entry_no is not null then
      new.seq_key := coalesce(new.seq_key, k); return new;
    end if;
    if not intl and r->>'mode' = 'auto' then new.entry_no := null; end if;   -- التلقائي: الرقم من البرنامج بس
    new.seq_key := k; chg := true;
  else
    new.seq_key := coalesce(old.seq_key, new.seq_key);
    if new.entry_no is null then new.entry_no := old.entry_no; end if;
    if old.doc_code is null then return new; end if;   -- تعبئة المستندات القديمة
    if old.status = 'draft' and (new.entry_date is distinct from old.entry_date or new.fiscal_year_id is distinct from old.fiscal_year_id) and k is distinct from old.seq_key then
      -- المسودة انتقلت لشهر/سنة/فرع ثاني: بتاخذ رقم من التسلسل الجديد
      new.seq_key := k; if new.entry_no = old.entry_no or (not intl and r->>'mode' = 'auto') then new.entry_no := null; end if; chg := true;
    elsif new.entry_no <> old.entry_no then
      if not intl and r->>'mode' = 'auto' then new.entry_no := old.entry_no; else chg := true; end if;
    elsif old.status = 'draft' and (new.entry_date is distinct from old.entry_date or new.fiscal_year_id is distinct from old.fiscal_year_id) then chg := true;
    end if;
    if not chg then new.doc_code := old.doc_code; return new; end if;
  end if;
  if new.entry_no is not null and (new.entry_no <= 0 or new.entry_no > 999999999) then raise exception 'رقم المستند لازم يكون بين 1 و 999999999'; end if;
  perform pg_advisory_xact_lock(hashtext('je|' || co || '|' || ty || '|' || new.seq_key));
  if new.entry_no is null then
    select coalesce(max(x.entry_no), 0) + 1 into new.entry_no from public.journal_entries x where x.company_id = co and x.entry_type = ty and x.seq_key = new.seq_key;
    loop   -- بعد تغيير القاعدة: نتخطى أي رقم بيطلع شكله مكرر
      new.doc_code := public.numbering_format(r, new.entry_no, new.entry_date, fy, spc);
      exit when not exists (select 1 from public.journal_entries x where x.company_id = co and x.entry_type = ty and x.doc_code = new.doc_code and x.fiscal_year_id = new.fiscal_year_id and x.id <> new.id);
      new.entry_no := new.entry_no + 1;
    end loop;
  else
    if exists (select 1 from public.journal_entries x where x.company_id = co and x.entry_type = ty and x.seq_key = new.seq_key and x.entry_no = new.entry_no and x.id <> new.id) then
      raise exception 'رقم المستند % مستعمل من قبل بنفس التسلسل', new.entry_no;
    end if;
    new.doc_code := public.numbering_format(r, new.entry_no, new.entry_date, fy, spc);
    if exists (select 1 from public.journal_entries x where x.company_id = co and x.entry_type = ty and x.doc_code = new.doc_code and x.fiscal_year_id = new.fiscal_year_id and x.id <> new.id) then
      raise exception 'الرقم % موجود على مستند ثاني بنفس السنة', new.doc_code;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists aa_number_entries on public.journal_entries;
create trigger aa_number_entries before insert or update on public.journal_entries
  for each row execute function public.aa_number_entries();
create index if not exists je_code_idx on public.journal_entries (company_id, entry_type, doc_code);

create or replace function public.aa_number_invoices() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb; sp uuid; spc text; fy uuid; k text; co uuid; ty text; chg boolean := false; intl boolean := public.is_internal();
begin
  if tg_op = 'UPDATE' then co := old.company_id; ty := old.inv_type; else co := new.company_id; ty := new.inv_type; end if;
  r := public.numbering_rule(co, ty);
  fy := new.fiscal_year_id;
  sp := case r->>'split' when 'cost_center' then new.cost_center_id when 'warehouse' then new.warehouse_id end;
  if sp is not null then
    if r->>'split' = 'cost_center' then select code into spc from public.cost_centers where id = sp and company_id = co;
    else select code into spc from public.warehouses where id = sp and company_id = co; end if;
  end if;
  k := public.numbering_key(r, new.inv_date, fy, sp);
  if tg_op = 'INSERT' then
    -- الاسترجاع من نسخة احتياطية: الرقم والتسلسل بيرجعوا مثل ما كانوا
    if intl and new.doc_code is not null and new.inv_no is not null then
      new.seq_key := coalesce(new.seq_key, k); return new;
    end if;
    if not intl and r->>'mode' = 'auto' then new.inv_no := null; end if;   -- التلقائي: الرقم من البرنامج بس
    new.seq_key := k; chg := true;
  else
    new.seq_key := coalesce(old.seq_key, new.seq_key);
    if new.inv_no is null then new.inv_no := old.inv_no; end if;
    if old.doc_code is null then return new; end if;   -- تعبئة المستندات القديمة
    if old.status = 'draft' and (new.inv_date is distinct from old.inv_date or new.fiscal_year_id is distinct from old.fiscal_year_id or new.cost_center_id is distinct from old.cost_center_id or new.warehouse_id is distinct from old.warehouse_id) and k is distinct from old.seq_key then
      -- المسودة انتقلت لشهر/سنة/فرع ثاني: بتاخذ رقم من التسلسل الجديد
      new.seq_key := k; if new.inv_no = old.inv_no or (not intl and r->>'mode' = 'auto') then new.inv_no := null; end if; chg := true;
    elsif new.inv_no <> old.inv_no then
      if not intl and r->>'mode' = 'auto' then new.inv_no := old.inv_no; else chg := true; end if;
    elsif old.status = 'draft' and (new.inv_date is distinct from old.inv_date or new.fiscal_year_id is distinct from old.fiscal_year_id or new.cost_center_id is distinct from old.cost_center_id or new.warehouse_id is distinct from old.warehouse_id) then chg := true;
    end if;
    if not chg then new.doc_code := old.doc_code; return new; end if;
  end if;
  if new.inv_no is not null and (new.inv_no <= 0 or new.inv_no > 999999999) then raise exception 'رقم الفاتورة لازم يكون بين 1 و 999999999'; end if;
  perform pg_advisory_xact_lock(hashtext('inv|' || co || '|' || ty || '|' || new.seq_key));
  if new.inv_no is null then
    select coalesce(max(x.inv_no), 0) + 1 into new.inv_no from public.invoices x where x.company_id = co and x.inv_type = ty and x.seq_key = new.seq_key;
    loop   -- بعد تغيير القاعدة: نتخطى أي رقم بيطلع شكله مكرر
      new.doc_code := public.numbering_format(r, new.inv_no, new.inv_date, fy, spc);
      exit when not exists (select 1 from public.invoices x where x.company_id = co and x.inv_type = ty and x.doc_code = new.doc_code and x.fiscal_year_id = new.fiscal_year_id and x.id <> new.id);
      new.inv_no := new.inv_no + 1;
    end loop;
  else
    if exists (select 1 from public.invoices x where x.company_id = co and x.inv_type = ty and x.seq_key = new.seq_key and x.inv_no = new.inv_no and x.id <> new.id) then
      raise exception 'رقم الفاتورة % مستعمل من قبل بنفس التسلسل', new.inv_no;
    end if;
    new.doc_code := public.numbering_format(r, new.inv_no, new.inv_date, fy, spc);
    if exists (select 1 from public.invoices x where x.company_id = co and x.inv_type = ty and x.doc_code = new.doc_code and x.fiscal_year_id = new.fiscal_year_id and x.id <> new.id) then
      raise exception 'الرقم % موجود على مستند ثاني بنفس السنة', new.doc_code;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists aa_number_invoices on public.invoices;
create trigger aa_number_invoices before insert or update on public.invoices
  for each row execute function public.aa_number_invoices();
create index if not exists inv_code_idx on public.invoices (company_id, inv_type, doc_code);

create or replace function public.aa_number_stock() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb; sp uuid; spc text; fy uuid; k text; co uuid; ty text; chg boolean := false; intl boolean := public.is_internal();
begin
  if tg_op = 'UPDATE' then co := old.company_id; ty := old.doc_type; else co := new.company_id; ty := new.doc_type; end if;
  r := public.numbering_rule(co, 'stock_' || ty);
  sp := case when r->>'split' = 'warehouse' then new.warehouse_id end;
  if sp is not null then select code into spc from public.warehouses where id = sp and company_id = co; end if;
  select id into fy from public.fiscal_years where company_id = co and new.doc_date between start_date and end_date order by start_date desc limit 1;
  if fy is null and r->>'reset' <> 'none' and not public.is_internal() then raise exception 'ما في سنة مالية بتاريخ السند، والترقيم بيبدأ من جديد كل سنة/شهر'; end if;
  k := public.numbering_key(r, new.doc_date, fy, sp);
  if tg_op = 'INSERT' then
    -- الاسترجاع من نسخة احتياطية: الرقم والتسلسل بيرجعوا مثل ما كانوا
    if intl and new.doc_code is not null and new.doc_no is not null then
      new.seq_key := coalesce(new.seq_key, k); return new;
    end if;
    if not intl and r->>'mode' = 'auto' then new.doc_no := null; end if;   -- التلقائي: الرقم من البرنامج بس
    new.seq_key := k; chg := true;
  else
    new.seq_key := coalesce(old.seq_key, new.seq_key);
    if new.doc_no is null then new.doc_no := old.doc_no; end if;
    if old.doc_code is null then return new; end if;   -- تعبئة المستندات القديمة
    if old.status = 'draft' and (new.doc_date is distinct from old.doc_date or new.warehouse_id is distinct from old.warehouse_id) and k is distinct from old.seq_key then
      -- المسودة انتقلت لشهر/سنة/فرع ثاني: بتاخذ رقم من التسلسل الجديد
      new.seq_key := k; if new.doc_no = old.doc_no or (not intl and r->>'mode' = 'auto') then new.doc_no := null; end if; chg := true;
    elsif new.doc_no <> old.doc_no then
      if not intl and r->>'mode' = 'auto' then new.doc_no := old.doc_no; else chg := true; end if;
    elsif old.status = 'draft' and (new.doc_date is distinct from old.doc_date or new.warehouse_id is distinct from old.warehouse_id) then chg := true;
    end if;
    if not chg then new.doc_code := old.doc_code; return new; end if;
  end if;
  if new.doc_no is not null and (new.doc_no <= 0 or new.doc_no > 999999999) then raise exception 'رقم السند لازم يكون بين 1 و 999999999'; end if;
  perform pg_advisory_xact_lock(hashtext('sd|' || co || '|' || ty || '|' || new.seq_key));
  if new.doc_no is null then
    select coalesce(max(x.doc_no), 0) + 1 into new.doc_no from public.stock_docs x where x.company_id = co and x.doc_type = ty and x.seq_key = new.seq_key;
    loop   -- بعد تغيير القاعدة: نتخطى أي رقم بيطلع شكله مكرر
      new.doc_code := public.numbering_format(r, new.doc_no, new.doc_date, fy, spc);
      exit when not exists (select 1 from public.stock_docs x where x.company_id = co and x.doc_type = ty and x.doc_code = new.doc_code and extract(year from x.doc_date) = extract(year from new.doc_date) and x.id <> new.id);
      new.doc_no := new.doc_no + 1;
    end loop;
  else
    if exists (select 1 from public.stock_docs x where x.company_id = co and x.doc_type = ty and x.seq_key = new.seq_key and x.doc_no = new.doc_no and x.id <> new.id) then
      raise exception 'رقم السند % مستعمل من قبل بنفس التسلسل', new.doc_no;
    end if;
    new.doc_code := public.numbering_format(r, new.doc_no, new.doc_date, fy, spc);
    if exists (select 1 from public.stock_docs x where x.company_id = co and x.doc_type = ty and x.doc_code = new.doc_code and extract(year from x.doc_date) = extract(year from new.doc_date) and x.id <> new.id) then
      raise exception 'الرقم % موجود على مستند ثاني بنفس السنة', new.doc_code;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists aa_number_stock on public.stock_docs;
create trigger aa_number_stock before insert or update on public.stock_docs
  for each row execute function public.aa_number_stock();
create index if not exists sd_code_idx on public.stock_docs (company_id, doc_type, doc_code);

-- الصلاحيات
revoke execute on function public.numbering_rule(uuid, text), public.numbering_key(jsonb, date, uuid, uuid),
  public.numbering_format(jsonb, int, date, uuid, text) from public, anon, authenticated;
revoke execute on function public.aa_number_entries(), public.aa_number_invoices(), public.aa_number_stock() from public, anon, authenticated;
-- دوال التقارير انعملت من جديد بالمراحل 3 و4 و13: صلاحية التنفيذ للمستخدمين المسجلين بس
revoke execute on function public.rep_ledger(uuid, uuid, uuid, date, date), public.rep_journal(uuid, uuid, date, date, text),
  public.rep_party_ledger(uuid, uuid, uuid, date, date), public.pending_posts(uuid), public.rep_bank_lines(uuid) from public, anon;
grant execute on function public.rep_ledger(uuid, uuid, uuid, date, date), public.rep_journal(uuid, uuid, date, date, text),
  public.rep_party_ledger(uuid, uuid, uuid, date, date), public.pending_posts(uuid), public.rep_bank_lines(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- فئات المواد (الأصناف)
-- ---------------------------------------------------------------------
create table if not exists public.item_categories (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code       text not null,
  name       text not null,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, code)
);
alter table public.items add column if not exists category_id uuid references public.item_categories(id) on delete restrict;
create index if not exists items_cat_idx on public.items (category_id) where category_id is not null;

-- الصنف وفئته لازم يكونوا بنفس الشركة
create or replace function public.items_category_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.category_id is not null and not exists (select 1 from public.item_categories c where c.id = new.category_id and c.company_id = new.company_id) then
    raise exception 'الفئة مش لهالشركة';
  end if;
  return new;
end $$;
drop trigger if exists items_category_check on public.items;
create trigger items_category_check before insert or update of category_id, company_id on public.items
  for each row execute function public.items_category_check();
revoke execute on function public.items_category_check() from public, anon, authenticated;

create or replace function public.item_categories_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then new.company_id := old.company_id; end if;
  new.code := btrim(new.code); new.name := btrim(new.name);
  if new.code = '' or new.name = '' then raise exception 'رمز الفئة واسمها مطلوبين'; end if;
  return new;
end $$;
drop trigger if exists item_categories_before on public.item_categories;
create trigger item_categories_before before insert or update on public.item_categories
  for each row execute function public.item_categories_before();
revoke execute on function public.item_categories_before() from public, anon, authenticated;

alter table public.item_categories enable row level security;
drop policy if exists icat_select on public.item_categories;
create policy icat_select on public.item_categories for select to authenticated using (public.has_company(company_id));
drop policy if exists icat_insert on public.item_categories;
create policy icat_insert on public.item_categories for insert to authenticated with check (public.can(company_id, 'items', 'add'));
drop policy if exists icat_update on public.item_categories;
create policy icat_update on public.item_categories for update to authenticated
  using (public.can(company_id, 'items', 'edit')) with check (public.can(company_id, 'items', 'edit'));
drop policy if exists icat_delete on public.item_categories;
create policy icat_delete on public.item_categories for delete to authenticated using (public.can(company_id, 'items', 'delete'));
grant select, insert, update, delete on public.item_categories to authenticated;
revoke all on public.item_categories from anon;
