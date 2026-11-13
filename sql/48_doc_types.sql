-- =====================================================================
--  السمو ERP — المرحلة 48: أنواع السندات (اليوميات) الإلزامية
--  doc_types: لكل نوع مستند (قيد/افتتاحية/قبض/صرف/فواتير/سندات مخزون) أنواع، وواحد افتراضي بيتعمل لحاله.
--  كل نوع: تسلسل وبادئة لحاله (own_seq/prefix)، عدد نسخ الطباعة، تقييد التاريخ بتاريخ اليوم،
--  مدة التعديل/الحذف بالأيام من يوم الإدخال (0 = نفس اليوم)، قفل الدائرة على دائرة المستخدم، ولجنة الجرد (لسندات الجرد).
--  المدير ومين إله صلاحية edit على شاشة doc_types مستثنى من القيود.
-- =====================================================================
create table if not exists public.doc_types (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  kind         text not null check (kind in ('journal','opening','receipt','payment','sale','sale_return','purchase','purchase_return','stock_in','stock_out','stock_transfer','stock_count')),
  code         text not null,
  name         text not null,
  is_default   boolean not null default false,
  is_active    boolean not null default true,
  own_seq      boolean not null default false,
  prefix       text,
  print_copies int not null default 1 check (print_copies between 1 and 5),
  date_today   boolean not null default false,
  edit_days    int check (edit_days between 0 and 3650),
  lock_dept    boolean not null default false,
  committee    text,
  notes        text,
  created_at   timestamptz not null default now(),
  unique (company_id, kind, code)
);
create unique index if not exists doc_types_default on public.doc_types (company_id, kind) where is_default;
create unique index if not exists doc_types_prefix on public.doc_types (company_id, kind, lower(prefix)) where own_seq;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'doc_types_own_seq_prefix') then
    alter table public.doc_types add constraint doc_types_own_seq_prefix check (not own_seq or coalesce(trim(prefix), '') <> '');
  end if;
end $$;
alter table public.doc_types enable row level security;
grant select, insert, update, delete on public.doc_types to authenticated;
drop policy if exists dt_select on public.doc_types;
create policy dt_select on public.doc_types for select to authenticated using (public.has_company(company_id));
drop policy if exists dt_write on public.doc_types;
create policy dt_write on public.doc_types for all to authenticated
  using (public.can(company_id, 'doc_types', 'edit') and public.tenant_writable()) with check (public.can(company_id, 'doc_types', 'edit') and public.tenant_writable());

alter table public.journal_entries add column if not exists doc_type_id uuid references public.doc_types(id) on delete restrict;
alter table public.invoices        add column if not exists doc_type_id uuid references public.doc_types(id) on delete restrict;
alter table public.stock_docs      add column if not exists doc_type_id uuid references public.doc_types(id) on delete restrict;

create or replace function public.doc_kind(p_tbl text, p_type text) returns text
language sql immutable as $$
  select case p_tbl when 'journal_entries' then case when p_type in ('journal','opening','receipt','payment') then p_type end
                    when 'invoices' then p_type
                    when 'stock_docs' then 'stock_' || p_type end;
$$;

-- النوع الافتراضي (بيتعمل لحاله إذا ناقص)
create or replace function public.doc_type_default(p_company uuid, p_kind text) returns uuid
language plpgsql security definer set search_path = public as $$
declare tid uuid;
begin
  if p_kind is null then return null; end if;
  select id into tid from public.doc_types where company_id = p_company and kind = p_kind and is_default and is_active;
  if tid is not null then return tid; end if;
  select id into tid from public.doc_types where company_id = p_company and kind = p_kind and is_active order by code limit 1;
  if tid is not null then return tid; end if;
  insert into public.doc_types (company_id, kind, code, name, is_default)
  values (p_company, p_kind, '01', 'عام', not exists (select 1 from public.doc_types where company_id = p_company and kind = p_kind and is_default))
  on conflict (company_id, kind, code) do update set is_active = true returning id into tid;
  return tid;
end $$;
revoke execute on function public.doc_type_default(uuid, text) from public, anon, authenticated;

