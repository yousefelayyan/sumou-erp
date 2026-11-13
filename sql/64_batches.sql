-- =====================================================================
--  السمو ERP — المرحلة 64: الدفعات وتواريخ الانتهاء
--  items.batch_mode = none | batch (رقم دفعة) | expiry (دفعة + تاريخ انتهاء).
--  invoice_lines / stock_doc_lines: batch_no, expiry_date (المستخدم بيكتبهم بالسطر).
--  item_batches: دفعات الصنف (بتنعمل لحالها من سطر داخل). batch_moves: دفتر الدفعات لكل مستودع،
--  بيتولّد لحاله لما المستند يترحّل للمخزون (ما بيلمس حركات المخزون والكلفة)، وبينمسح بإلغاء ترحيل المخزون،
--  وإلغاء الفاتورة بيعكسه. الطالع بدون رقم دفعة بياخذ الأقرب انتهاء أول (FEFO)، والبيع بيتخطّى المنتهي؛
--  الزايد عن الدفعات بيضل «بدون دفعة». الطالع برقم دفعة لازم يكون رصيدها كافي.
--  company_settings.expiry_warn_days (60)، block_expired_sale (منع بيع دفعة منتهية برقمها).
-- =====================================================================
alter table public.items add column if not exists batch_mode text not null default 'none';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'items_batch_mode_chk') then
    alter table public.items add constraint items_batch_mode_chk check (batch_mode in ('none','batch','expiry'));
  end if;
end $$;
alter table public.invoice_lines   add column if not exists batch_no text;
alter table public.invoice_lines   add column if not exists expiry_date date;
alter table public.stock_doc_lines add column if not exists batch_no text;
alter table public.stock_doc_lines add column if not exists expiry_date date;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'invoice_lines_batch_len') then
    alter table public.invoice_lines add constraint invoice_lines_batch_len check (batch_no is null or length(batch_no) <= 60);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'stock_doc_lines_batch_len') then
    alter table public.stock_doc_lines add constraint stock_doc_lines_batch_len check (batch_no is null or length(batch_no) <= 60);
  end if;
end $$;
alter table public.company_settings add column if not exists expiry_warn_days int not null default 60;
alter table public.company_settings add column if not exists block_expired_sale boolean not null default false;

create table if not exists public.item_batches (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  item_id     uuid not null references public.items(id) on delete cascade,
  batch_no    text not null check (length(batch_no) between 1 and 60),
  expiry_date date,
  mfg_date    date,
  notes       text,
  created_at  timestamptz not null default now(),
  unique (company_id, item_id, batch_no)
);
create table if not exists public.batch_moves (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  item_id      uuid not null references public.items(id) on delete restrict,
  warehouse_id uuid not null references public.warehouses(id) on delete restrict,
  batch_id     uuid references public.item_batches(id) on delete restrict,
  move_date    date not null,
  qty          numeric(18,3) not null,
  source_type  text not null,     -- invoice, invoice_cancel, stock_doc
  source_id    uuid not null,
  line_id      uuid,
  created_at   timestamptz not null default now()
);
create index if not exists batch_moves_bal_idx on public.batch_moves (company_id, item_id, warehouse_id, batch_id);
create index if not exists batch_moves_src_idx on public.batch_moves (source_type, source_id);
grant select, update on public.item_batches to authenticated;
grant select on public.batch_moves to authenticated;

alter table public.item_batches enable row level security;
alter table public.batch_moves enable row level security;
drop policy if exists item_batches_sel on public.item_batches;
create policy item_batches_sel on public.item_batches for select using (public.has_company(company_id));
drop policy if exists item_batches_upd on public.item_batches;
create policy item_batches_upd on public.item_batches for update
  using (public.can(company_id, 'inventory', 'edit') and public.tenant_writable())
  with check (public.can(company_id, 'inventory', 'edit') and public.tenant_writable());
