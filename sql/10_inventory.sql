-- =====================================================================
--  نظام السمو ERP — المخزون والجرد (كميات)
--  مستودعات، حركات تلقائية من الفواتير المرحّلة، سندات إدخال/إخراج/تحويل/جرد،
--  رصيد الأصناف ومتوسط الكلفة. (المحاسبة على المخزون بطريقة الجرد الدوري:
--  المشتريات بتنقيّد مصروف، وقيمة المخزون آخر المدة من تقرير الجرد.)
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

create table if not exists public.warehouses (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code       text not null,
  name       text not null,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, code)
);

alter table public.items add column if not exists track_stock boolean not null default true;
alter table public.invoices add column if not exists warehouse_id uuid references public.warehouses(id) on delete set null;

create table if not exists public.stock_docs (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  doc_type        text not null check (doc_type in ('in','out','transfer','count')),
  doc_no          int,
  doc_date        date not null default current_date,
  warehouse_id    uuid not null references public.warehouses(id) on delete restrict,
  to_warehouse_id uuid references public.warehouses(id) on delete restrict,
  status          text not null default 'draft' check (status in ('draft','posted')),
  notes           text,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  unique (company_id, doc_type, doc_no)
);

create table if not exists public.stock_doc_lines (
  id         uuid primary key default gen_random_uuid(),
  doc_id     uuid not null references public.stock_docs(id) on delete cascade,
  line_no    int not null default 1,
  item_id    uuid not null references public.items(id) on delete restrict,
  qty        numeric(18,3) not null default 0,        -- للإدخال/الإخراج/التحويل
  counted_qty numeric(18,3),                          -- للجرد: الكمية الفعلية
  unit_cost  numeric(18,3) not null default 0,
  note       text
);

create table if not exists public.stock_moves (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  item_id      uuid not null references public.items(id) on delete restrict,
  warehouse_id uuid not null references public.warehouses(id) on delete restrict,
  move_date    date not null,
  qty          numeric(18,3) not null,              -- موجب = داخل، سالب = خارج
  unit_cost    numeric(18,3) not null default 0,
  source_type  text not null,                       -- invoice, stock_doc
  source_id    uuid not null,
  description  text,
  created_at   timestamptz not null default now()
);
create index if not exists stock_moves_item_idx on public.stock_moves (company_id, item_id, warehouse_id, move_date);

-- مستودع رئيسي تلقائي لكل شركة
create or replace function public.default_warehouse(p_company uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare w uuid;
begin
  if not public.has_company(p_company) then raise exception 'ما عندك صلاحية'; end if;
  select id into w from public.warehouses where company_id = p_company and is_active order by code limit 1;
  if w is null then
    insert into public.warehouses (company_id, code, name) values (p_company, '1', 'المستودع الرئيسي') returning id into w;
  end if;
  return w;
end $$;

-- حركات المخزون من الفاتورة لما تترحّل أو تنلغى
create or replace function public.invoice_stock_moves() returns trigger
language plpgsql security definer set search_path = public as $$
declare w uuid; sgn int;
begin
  if not (old.status = 'draft' and new.status = 'posted') and not (old.status = 'posted' and new.status = 'cancelled') then return null; end if;
  sgn := case when new.inv_type in ('purchase','sale_return') then 1 else -1 end;
  if new.status = 'cancelled' then
    insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
    select company_id, item_id, warehouse_id, current_date, -qty, unit_cost, 'invoice_cancel', source_id, 'إلغاء: ' || coalesce(description, '')
    from public.stock_moves where source_type = 'invoice' and source_id = new.id;
    return null;
  end if;
  w := coalesce(new.warehouse_id, public.default_warehouse(new.company_id));
  insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
  select new.company_id, l.item_id, w, new.inv_date, sgn * l.qty,
         case when l.qty > 0 then round(l.subtotal / l.qty, 3) else 0 end, 'invoice', new.id,
         case new.inv_type when 'sale' then 'فاتورة بيع ' when 'sale_return' then 'مرتجع بيع ' when 'purchase' then 'فاتورة شراء ' else 'مرتجع شراء ' end || new.inv_no
  from public.invoice_lines l join public.items it on it.id = l.item_id
  where l.invoice_id = new.id and it.item_type = 'goods' and it.track_stock;
  return null;
end $$;
drop trigger if exists invoice_stock_moves on public.invoices;
create trigger invoice_stock_moves after update of status on public.invoices
  for each row execute function public.invoice_stock_moves();

-- ترقيم وحماية سندات المخزون
create or replace function public.stock_docs_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if old.status = 'posted' then raise exception 'السند مرحّل، ما بينحذف'; end if; return old;
  end if;
  if not public.is_internal() then
    if tg_op = 'UPDATE' and old.status = 'posted' then raise exception 'السند مرحّل، ما بينعدّل'; end if;
    if new.status <> 'draft' then raise exception 'الترحيل من زر «ترحيل» بس'; end if;
  end if;
  if not exists (select 1 from public.warehouses where id = new.warehouse_id and company_id = new.company_id) then raise exception 'المستودع مش لهالشركة'; end if;
  if new.doc_type = 'transfer' then
    if new.to_warehouse_id is null or new.to_warehouse_id = new.warehouse_id
       or not exists (select 1 from public.warehouses where id = new.to_warehouse_id and company_id = new.company_id) then
      raise exception 'اختار مستودع التحويل (غير المستودع الأصلي)';
    end if;
  end if;
  if tg_op = 'INSERT' and new.doc_no is null then
    select coalesce(max(doc_no), 0) + 1 into new.doc_no from public.stock_docs where company_id = new.company_id and doc_type = new.doc_type;
  end if;
  if tg_op = 'UPDATE' then new.company_id := old.company_id; new.doc_type := old.doc_type; end if;
  return new;
end $$;
drop trigger if exists stock_docs_before on public.stock_docs;
create trigger stock_docs_before before insert or update or delete on public.stock_docs
  for each row execute function public.stock_docs_before();

create or replace function public.stock_lines_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare d public.stock_docs;
begin
  if tg_op in ('UPDATE','DELETE') then
    select * into d from public.stock_docs where id = old.doc_id;
    if d.status = 'posted' and not public.is_internal() then raise exception 'السند مرحّل'; end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  select * into d from public.stock_docs where id = new.doc_id;
  if d.status = 'posted' and not public.is_internal() then raise exception 'السند مرحّل'; end if;
  if not exists (select 1 from public.items where id = new.item_id and company_id = d.company_id) then raise exception 'الصنف مش لهالشركة'; end if;
  return new;
end $$;
drop trigger if exists stock_lines_before on public.stock_doc_lines;
create trigger stock_lines_before before insert or update or delete on public.stock_doc_lines
  for each row execute function public.stock_lines_before();

-- رصيد صنف بمستودع لتاريخ
create or replace function public.stock_qty(p_item uuid, p_wh uuid, p_date date) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(m.qty), 0) from public.stock_moves m
  where m.item_id = p_item and m.warehouse_id = p_wh and m.move_date <= p_date and public.has_company(m.company_id);