create or replace function public.ensure_doc_types(p_company uuid) returns int
language plpgsql security definer set search_path = public as $$
declare k text; n int := 0;
begin
  if not public.has_company(p_company) or not public.tenant_writable() then raise exception 'ما عندك صلاحية'; end if;
  foreach k in array array['journal','opening','receipt','payment','sale','sale_return','purchase','purchase_return','stock_in','stock_out','stock_transfer','stock_count'] loop
    if not exists (select 1 from public.doc_types where company_id = p_company and kind = k) then perform public.doc_type_default(p_company, k); n := n + 1; end if;
  end loop;
  return n;
end $$;

-- الفحص قبل الترقيم (a1 قبل aa_)
create or replace function public.a1_doc_type() returns trigger
language plpgsql security definer set search_path = public as $$
declare rw jsonb; o jsonb; co uuid; kind text; dt public.doc_types; d date; od date; free boolean; ud uuid;
begin
  rw := to_jsonb(case when tg_op = 'DELETE' then old else new end);
  o := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  co := (rw ->> 'company_id')::uuid;
  kind := public.doc_kind(tg_table_name, coalesce(rw ->> 'entry_type', rw ->> 'inv_type', rw ->> 'doc_type'));
  if kind is null then
    if tg_op <> 'DELETE' then new.doc_type_id := null; return new; end if;
    return old;
  end if;
  if tg_op <> 'DELETE' then
    if new.doc_type_id is null then new.doc_type_id := public.doc_type_default(co, kind); end if;
    if tg_op = 'INSERT' or new.doc_type_id is distinct from old.doc_type_id then
      select * into dt from public.doc_types where id = new.doc_type_id;
      if dt.id is null or dt.company_id <> co or dt.kind <> kind then raise exception 'نوع السند مش لهالشركة أو مش لهالنوع'; end if;
      if not dt.is_active and not public.is_internal() then raise exception 'نوع السند «%» موقوف', dt.name; end if;
      if tg_op = 'UPDATE' and (o ->> 'status') <> 'draft' and not public.is_internal() then raise exception 'ما بتقدر تغيّر نوع سند مرحّل'; end if;
    end if;
  end if;
  if public.is_internal() then return case when tg_op = 'DELETE' then old else new end; end if;
  if tg_op <> 'DELETE' then rw := to_jsonb(new); end if;   -- بعد تعبئة النوع الافتراضي
  free := public.is_admin() or public.can(co, 'doc_types', 'edit');
  if free then return case when tg_op = 'DELETE' then old else new end; end if;
  d  := coalesce(rw ->> 'entry_date', rw ->> 'inv_date', rw ->> 'doc_date')::date;
  od := coalesce(o ->> 'entry_date', o ->> 'inv_date', o ->> 'doc_date')::date;
  -- القيود بتنفحص على النوع القديم والجديد (تغيير النوع ما بيهرّب من القيود)
  for dt in select * from public.doc_types where id in ((rw ->> 'doc_type_id')::uuid, (o ->> 'doc_type_id')::uuid) loop
    if dt.date_today and tg_op <> 'DELETE' and (tg_op = 'INSERT' or d is distinct from od or (rw ->> 'doc_type_id') is distinct from (o ->> 'doc_type_id'))
       and d <> public.local_today() then
      raise exception 'نوع السند «%»: التاريخ لازم يكون تاريخ اليوم', dt.name;
    end if;
    if dt.edit_days is not null and tg_op <> 'INSERT' and (tg_op = 'DELETE' or (o ->> 'status') is not distinct from (rw ->> 'status'))
       and ((o ->> 'created_at')::timestamptz at time zone 'Asia/Amman')::date < public.local_today() - dt.edit_days then
      raise exception 'نوع السند «%»: انتهت مدة التعديل/الحذف (% يوم)', dt.name, dt.edit_days;
    end if;
    if dt.lock_dept and tg_op <> 'DELETE' and (rw ->> 'department_id') is not null then
      select department_id into ud from public.user_companies where user_id = auth.uid() and company_id = co;
      if ud is not null and (rw ->> 'department_id')::uuid <> ud then
        raise exception 'نوع السند «%»: الدائرة مقفولة على دائرتك', dt.name;
      end if;
    end if;
  end loop;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists a1_doc_type on public.journal_entries;