drop policy if exists batch_moves_sel on public.batch_moves;
create policy batch_moves_sel on public.batch_moves for select
  using (public.can(company_id, 'inventory', 'view') or public.can(company_id, 'items', 'view'));

-- تعديل الدفعة: بس التواريخ والملاحظات
create or replace function public.ab_item_batch_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  new.company_id := old.company_id; new.item_id := old.item_id; new.batch_no := old.batch_no; new.created_at := old.created_at;
  return new;
end $$;
drop trigger if exists ab_item_batch_guard on public.item_batches;
create trigger ab_item_batch_guard before update on public.item_batches for each row execute function public.ab_item_batch_guard();

-- الدفعة حسب رقمها (بتنعمل إذا مش موجودة)
create or replace function public.batch_get(p_company uuid, p_item uuid, p_no text, p_exp date) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid; ex date; n text := nullif(trim(coalesce(p_no, '')), '');
begin
  if n is null then return null; end if;
  select id, expiry_date into v, ex from public.item_batches where company_id = p_company and item_id = p_item and batch_no = n;
  if v is not null then
    if p_exp is not null and ex is not null and ex <> p_exp then
      raise exception 'الدفعة «%» مسجّلة من قبل بتاريخ انتهاء % (مش %) — صحّح التاريخ أو استعمل رقم دفعة ثاني', n, ex, p_exp; end if;
    if ex is null and p_exp is not null then update public.item_batches set expiry_date = p_exp where id = v; end if;
    return v;
  end if;
  insert into public.item_batches (company_id, item_id, batch_no, expiry_date) values (p_company, p_item, n, p_exp)
  on conflict (company_id, item_id, batch_no) do update set batch_no = excluded.batch_no
  returning id into v;
  return v;
end $$;

-- طالع من مستودع: برقم الدفعة، أو الأقرب انتهاء أول
create or replace function public.batch_out(p_company uuid, p_item uuid, p_wh uuid, p_date date, p_qty numeric, p_no text,
  p_src_type text, p_src uuid, p_line uuid, p_sale boolean)
returns table (o_batch uuid, o_qty numeric)
language plpgsql security definer set search_path = public as $$
declare b public.item_batches; bal numeric; rem numeric := p_qty; take numeric; r record; n text := nullif(trim(coalesce(p_no, '')), '');
        it text; blk boolean;
begin
  perform pg_advisory_xact_lock(hashtext('batch:' || p_item::text || ':' || p_wh::text));
  if n is not null then
    select * into b from public.item_batches where company_id = p_company and item_id = p_item and batch_no = n;
    select name into it from public.items where id = p_item;
    if b.id is null then raise exception 'الدفعة «%» مش موجودة للصنف %', n, it; end if;
    select coalesce(sum(qty), 0) into bal from public.batch_moves where company_id = p_company and batch_id = b.id and warehouse_id = p_wh;
    if bal < p_qty - 0.0005 then raise exception 'الدفعة «%» من الصنف % فيها % بس بالمستودع', n, it, bal; end if;
    select block_expired_sale into blk from public.company_settings where company_id = p_company;
    if p_sale and coalesce(blk, false) and b.expiry_date is not null and b.expiry_date < p_date then
      raise exception 'الدفعة «%» من الصنف % منتهية بتاريخ %', n, it, b.expiry_date; end if;
    insert into public.batch_moves (company_id, item_id, warehouse_id, batch_id, move_date, qty, source_type, source_id, line_id)
    values (p_company, p_item, p_wh, b.id, p_date, -p_qty, p_src_type, p_src, p_line);
    o_batch := b.id; o_qty := p_qty; return next; return;
  end if;
  for r in select ib.id, sum(m.qty) bal from public.item_batches ib join public.batch_moves m on m.batch_id = ib.id and m.warehouse_id = p_wh and m.company_id = p_company
            where ib.company_id = p_company and ib.item_id = p_item and (not p_sale or ib.expiry_date is null or ib.expiry_date >= p_date)
            group by ib.id, ib.expiry_date, ib.created_at having sum(m.qty) > 0.0005
            order by ib.expiry_date nulls last, ib.created_at loop
    exit when rem <= 0.0005;
    take := least(rem, r.bal);
    insert into public.batch_moves (company_id, item_id, warehouse_id, batch_id, move_date, qty, source_type, source_id, line_id)
    values (p_company, p_item, p_wh, r.id, p_date, -take, p_src_type, p_src, p_line);
    o_batch := r.id; o_qty := take; return next;
    rem := rem - take;
  end loop;
  if rem > 0.0005 then
    insert into public.batch_moves (company_id, item_id, warehouse_id, batch_id, move_date, qty, source_type, source_id, line_id)
    values (p_company, p_item, p_wh, null, p_date, -rem, p_src_type, p_src, p_line);
    o_batch := null; o_qty := rem; return next;
  end if;