$$;

-- ترحيل سند مخزون
create or replace function public.post_stock_doc(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d public.stock_docs; r record; n int; diff numeric; descr text;
begin
  select * into d from public.stock_docs where id = p_id for update;
  if d.id is null then raise exception 'السند غير موجود'; end if;
  if not public.can(d.company_id, 'inventory', 'post') then raise exception 'ما عندك صلاحية ترحيل سندات المخزون'; end if;
  if d.status <> 'draft' then raise exception 'السند مرحّل من قبل'; end if;
  select count(*) into n from public.stock_doc_lines where doc_id = p_id;
  if n = 0 then raise exception 'السند بدون أصناف'; end if;
  descr := case d.doc_type when 'in' then 'سند إدخال ' when 'out' then 'سند إخراج ' when 'transfer' then 'سند تحويل ' else 'جرد ' end || d.doc_no;
  for r in select * from public.stock_doc_lines where doc_id = p_id loop
    if d.doc_type = 'in' then
      if r.qty <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
      values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, r.qty, r.unit_cost, 'stock_doc', p_id, descr);
    elsif d.doc_type = 'out' then
      if r.qty <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
      values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, -r.qty, r.unit_cost, 'stock_doc', p_id, descr);
    elsif d.doc_type = 'transfer' then
      if r.qty <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
      values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, -r.qty, r.unit_cost, 'stock_doc', p_id, descr),
             (d.company_id, r.item_id, d.to_warehouse_id, d.doc_date, r.qty, r.unit_cost, 'stock_doc', p_id, descr);
    else   -- جرد: الفرق بين الفعلي والدفتري
      if r.counted_qty is null then continue; end if;
      diff := r.counted_qty - public.stock_qty(r.item_id, d.warehouse_id, d.doc_date);
      if abs(diff) > 0.0005 then
        insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
        values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, diff, r.unit_cost, 'stock_doc', p_id, descr || ' (تسوية)');
      end if;
      perform set_config('sumou.internal', public.internal_token(), true);
      update public.stock_doc_lines set qty = diff where id = r.id;
    end if;
  end loop;
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.stock_docs set status = 'posted' where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), d.company_id, 'ترحيل', 'inventory', p_id::text, jsonb_build_object('doc', descr));
end $$;