create trigger a1_doc_type before insert or update or delete on public.journal_entries for each row execute function public.a1_doc_type();
drop trigger if exists a1_doc_type on public.invoices;
create trigger a1_doc_type before insert or update or delete on public.invoices for each row execute function public.a1_doc_type();
drop trigger if exists a1_doc_type on public.stock_docs;
create trigger a1_doc_type before insert or update or delete on public.stock_docs for each row execute function public.a1_doc_type();


-- سطور المستند: مدة التعديل تبع نوع المستند
create or replace function public.a1_doc_type_lines() returns trigger
language plpgsql security definer set search_path = public as $$
declare rw jsonb := to_jsonb(case when tg_op = 'DELETE' then old else new end); hid uuid; h jsonb; dt public.doc_types; co uuid;
begin
  if public.is_internal() then return case when tg_op = 'DELETE' then old else new end; end if;
  hid := coalesce(rw ->> 'entry_id', rw ->> 'invoice_id', rw ->> 'doc_id')::uuid;
  h := case tg_table_name when 'journal_lines' then (select to_jsonb(x) from public.journal_entries x where x.id = hid)
                          when 'invoice_lines' then (select to_jsonb(x) from public.invoices x where x.id = hid)
                          else (select to_jsonb(x) from public.stock_docs x where x.id = hid) end;
  if h is null or h ->> 'doc_type_id' is null or h ->> 'status' <> 'draft' then return case when tg_op = 'DELETE' then old else new end; end if;
  co := (h ->> 'company_id')::uuid;
  if public.is_admin() or public.can(co, 'doc_types', 'edit') then return case when tg_op = 'DELETE' then old else new end; end if;
  select * into dt from public.doc_types where id = (h ->> 'doc_type_id')::uuid;
  if dt.edit_days is not null and ((h ->> 'created_at')::timestamptz at time zone 'Asia/Amman')::date < public.local_today() - dt.edit_days then
    raise exception 'نوع السند «%»: انتهت مدة التعديل/الحذف (% يوم)', dt.name, dt.edit_days;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists a1_doc_type_lines on public.journal_lines;
create trigger a1_doc_type_lines before insert or update or delete on public.journal_lines for each row execute function public.a1_doc_type_lines();
drop trigger if exists a1_doc_type_lines on public.invoice_lines;
create trigger a1_doc_type_lines before insert or update or delete on public.invoice_lines for each row execute function public.a1_doc_type_lines();
drop trigger if exists a1_doc_type_lines on public.stock_doc_lines;
create trigger a1_doc_type_lines before insert or update or delete on public.stock_doc_lines for each row execute function public.a1_doc_type_lines();

-- ما بينحذف نوع عليه مستندات (FK restrict)، والافتراضي ما بينوقف
create or replace function public.ab_doc_type_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.is_default and not new.is_active then raise exception 'النوع الافتراضي ما بينوقف؛ خلّي نوع ثاني افتراضي أول'; end if;
  if new.is_default and (tg_op = 'INSERT' or not old.is_default) then
    update public.doc_types set is_default = false where company_id = new.company_id and kind = new.kind and is_default and id <> new.id;
  end if;
  if tg_op = 'UPDATE' and (new.kind <> old.kind or new.company_id <> old.company_id) then raise exception 'ما بتقدر تغيّر نوع المستند'; end if;
  return new;
end $$;
drop trigger if exists ab_doc_type_guard on public.doc_types;
create trigger ab_doc_type_guard before insert or update on public.doc_types for each row execute function public.ab_doc_type_guard();

revoke execute on function public.ensure_doc_types(uuid) from public, anon;
grant execute on function public.ensure_doc_types(uuid) to authenticated;