end $$;

-- قبل مسح حركات مستند: ولا دفعة بتصير بالسالب (يعني ما طلع منها شي بعد ما دخلت بهالمستند)
create or replace function public.batch_unpost_check(p_src uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select m.batch_id, m.warehouse_id, b.batch_no, it.name,
                  (select coalesce(sum(x.qty), 0) from public.batch_moves x
                    where x.batch_id = m.batch_id and x.warehouse_id = m.warehouse_id and x.company_id = m.company_id and x.source_id <> p_src) rest
             from public.batch_moves m join public.item_batches b on b.id = m.batch_id join public.items it on it.id = m.item_id
            where m.source_id = p_src and m.batch_id is not null
            group by m.batch_id, m.warehouse_id, m.company_id, b.batch_no, it.name having sum(m.qty) > 0 loop
    if r.rest < -0.0005 then
      raise exception 'ما بينفع: الدفعة «%» من الصنف % طلع منها بمستندات بعد هالمستند — ألغِ ترحيلها أول', r.batch_no, r.name;
    end if;
  end loop;
end $$;
revoke execute on function public.batch_unpost_check(uuid) from public, anon, authenticated;

-- حركة الدفعة لازم أصنافها ومستودعها ودفعتها من نفس الشركة
create or replace function public.ab_batch_move_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.items where id = new.item_id and company_id = new.company_id)
     or not exists (select 1 from public.warehouses where id = new.warehouse_id and company_id = new.company_id)
     or (new.batch_id is not null and not exists (select 1 from public.item_batches where id = new.batch_id and company_id = new.company_id and item_id = new.item_id)) then
    raise exception 'حركة دفعة مش من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists ab_batch_move_check on public.batch_moves;
create trigger ab_batch_move_check before insert or update on public.batch_moves for each row execute function public.ab_batch_move_check();
create or replace function public.ab_item_batch_co_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.items where id = new.item_id and company_id = new.company_id) then raise exception 'الصنف مش من نفس الشركة'; end if;
  return new;
end $$;
drop trigger if exists ab_item_batch_co_check on public.item_batches;
create trigger ab_item_batch_co_check before insert on public.item_batches for each row execute function public.ab_item_batch_co_check();
revoke execute on function public.ab_batch_move_check(), public.ab_item_batch_co_check() from public, anon, authenticated;