-- رصيد المخزون: الكمية ومتوسط كلفة الوارد والقيمة
create or replace function public.rep_stock_balance(p_company uuid, p_date date, p_wh uuid default null)
returns table (item_id uuid, warehouse_id uuid, qty numeric, avg_cost numeric, value numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'inventory', 'view') then raise exception 'ما عندك صلاحية على المخزون'; end if;
  return query
  with m as (select sm.* from public.stock_moves sm where sm.company_id = p_company and sm.move_date <= p_date and (p_wh is null or sm.warehouse_id = p_wh)),
  c as (select m2.item_id, case when sum(m2.qty) filter (where m2.qty > 0 and m2.unit_cost > 0) > 0
                             then sum(m2.qty * m2.unit_cost) filter (where m2.qty > 0 and m2.unit_cost > 0) / sum(m2.qty) filter (where m2.qty > 0 and m2.unit_cost > 0)
                             else 0 end as ac
        from public.stock_moves m2 where m2.company_id = p_company and m2.move_date <= p_date group by m2.item_id)
  select m.item_id, m.warehouse_id, sum(m.qty), round(coalesce(max(c.ac), 0), 3), round(sum(m.qty) * coalesce(max(c.ac), 0), 3)
  from m left join c on c.item_id = m.item_id
  group by m.item_id, m.warehouse_id having abs(sum(m.qty)) > 0.0005;
end $$;

-- بطاقة صنف
create or replace function public.rep_item_card(p_company uuid, p_item uuid, p_from date, p_to date, p_wh uuid default null)
returns table (move_date date, warehouse_id uuid, qty numeric, unit_cost numeric, description text, opening numeric)
language plpgsql stable security definer set search_path = public as $$
declare ob numeric;
begin
  if not public.can(p_company, 'inventory', 'view') then raise exception 'ما عندك صلاحية على المخزون'; end if;
  select coalesce(sum(m.qty), 0) into ob from public.stock_moves m where m.company_id = p_company and m.item_id = p_item and m.move_date < p_from and (p_wh is null or m.warehouse_id = p_wh);
  return query select null::date, null::uuid, 0::numeric, null::numeric, 'رصيد أول المدة'::text, ob;
  return query
  select m.move_date, m.warehouse_id, m.qty, m.unit_cost, m.description, ob
  from public.stock_moves m where m.company_id = p_company and m.item_id = p_item and m.move_date between p_from and p_to and (p_wh is null or m.warehouse_id = p_wh)
  order by m.move_date, m.created_at;
end $$;

alter table public.warehouses enable row level security;
alter table public.stock_docs enable row level security;
alter table public.stock_doc_lines enable row level security;
alter table public.stock_moves enable row level security;

drop policy if exists wh_select on public.warehouses;
create policy wh_select on public.warehouses for select to authenticated using (public.has_company(company_id));
drop policy if exists wh_write on public.warehouses;
create policy wh_write on public.warehouses for all to authenticated
  using (public.can(company_id, 'inventory', 'edit')) with check (public.can(company_id, 'inventory', 'edit'));

drop policy if exists sd_select on public.stock_docs;
create policy sd_select on public.stock_docs for select to authenticated using (public.can(company_id, 'inventory', 'view'));
drop policy if exists sd_insert on public.stock_docs;
create policy sd_insert on public.stock_docs for insert to authenticated with check (public.can(company_id, 'inventory', 'add'));
drop policy if exists sd_update on public.stock_docs;
create policy sd_update on public.stock_docs for update to authenticated
  using (public.can(company_id, 'inventory', 'edit')) with check (public.can(company_id, 'inventory', 'edit'));
drop policy if exists sd_delete on public.stock_docs;
create policy sd_delete on public.stock_docs for delete to authenticated using (public.can(company_id, 'inventory', 'delete'));

drop policy if exists sdl_all on public.stock_doc_lines;
create policy sdl_all on public.stock_doc_lines for all to authenticated
  using (exists (select 1 from public.stock_docs d where d.id = doc_id and public.can(d.company_id, 'inventory', 'view')))
  with check (exists (select 1 from public.stock_docs d where d.id = doc_id and (public.can(d.company_id, 'inventory', 'add') or public.can(d.company_id, 'inventory', 'edit'))));

drop policy if exists sm_select on public.stock_moves;
create policy sm_select on public.stock_moves for select to authenticated using (public.can(company_id, 'inventory', 'view'));

grant select, insert, update, delete on public.warehouses, public.stock_docs, public.stock_doc_lines to authenticated;
grant select on public.stock_moves to authenticated;
grant execute on function public.post_stock_doc(uuid), public.rep_stock_balance(uuid, date, uuid), public.rep_item_card(uuid, uuid, date, date, uuid),
  public.default_warehouse(uuid), public.stock_qty(uuid, uuid, date) to authenticated;

update public.user_groups set permissions = permissions || '{"inventory":{"view":true,"add":true,"edit":true,"print":true,"post":true}}'::jsonb
 where name = 'محاسب' and not (permissions ? 'inventory');
update public.user_groups set permissions = permissions || '{"inventory":{"view":true,"add":true,"edit":true}}'::jsonb
 where name = 'مدخل بيانات' and not (permissions ? 'inventory');
update public.user_groups set permissions = permissions || '{"inventory":{"view":true,"print":true}}'::jsonb
 where name = 'مشاهد' and not (permissions ? 'inventory');

-- انتهى ✅