-- تعبئة المستندات الموجودة بالنوع الافتراضي (مرة وحدة)
do $$
declare c record;
begin
  if exists (select 1 from public.journal_entries where doc_type_id is null and entry_type in ('journal','opening','receipt','payment'))
     or exists (select 1 from public.invoices where doc_type_id is null) or exists (select 1 from public.stock_docs where doc_type_id is null) then
    perform set_config('sumou.internal', public.internal_token(), true);
    alter table public.journal_entries disable trigger user; alter table public.invoices disable trigger user; alter table public.stock_docs disable trigger user;
    for c in select id from public.companies loop
      update public.journal_entries set doc_type_id = public.doc_type_default(c.id, entry_type) where company_id = c.id and doc_type_id is null and entry_type in ('journal','opening','receipt','payment');
      update public.invoices set doc_type_id = public.doc_type_default(c.id, inv_type) where company_id = c.id and doc_type_id is null;
      update public.stock_docs set doc_type_id = public.doc_type_default(c.id, 'stock_' || doc_type) where company_id = c.id and doc_type_id is null;
    end loop;
    alter table public.journal_entries enable trigger user; alter table public.invoices enable trigger user; alter table public.stock_docs enable trigger user;
    perform set_config('sumou.internal', '', true);
  end if;
end $$;

-- الترقيم: تسلسل وبادئة حسب نوع السند
create or replace function public.aa_number_entries() returns trigger
language plpgsql security definer set search_path = public as $$
declare dt record; r jsonb; sp uuid; spc text; fy uuid; k text; co uuid; ty text; chg boolean := false; intl boolean := public.is_internal();
begin
  if tg_op = 'UPDATE' then co := old.company_id; ty := old.entry_type; else co := new.company_id; ty := new.entry_type; end if;
  r := public.numbering_rule(co, case when ty in ('journal','receipt','payment') then ty end);
  fy := new.fiscal_year_id;
  k := public.numbering_key(r, new.entry_date, fy, sp);
  -- نوع السند: تسلسل وبادئة لحاله
  select t.own_seq, t.prefix, t.id into dt from public.doc_types t where t.id = new.doc_type_id;
  if dt.own_seq then
    k := concat_ws('|', nullif(k, ''), 'T' || dt.id);
    if coalesce(dt.prefix, '') <> '' then r := r || jsonb_build_object('prefix', left(regexp_replace(dt.prefix, '[<>"''&]', '', 'g'), 15)); end if;
  end if;
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
    if old.status = 'draft' and (new.doc_type_id is distinct from old.doc_type_id or new.entry_date is distinct from old.entry_date or new.fiscal_year_id is distinct from old.fiscal_year_id) and k is distinct from old.seq_key then
      -- المسودة انتقلت لشهر/سنة/فرع ثاني: بتاخذ رقم من التسلسل الجديد
      new.seq_key := k; if new.entry_no = old.entry_no or (not intl and r->>'mode' = 'auto') then new.entry_no := null; end if; chg := true;
    elsif new.entry_no <> old.entry_no then
      if not intl and r->>'mode' = 'auto' then new.entry_no := old.entry_no; else chg := true; end if;
    elsif old.status = 'draft' and (new.doc_type_id is distinct from old.doc_type_id or new.entry_date is distinct from old.entry_date or new.fiscal_year_id is distinct from old.fiscal_year_id) then chg := true;
    end if;
    if not chg then new.doc_code := old.doc_code; return new; end if;
  end if;
  if new.entry_no is not null and (new.entry_no <= 0 or new.entry_no > 999999999) then raise exception 'رقم المستند لازم يكون بين 1 و 999999999'; end if;
  perform pg_advisory_xact_lock(hashtext('je|' || co || '|' || ty));   -- قفل على النوع كله (التسلسلات الخاصة بتشارك فحص تكرار الرقم المنسّق)
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