-- توليد دفتر الدفعات لمستند مرحّل للمخزون
create or replace function public.batch_sync(p_kind text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invoices; d public.stock_docs; r record; w uuid; a record; sgn int; bid uuid;
begin
  if p_kind = 'invoice' then
    select * into i from public.invoices where id = p_id;
    w := coalesce(i.warehouse_id, (select id from public.warehouses where company_id = i.company_id and is_active order by code limit 1));
    sgn := case when i.inv_type in ('purchase','sale_return') then 1 else -1 end;
    for r in select l.* from public.invoice_lines l join public.items it on it.id = l.item_id
              where l.invoice_id = p_id and it.item_type = 'goods' and it.track_stock and it.batch_mode <> 'none' order by l.line_no loop
      if sgn > 0 then
        bid := public.batch_get(i.company_id, r.item_id, r.batch_no, r.expiry_date);
        insert into public.batch_moves (company_id, item_id, warehouse_id, batch_id, move_date, qty, source_type, source_id, line_id)
        values (i.company_id, r.item_id, w, bid, i.inv_date, r.qty, 'invoice', p_id, r.id);
      else
        perform public.batch_out(i.company_id, r.item_id, w, i.inv_date, r.qty, r.batch_no, 'invoice', p_id, r.id, i.inv_type = 'sale');
      end if;
    end loop;
  else
    select * into d from public.stock_docs where id = p_id;
    if d.doc_type = 'in' and d.supply_request_id is not null then   -- إدخال طلب التزويد: نفس دفعات سند الإخراج
      insert into public.batch_moves (company_id, item_id, warehouse_id, batch_id, move_date, qty, source_type, source_id, line_id)
      select d.company_id, m.item_id, d.warehouse_id, m.batch_id, d.doc_date, -m.qty, 'stock_doc', p_id, null
        from public.batch_moves m join public.supply_requests q on q.id = d.supply_request_id
       where m.source_type = 'stock_doc' and m.source_id = q.out_doc_id and m.company_id = d.company_id and m.qty < 0;
      return;
    end if;
    for r in select l.* from public.stock_doc_lines l join public.items it on it.id = l.item_id
              where l.doc_id = p_id and it.item_type = 'goods' and it.track_stock and it.batch_mode <> 'none'
                and abs(l.qty) > 0.0005 order by l.line_no loop
      if d.doc_type = 'in' or (d.doc_type = 'count' and r.qty > 0) then
        bid := public.batch_get(d.company_id, r.item_id, r.batch_no, r.expiry_date);
        insert into public.batch_moves (company_id, item_id, warehouse_id, batch_id, move_date, qty, source_type, source_id, line_id)
        values (d.company_id, r.item_id, d.warehouse_id, bid, d.doc_date, abs(r.qty), 'stock_doc', p_id, r.id);
      else
        for a in select * from public.batch_out(d.company_id, r.item_id, d.warehouse_id, d.doc_date, abs(r.qty), r.batch_no, 'stock_doc', p_id, r.id, false) loop
          if d.doc_type = 'transfer' then
            insert into public.batch_moves (company_id, item_id, warehouse_id, batch_id, move_date, qty, source_type, source_id, line_id)
            values (d.company_id, r.item_id, d.to_warehouse_id, a.o_batch, d.doc_date, a.o_qty, 'stock_doc', p_id, r.id);
          end if;
        end loop;
      end if;
    end loop;
  end if;
end $$;
revoke execute on function public.batch_get(uuid, uuid, text, date), public.batch_out(uuid, uuid, uuid, date, numeric, text, text, uuid, uuid, boolean),
  public.batch_sync(text, uuid) from public, anon, authenticated;

create or replace function public.zb_invoice_batches() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not old.stock_posted and new.stock_posted then
    perform public.batch_sync('invoice', new.id);
  elsif old.stock_posted and not new.stock_posted then
    perform public.batch_unpost_check(new.id);
    delete from public.batch_moves where source_id = new.id and source_type in ('invoice', 'invoice_cancel');
  elsif old.status = 'posted' and new.status = 'cancelled' and new.stock_posted then
    perform public.batch_unpost_check(new.id);
    insert into public.batch_moves (company_id, item_id, warehouse_id, batch_id, move_date, qty, source_type, source_id, line_id)
    select company_id, item_id, warehouse_id, batch_id, coalesce((select entry_date from public.journal_entries where id = new.cancel_entry_id), current_date),
           -qty, 'invoice_cancel', source_id, line_id
      from public.batch_moves where source_type = 'invoice' and source_id = new.id;
  end if;
  return null;
end $$;
drop trigger if exists zb_invoice_batches on public.invoices;
create trigger zb_invoice_batches after update of status, stock_posted on public.invoices
  for each row execute function public.zb_invoice_batches();

create or replace function public.zb_stock_doc_batches() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'draft' and new.status = 'posted' then
    perform public.batch_sync('stock_doc', new.id);
  elsif old.status = 'posted' and new.status <> 'posted' then
    perform public.batch_unpost_check(new.id);
    delete from public.batch_moves where source_type = 'stock_doc' and source_id = new.id;
  end if;
  return null;
end $$;
drop trigger if exists zb_stock_doc_batches on public.stock_docs;
create trigger zb_stock_doc_batches after update of status on public.stock_docs
  for each row execute function public.zb_stock_doc_batches();
revoke execute on function public.zb_invoice_batches(), public.zb_stock_doc_batches() from public, anon, authenticated;

-- أرصدة الدفعات (للتقرير والاختيار بالسطر)
create or replace function public.batch_balances(p_company uuid, p_warehouse uuid default null, p_item uuid default null, p_all boolean default false)
returns table (item_id uuid, warehouse_id uuid, batch_id uuid, batch_no text, expiry_date date, qty numeric, days_left int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.can(p_company, 'inventory', 'view') or public.can(p_company, 'items', 'view')
          or public.can(p_company, 'sales_invoices', 'add') or public.can(p_company, 'purchase_invoices', 'add')) then
    raise exception 'ما عندك صلاحية'; end if;
  return query
    select m.item_id, m.warehouse_id, m.batch_id, b.batch_no, b.expiry_date, sum(m.qty)::numeric, (b.expiry_date - public.local_today())::int
      from public.batch_moves m left join public.item_batches b on b.id = m.batch_id
     where m.company_id = p_company and (p_warehouse is null or m.warehouse_id = p_warehouse) and (p_item is null or m.item_id = p_item)
     group by m.item_id, m.warehouse_id, m.batch_id, b.batch_no, b.expiry_date
    having p_all or abs(sum(m.qty)) > 0.0005
     order by b.expiry_date nulls last, b.batch_no;
end $$;
revoke execute on function public.batch_balances(uuid, uuid, uuid, boolean) from public, anon;
grant execute on function public.batch_balances(uuid, uuid, uuid, boolean) to authenticated;

-- حركات دفعة (سجل الدفعة)
create or replace function public.batch_history(p_batch uuid)
returns table (move_date date, warehouse_id uuid, qty numeric, source_type text, source_id uuid, doc_no text, doc_kind text)
language plpgsql stable security definer set search_path = public as $$
declare b public.item_batches;
begin
  select * into b from public.item_batches where id = p_batch;
  if b.id is null or not (public.can(b.company_id, 'inventory', 'view') or public.can(b.company_id, 'items', 'view')) then raise exception 'ما عندك صلاحية'; end if;
  return query
    select m.move_date, m.warehouse_id, m.qty, m.source_type, m.source_id,
           coalesce(i.doc_code, i.inv_no::text, s.doc_code, s.doc_no::text),
           coalesce(i.inv_type, 'stock_' || s.doc_type)
      from public.batch_moves m
      left join public.invoices i on m.source_type in ('invoice', 'invoice_cancel') and i.id = m.source_id
      left join public.stock_docs s on m.source_type = 'stock_doc' and s.id = m.source_id
     where m.batch_id = p_batch and m.company_id = b.company_id order by m.move_date, m.created_at;
end $$;
revoke execute on function public.batch_history(uuid) from public, anon;
grant execute on function public.batch_history(uuid) to authenticated;

-- النسخة الاحتياطية: الدفعات بعد الأصناف، ودفتر الدفعات بعد حركات المخزون
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1, 'companies', 'id = $1', 'code'),
   (2, 'fiscal_years', 'company_id = $1', 'start_date'),
   (3, 'accounts', 'company_id = $1', 'level, code'),
   (4, 'discount_types', 'company_id = $1', 'code'),
   (5, 'cost_centers', 'company_id = $1', 'code'),
   (6, 'currencies', 'company_id = $1', 'code'),
   (7, 'company_settings', 'company_id = $1', 'company_id'),
   (8, 'lookups', 'company_id = $1', 'parent_id nulls first, kind, code'),
   (9, 'custom_fields', 'company_id = $1', 'entity, sort'),
   (10, 'party_categories', 'company_id = $1', 'party_type, code'),
   (11, 'price_lists', 'company_id = $1', 'code'),
   (12, 'party_doc_types', 'company_id = $1', 'code'),
   (13, 'parties', 'company_id = $1', 'code'),
   (14, 'party_documents', 'company_id = $1', 'party_id, expiry_date'),
   (15, 'sales_visits', 'company_id = $1', 'started_at'),
   (16, 'item_categories', 'company_id = $1', 'code'),
   (17, 'items', 'company_id = $1', 'code'),
   (18, 'item_batches', 'company_id = $1', 'item_id, batch_no'),
   (19, 'price_list_items', 'list_id in (select id from public.price_lists where company_id = $1)', 'list_id'),
   (20, 'promotions', 'company_id = $1', 'date_from'),
   (21, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (22, 'warehouses', 'company_id = $1', 'code'),
   (23, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (24, 'departments', 'company_id = $1', 'level, code'),
   (25, 'doc_types', 'company_id = $1', 'kind, code'),
   (26, 'doc_statuses', 'company_id = $1', 'kind, sort, code'),
   (27, 'boms', 'company_id = $1', 'code'),
   (28, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (29, 'journal_entries', 'company_id = $1', 'created_at'),
   (30, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (31, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (32, 'invoices', 'company_id = $1', 'created_at'),
   (33, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (34, 'invoice_allocations', 'company_id = $1', 'created_at'),
   (35, 'orders', 'company_id = $1', 'created_at'),
   (36, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (37, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (38, 'cheques', 'company_id = $1', 'created_at'),
   (39, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (40, 'supply_requests', 'company_id = $1', 'req_no'),
   (41, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (42, 'stock_docs', 'company_id = $1', 'created_at'),
   (43, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (44, 'stock_moves', 'company_id = $1', 'created_at'),
   (45, 'batch_moves', 'company_id = $1', 'created_at'),
   (46, 'landed_costs', 'company_id = $1', 'doc_no'),
   (47, 'landed_cost_invoices', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (48, 'landed_cost_charges', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id, line_no'),
   (49, 'landed_cost_allocs', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (50, 'productions', 'company_id = $1', 'prod_no'),
   (51, 'obligations', 'company_id = $1', 'due_date'),
   (52, 'recurring_entries', 'company_id = $1', 'created_at'),
   (53, 'work_locations', 'company_id = $1', 'name'),
   (54, 'work_shifts', 'company_id = $1', 'code'),
   (55, 'employees', 'company_id = $1', 'code'),
   (56, 'attendance', 'company_id = $1', 'day, employee_id'),
   (57, 'leave_types', 'company_id = $1', 'code'),
   (58, 'leave_requests', 'company_id = $1', 'req_no'),
   (59, 'payroll_runs', 'company_id = $1', 'period'),
   (60, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (61, 'employee_loans', 'company_id = $1', 'loan_no'),
   (62, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (63, 'asset_custodians', 'company_id = $1', 'code'),
   (64, 'fixed_assets', 'company_id = $1', 'code'),
   (65, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (66, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (67, 'asset_movements', 'company_id = $1', 'mov_no'),
   (68, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (69, 'custody_docs', 'company_id = $1', 'doc_no'),
   (70, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (71, 'bank_recons', 'company_id = $1', 'created_at'),
   (72, 'bank_cleared', 'company_id = $1', 'line_id'),
   (73, 'message_log', 'company_id = $1', 'sent_at'),
   (74, 'doc_follow', 'company_id = $1', 'updated_at'),
   (75, 'doc_follow_log', 'company_id = $1', 'set_at'),
   (76, 'attachments', 'company_id = $1', 'created_at'),
   (77, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