create or replace function public.aa_number_invoices() returns trigger
language plpgsql security definer set search_path = public as $$
declare dt record; r jsonb; sp uuid; spc text; fy uuid; k text; co uuid; ty text; chg boolean := false; intl boolean := public.is_internal();
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
  -- نوع السند: تسلسل وبادئة لحاله
  select t.own_seq, t.prefix, t.id into dt from public.doc_types t where t.id = new.doc_type_id;
  if dt.own_seq then
    k := concat_ws('|', nullif(k, ''), 'T' || dt.id);
    if coalesce(dt.prefix, '') <> '' then r := r || jsonb_build_object('prefix', left(regexp_replace(dt.prefix, '[<>"''&]', '', 'g'), 15)); end if;
  end if;
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
    if old.status = 'draft' and (new.doc_type_id is distinct from old.doc_type_id or new.inv_date is distinct from old.inv_date or new.fiscal_year_id is distinct from old.fiscal_year_id or new.cost_center_id is distinct from old.cost_center_id or new.warehouse_id is distinct from old.warehouse_id) and k is distinct from old.seq_key then
      -- المسودة انتقلت لشهر/سنة/فرع ثاني: بتاخذ رقم من التسلسل الجديد
      new.seq_key := k; if new.inv_no = old.inv_no or (not intl and r->>'mode' = 'auto') then new.inv_no := null; end if; chg := true;
    elsif new.inv_no <> old.inv_no then
      if not intl and r->>'mode' = 'auto' then new.inv_no := old.inv_no; else chg := true; end if;
    elsif old.status = 'draft' and (new.doc_type_id is distinct from old.doc_type_id or new.inv_date is distinct from old.inv_date or new.fiscal_year_id is distinct from old.fiscal_year_id or new.cost_center_id is distinct from old.cost_center_id or new.warehouse_id is distinct from old.warehouse_id) then chg := true;
    end if;
    if not chg then new.doc_code := old.doc_code; return new; end if;
  end if;
  if new.inv_no is not null and (new.inv_no <= 0 or new.inv_no > 999999999) then raise exception 'رقم الفاتورة لازم يكون بين 1 و 999999999'; end if;
  perform pg_advisory_xact_lock(hashtext('inv|' || co || '|' || ty));   -- قفل على النوع كله (التسلسلات الخاصة بتشارك فحص تكرار الرقم المنسّق)
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

create or replace function public.aa_number_stock() returns trigger
language plpgsql security definer set search_path = public as $$
declare dt record; r jsonb; sp uuid; spc text; fy uuid; k text; co uuid; ty text; chg boolean := false; intl boolean := public.is_internal();
begin
  if tg_op = 'UPDATE' then co := old.company_id; ty := old.doc_type; else co := new.company_id; ty := new.doc_type; end if;
  r := public.numbering_rule(co, 'stock_' || ty);
  sp := case when r->>'split' = 'warehouse' then new.warehouse_id end;
  if sp is not null then select code into spc from public.warehouses where id = sp and company_id = co; end if;
  select id into fy from public.fiscal_years where company_id = co and new.doc_date between start_date and end_date order by start_date desc limit 1;
  if fy is null and r->>'reset' <> 'none' and not public.is_internal() then raise exception 'ما في سنة مالية بتاريخ السند، والترقيم بيبدأ من جديد كل سنة/شهر'; end if;
  k := public.numbering_key(r, new.doc_date, fy, sp);
  -- نوع السند: تسلسل وبادئة لحاله
  select t.own_seq, t.prefix, t.id into dt from public.doc_types t where t.id = new.doc_type_id;
  if dt.own_seq then
    k := concat_ws('|', nullif(k, ''), 'T' || dt.id);
    if coalesce(dt.prefix, '') <> '' then r := r || jsonb_build_object('prefix', left(regexp_replace(dt.prefix, '[<>"''&]', '', 'g'), 15)); end if;
  end if;
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
    if old.status = 'draft' and (new.doc_type_id is distinct from old.doc_type_id or new.doc_date is distinct from old.doc_date or new.warehouse_id is distinct from old.warehouse_id) and k is distinct from old.seq_key then
      -- المسودة انتقلت لشهر/سنة/فرع ثاني: بتاخذ رقم من التسلسل الجديد
      new.seq_key := k; if new.doc_no = old.doc_no or (not intl and r->>'mode' = 'auto') then new.doc_no := null; end if; chg := true;
    elsif new.doc_no <> old.doc_no then
      if not intl and r->>'mode' = 'auto' then new.doc_no := old.doc_no; else chg := true; end if;
    elsif old.status = 'draft' and (new.doc_type_id is distinct from old.doc_type_id or new.doc_date is distinct from old.doc_date or new.warehouse_id is distinct from old.warehouse_id) then chg := true;
    end if;
    if not chg then new.doc_code := old.doc_code; return new; end if;
  end if;
  if new.doc_no is not null and (new.doc_no <= 0 or new.doc_no > 999999999) then raise exception 'رقم السند لازم يكون بين 1 و 999999999'; end if;
  perform pg_advisory_xact_lock(hashtext('sd|' || co || '|' || ty));   -- قفل على النوع كله (التسلسلات الخاصة بتشارك فحص تكرار الرقم المنسّق)
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


-- عمولة وسيلة الدفع (فيزا…): rate = النسبة %، والعمولة بتنقيّد على commission_account_id بسند القبض
alter table public.lookups add column if not exists commission_account_id uuid references public.accounts(id) on delete set null;
create or replace function public.ad_lookup_commission_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.commission_account_id is not null then
    if new.kind <> 'payment_method' then new.commission_account_id := null; return new; end if;
    if not exists (select 1 from public.accounts where id = new.commission_account_id and company_id = new.company_id and not is_group) then
      raise exception 'حساب العمولة لازم يكون حساب فرعي من نفس الشركة';
    end if;
    if coalesce(new.rate, 0) < 0 or coalesce(new.rate, 0) > 20 then raise exception 'نسبة العمولة من 0 لـ 20%%'; end if;
  end if;
  return new;
end $$;
drop trigger if exists ad_lookup_commission_check on public.lookups;
create trigger ad_lookup_commission_check before insert or update on public.lookups for each row execute function public.ad_lookup_commission_check();

-- النسخة الاحتياطية: أنواع السندات قبل المستندات
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1, 'companies', 'id = $1', 'code'),
   (2, 'fiscal_years', 'company_id = $1', 'start_date'),
   (3, 'accounts', 'company_id = $1', 'level, code'),
   (4, 'cost_centers', 'company_id = $1', 'code'),
   (5, 'currencies', 'company_id = $1', 'code'),
   (6, 'company_settings', 'company_id = $1', 'company_id'),
   (7, 'lookups', 'company_id = $1', 'parent_id nulls first, kind, code'),
   (8, 'custom_fields', 'company_id = $1', 'entity, sort'),
   (9, 'party_categories', 'company_id = $1', 'party_type, code'),
   (10, 'parties', 'company_id = $1', 'code'),
   (11, 'sales_visits', 'company_id = $1', 'started_at'),
   (12, 'item_categories', 'company_id = $1', 'code'),
   (13, 'items', 'company_id = $1', 'code'),
   (14, 'promotions', 'company_id = $1', 'date_from'),
   (15, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (16, 'warehouses', 'company_id = $1', 'code'),
   (17, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (18, 'departments', 'company_id = $1', 'level, code'),
   (19, 'doc_types', 'company_id = $1', 'kind, code'),
   (20, 'boms', 'company_id = $1', 'code'),
   (21, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (22, 'journal_entries', 'company_id = $1', 'created_at'),
   (23, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (24, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (25, 'invoices', 'company_id = $1', 'created_at'),
   (26, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (27, 'orders', 'company_id = $1', 'created_at'),
   (28, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (29, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (30, 'cheques', 'company_id = $1', 'created_at'),
   (31, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (32, 'supply_requests', 'company_id = $1', 'req_no'),
   (33, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (34, 'stock_docs', 'company_id = $1', 'created_at'),
   (35, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (36, 'stock_moves', 'company_id = $1', 'created_at'),
   (37, 'productions', 'company_id = $1', 'prod_no'),
   (38, 'obligations', 'company_id = $1', 'due_date'),
   (39, 'recurring_entries', 'company_id = $1', 'created_at'),
   (40, 'work_locations', 'company_id = $1', 'name'),
   (41, 'employees', 'company_id = $1', 'code'),
   (42, 'attendance', 'company_id = $1', 'day, employee_id'),
   (43, 'payroll_runs', 'company_id = $1', 'period'),
   (44, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (45, 'employee_loans', 'company_id = $1', 'loan_no'),
   (46, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (47, 'asset_custodians', 'company_id = $1', 'code'),
   (48, 'fixed_assets', 'company_id = $1', 'code'),
   (49, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (50, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (51, 'asset_movements', 'company_id = $1', 'mov_no'),
   (52, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (53, 'custody_docs', 'company_id = $1', 'doc_no'),
   (54, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (55, 'bank_recons', 'company_id = $1', 'created_at'),
   (56, 'bank_cleared', 'company_id = $1', 'line_id'),
   (57, 'attachments', 'company_id = $1', 'created_at'),
   (58, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
