-- =====================================================================
--  المرحلة 86: الباركود المتعدد والأرقام التسلسلية (سيريال)
--  item_barcodes: باركود إضافي للصنف (مع «يساوي كم حبة» مثل الكرتونة = 12) — فريد بالشركة مع items.barcode.
--  items.serial_tracked: الصنف بيتتبّع بالسيريال. invoice_lines.serials / stock_doc_lines.serials (text[]).
--  serial_moves = دفتر السيريالات (+1 داخل / −1 طالع لكل مستودع) من ترحيل المخزون (زي دفتر الدفعات):
--    عدد السيريالات لازم = الكمية، الداخل ما بيكون موجود بالمخزون، والطالع لازم يكون بنفس المستودع.
--    نقطة البيع وأوامر الإنتاج والجرد ما بيتتبّعوا السيريال (بيتخطّوا). إدخال طلب التزويد بياخذ سيريالات الإخراج.
-- =====================================================================
alter table public.items add column if not exists serial_tracked boolean not null default false;
alter table public.invoice_lines add column if not exists serials text[];
alter table public.stock_doc_lines add column if not exists serials text[];

-- تنظيف السيريالات بالسطر: بدون فراغات ومكرر، ≤ 500، كل واحد ≤ 60 حرف
create or replace function public.ab_line_serials() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.serials is null then return new; end if;
  select array_agg(distinct s order by s) into new.serials from (select trim(x) s from unnest(new.serials) x) t where s <> '';
  if coalesce(array_length(new.serials, 1), 0) > 500 then raise exception 'السيريالات بالسطر أكثر من 500'; end if;
  if exists (select 1 from unnest(new.serials) x where length(x) > 60) then raise exception 'رقم السيريال طويل (أقصى 60 حرف)'; end if;
  return new;
end $$;
drop trigger if exists ab_line_serials on public.invoice_lines;
create trigger ab_line_serials before insert or update of serials on public.invoice_lines for each row execute function public.ab_line_serials();
drop trigger if exists ab_line_serials on public.stock_doc_lines;
create trigger ab_line_serials before insert or update of serials on public.stock_doc_lines for each row execute function public.ab_line_serials();

-- ===== الباركود الإضافي =====
create table if not exists public.item_barcodes (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  item_id    uuid not null references public.items(id) on delete cascade,
  barcode    text not null check (length(barcode) between 1 and 60),
  factor     numeric(18,3) not null default 1 check (factor > 0),
  label      text,
  created_at timestamptz not null default now(),
  unique (company_id, barcode)
);
create index if not exists item_barcodes_item on public.item_barcodes (item_id);
create or replace function public.ab_item_barcode_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.barcode := trim(new.barcode);
  if not exists (select 1 from public.items where id = new.item_id and company_id = new.company_id) then raise exception 'الصنف مش من نفس الشركة'; end if;
  if exists (select 1 from public.items where company_id = new.company_id and barcode = new.barcode) then raise exception 'الباركود «%» مستعمل لصنف (الباركود الأساسي)', new.barcode; end if;
  return new;
end $$;
drop trigger if exists ab_item_barcode_check on public.item_barcodes;
create trigger ab_item_barcode_check before insert or update on public.item_barcodes for each row execute function public.ab_item_barcode_check();
alter table public.item_barcodes enable row level security;
drop policy if exists ibc_select on public.item_barcodes;
create policy ibc_select on public.item_barcodes for select to authenticated using (public.has_company(company_id));
drop policy if exists ibc_write on public.item_barcodes;
create policy ibc_write on public.item_barcodes for all to authenticated
  using (public.can(company_id, 'items', 'edit') and public.tenant_writable()) with check (public.can(company_id, 'items', 'edit') and public.tenant_writable());
grant select, insert, update, delete on public.item_barcodes to authenticated;

-- ===== دفتر السيريالات =====
create table if not exists public.serial_moves (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  item_id     uuid not null references public.items(id) on delete cascade,
  serial      text not null,
  warehouse_id uuid not null references public.warehouses(id) on delete cascade,
  move_date   date not null,
  qty         int not null check (qty in (-1, 1)),
  source_type text not null,
  source_id   uuid not null,
  line_id     uuid,
  created_at  timestamptz not null default now()
);
create index if not exists serial_moves_lookup on public.serial_moves (company_id, item_id, serial);
create index if not exists serial_moves_src on public.serial_moves (source_id);
alter table public.serial_moves enable row level security;
revoke insert, update, delete on public.serial_moves from authenticated;
grant select on public.serial_moves to authenticated;
drop policy if exists sm_select on public.serial_moves;
create policy sm_select on public.serial_moves for select to authenticated
  using (public.can(company_id, 'inventory', 'view') or public.can(company_id, 'items', 'view'));

-- بعد أي تغيير: كل سيريال رصيده بكل مستودع 0 أو 1، ومجموعه بالشركة 0 أو 1
create or replace function public.serial_validate(p_company uuid, p_item uuid, p_serials text[]) returns void
language plpgsql security definer set search_path = public as $$
declare r record; nm text;
begin
  for r in select serial, warehouse_id, sum(qty) q, sum(sum(qty)) over (partition by serial) t
             from public.serial_moves where company_id = p_company and item_id = p_item and serial = any (p_serials)
            group by serial, warehouse_id loop
    select name into nm from public.items where id = p_item;
    if r.q < 0 then raise exception 'السيريال «%» (%) مش موجود بالمستودع', r.serial, nm; end if;
    if r.q > 1 or r.t > 1 then raise exception 'السيريال «%» (%) موجود بالمخزون من قبل', r.serial, nm; end if;
  end loop;
end $$;

create or replace function public.serial_sync(p_kind text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invoices; d public.stock_docs; r record; w uuid; sgn int; n int;
begin
  if p_kind = 'invoice' then
    select * into i from public.invoices where id = p_id;
    if i.pos then return; end if;
    w := coalesce(i.warehouse_id, (select id from public.warehouses where company_id = i.company_id and is_active order by code limit 1));
    sgn := case when i.inv_type in ('purchase','sale_return') then 1 else -1 end;
    for r in select l.* from public.invoice_lines l join public.items it on it.id = l.item_id
              where l.invoice_id = p_id and it.item_type = 'goods' and it.track_stock and it.serial_tracked order by l.line_no loop
      n := coalesce(array_length(r.serials, 1), 0);
      if r.qty <> n then raise exception 'السطر %: عدد السيريالات (%) لازم يساوي الكمية (%)', r.line_no, n, r.qty; end if;
      insert into public.serial_moves (company_id, item_id, serial, warehouse_id, move_date, qty, source_type, source_id, line_id)
      select i.company_id, r.item_id, x, w, i.inv_date, sgn, 'invoice', p_id, r.id from unnest(r.serials) x;
      perform public.serial_validate(i.company_id, r.item_id, r.serials);
    end loop;
  else
    select * into d from public.stock_docs where id = p_id;
    if d.production_id is not null or d.doc_type = 'count' then return; end if;
    if d.doc_type = 'in' and d.supply_request_id is not null then   -- إدخال طلب التزويد: نفس سيريالات الإخراج
      insert into public.serial_moves (company_id, item_id, serial, warehouse_id, move_date, qty, source_type, source_id, line_id)
      select d.company_id, m.item_id, m.serial, d.warehouse_id, d.doc_date, 1, 'stock_doc', p_id, null
        from public.serial_moves m join public.supply_requests q on q.id = d.supply_request_id
       where m.source_type = 'stock_doc' and m.source_id = q.out_doc_id and m.qty = -1;
      for r in select item_id, array_agg(serial) s from public.serial_moves where source_id = p_id group by item_id loop
        perform public.serial_validate(d.company_id, r.item_id, r.s);
      end loop;
      return;
    end if;
    for r in select l.* from public.stock_doc_lines l join public.items it on it.id = l.item_id
              where l.doc_id = p_id and it.item_type = 'goods' and it.track_stock and it.serial_tracked order by l.line_no loop
      n := coalesce(array_length(r.serials, 1), 0);
      if abs(r.qty) <> n then raise exception 'السطر %: عدد السيريالات (%) لازم يساوي الكمية (%)', r.line_no, n, abs(r.qty); end if;
      insert into public.serial_moves (company_id, item_id, serial, warehouse_id, move_date, qty, source_type, source_id, line_id)
      select d.company_id, r.item_id, x, d.warehouse_id, d.doc_date, case when d.doc_type = 'in' then 1 else -1 end, 'stock_doc', p_id, r.id from unnest(r.serials) x;
      if d.doc_type = 'transfer' then
        insert into public.serial_moves (company_id, item_id, serial, warehouse_id, move_date, qty, source_type, source_id, line_id)
        select d.company_id, r.item_id, x, d.to_warehouse_id, d.doc_date, 1, 'stock_doc', p_id, r.id from unnest(r.serials) x;
      end if;
      perform public.serial_validate(d.company_id, r.item_id, r.serials);
    end loop;
  end if;
end $$;

-- إلغاء ترحيل/إلغاء: بنشيل الحركات وبنتأكد إنه الباقي صحيح
create or replace function public.serial_unsync(p_id uuid, p_types text[]) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  create temp table if not exists _sx (company_id uuid, item_id uuid, s text[]) on commit drop; truncate _sx;
  insert into _sx select company_id, item_id, array_agg(distinct serial) from public.serial_moves where source_id = p_id and source_type = any (p_types) group by 1, 2;
  delete from public.serial_moves where source_id = p_id and source_type = any (p_types);
  for r in select * from _sx loop
    begin perform public.serial_validate(r.company_id, r.item_id, r.s);
    exception when others then raise exception 'ما بينفع: سيريالات هالمستند انحركت بعده (%)', sqlerrm; end;
  end loop;
end $$;

create or replace function public.zc_invoice_serials() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not old.stock_posted and new.stock_posted then
    perform public.serial_sync('invoice', new.id);
  elsif old.stock_posted and not new.stock_posted then
    perform public.serial_unsync(new.id, array['invoice','invoice_cancel']);
  elsif old.status = 'posted' and new.status = 'cancelled' and new.stock_posted then
    insert into public.serial_moves (company_id, item_id, serial, warehouse_id, move_date, qty, source_type, source_id, line_id)
    select company_id, item_id, serial, warehouse_id, coalesce((select entry_date from public.journal_entries where id = new.cancel_entry_id), current_date),
           -qty, 'invoice_cancel', source_id, line_id from public.serial_moves where source_type = 'invoice' and source_id = new.id;
    for r in select company_id, item_id, array_agg(serial) s from public.serial_moves where source_id = new.id and source_type = 'invoice_cancel' group by 1, 2 loop
      begin perform public.serial_validate(r.company_id, r.item_id, r.s);
      exception when others then raise exception 'ما بينفع: سيريالات الفاتورة انحركت بعدها (%)', sqlerrm; end;
    end loop;
  end if;
  return null;
end $$;
drop trigger if exists zc_invoice_serials on public.invoices;
create trigger zc_invoice_serials after update of status, stock_posted on public.invoices for each row execute function public.zc_invoice_serials();

create or replace function public.zc_stock_doc_serials() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'draft' and new.status = 'posted' then perform public.serial_sync('stock_doc', new.id);
  elsif old.status = 'posted' and new.status <> 'posted' then perform public.serial_unsync(new.id, array['stock_doc']);
  end if;
  return null;
end $$;
drop trigger if exists zc_stock_doc_serials on public.stock_docs;
create trigger zc_stock_doc_serials after update of status on public.stock_docs for each row execute function public.zc_stock_doc_serials();

-- السيريالات الموجودة (للاختيار بالسطر والتقرير)
create or replace function public.serial_balances(p_company uuid, p_warehouse uuid default null, p_item uuid default null)
returns table (item_id uuid, warehouse_id uuid, serial text, since date)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.can(p_company, 'inventory', 'view') or public.can(p_company, 'items', 'view')
          or public.can(p_company, 'sales_invoices', 'add') or public.can(p_company, 'purchase_invoices', 'add')) then raise exception 'ما عندك صلاحية'; end if;
  return query
    select m.item_id, m.warehouse_id, m.serial, max(m.move_date) filter (where m.qty > 0)
      from public.serial_moves m
     where m.company_id = p_company and (p_warehouse is null or m.warehouse_id = p_warehouse) and (p_item is null or m.item_id = p_item)
     group by m.item_id, m.warehouse_id, m.serial having sum(m.qty) > 0
     order by m.item_id, m.serial;
end $$;

-- سجل سيريال (بحث برقم السيريال)
create or replace function public.serial_history(p_company uuid, p_serial text)
returns table (item_id uuid, warehouse_id uuid, move_date date, qty int, source_type text, source_id uuid, doc_no text, doc_kind text, party_name text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.can(p_company, 'inventory', 'view') or public.can(p_company, 'items', 'view')) then raise exception 'ما عندك صلاحية'; end if;
  return query
    select m.item_id, m.warehouse_id, m.move_date, m.qty, m.source_type, m.source_id,
           coalesce(i.doc_code, i.inv_no::text, s.doc_code, s.doc_no::text), coalesce(i.inv_type, 'stock_' || s.doc_type),
           coalesce(p.name, i.party_name)
      from public.serial_moves m
      left join public.invoices i on m.source_type in ('invoice', 'invoice_cancel') and i.id = m.source_id
      left join public.parties p on p.id = i.party_id
      left join public.stock_docs s on m.source_type = 'stock_doc' and s.id = m.source_id
     where m.company_id = p_company and m.serial = trim(p_serial) order by m.move_date, m.created_at;
end $$;

revoke execute on function public.ab_line_serials(), public.ab_item_barcode_check(), public.serial_validate(uuid, uuid, text[]), public.serial_sync(text, uuid),
  public.serial_unsync(uuid, text[]), public.zc_invoice_serials(), public.zc_stock_doc_serials() from public, anon, authenticated;
revoke execute on function public.serial_balances(uuid, uuid, uuid), public.serial_history(uuid, text) from public, anon;
grant execute on function public.serial_balances(uuid, uuid, uuid), public.serial_history(uuid, text) to authenticated;

-- النسخة الاحتياطية: الباركود بعد الأصناف، ودفتر السيريالات بعد دفتر الدفعات
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
   (8, 'commission_plans', 'company_id = $1', 'code'),
   (9, 'lookups', 'company_id = $1', 'parent_id nulls first, kind, code'),
   (10, 'rep_targets', 'company_id = $1', 'month, rep_id'),
   (11, 'custom_fields', 'company_id = $1', 'entity, sort'),
   (12, 'party_categories', 'company_id = $1', 'party_type, code'),
   (13, 'price_lists', 'company_id = $1', 'code'),
   (14, 'party_doc_types', 'company_id = $1', 'code'),
   (15, 'parties', 'company_id = $1', 'code'),
   (16, 'party_documents', 'company_id = $1', 'party_id, expiry_date'),
   (17, 'sales_visits', 'company_id = $1', 'started_at'),
   (18, 'item_categories', 'company_id = $1', 'code'),
   (19, 'items', 'company_id = $1', 'code'),
   (20, 'item_barcodes', 'company_id = $1', 'item_id, barcode'),
   (21, 'item_batches', 'company_id = $1', 'item_id, batch_no'),
   (22, 'price_list_items', 'list_id in (select id from public.price_lists where company_id = $1)', 'list_id'),
   (23, 'promotions', 'company_id = $1', 'date_from'),
   (24, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (25, 'warehouses', 'company_id = $1', 'code'),
   (26, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (27, 'departments', 'company_id = $1', 'level, code'),
   (28, 'doc_types', 'company_id = $1', 'kind, code'),
   (29, 'doc_statuses', 'company_id = $1', 'kind, sort, code'),
   (30, 'boms', 'company_id = $1', 'code'),
   (31, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (32, 'work_locations', 'company_id = $1', 'name'),
   (33, 'work_shifts', 'company_id = $1', 'code'),
   (34, 'employees', 'company_id = $1', 'code'),
   (35, 'contract_templates', 'company_id = $1', 'code'),
   (36, 'contracts', 'company_id = $1', 'contract_no'),
   (37, 'contract_lines', 'contract_id in (select id from public.contracts where company_id = $1)', 'contract_id, line_no'),
   (38, 'journal_entries', 'company_id = $1', 'created_at'),
   (39, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (40, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (41, 'invoices', 'company_id = $1', 'created_at'),
   (42, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (43, 'invoice_party_splits', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (44, 'invoice_allocations', 'company_id = $1', 'created_at'),
   (45, 'party_notes', 'company_id = $1', 'created_at'),
   (46, 'orders', 'company_id = $1', 'created_at'),
   (47, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (48, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (49, 'cheques', 'company_id = $1', 'created_at'),
   (50, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (51, 'guarantee_cheques', 'company_id = $1', 'doc_no'),
   (52, 'supply_requests', 'company_id = $1', 'req_no'),
   (53, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (54, 'stock_docs', 'company_id = $1', 'created_at'),
   (55, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (56, 'stock_moves', 'company_id = $1', 'created_at'),
   (57, 'batch_moves', 'company_id = $1', 'created_at'),
   (58, 'serial_moves', 'company_id = $1', 'created_at'),
   (59, 'landed_costs', 'company_id = $1', 'doc_no'),
   (60, 'landed_cost_invoices', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (61, 'landed_cost_charges', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id, line_no'),
   (62, 'landed_cost_allocs', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (63, 'productions', 'company_id = $1', 'prod_no'),
   (64, 'obligations', 'company_id = $1', 'due_date'),
   (65, 'recurring_entries', 'company_id = $1', 'created_at'),
   (66, 'budgets', 'company_id = $1', 'code'),
   (67, 'budget_lines', 'budget_id in (select id from public.budgets where company_id = $1)', 'budget_id'),
   (68, 'attendance', 'company_id = $1', 'day, employee_id'),
   (69, 'leave_types', 'company_id = $1', 'code'),
   (70, 'leave_requests', 'company_id = $1', 'req_no'),
   (71, 'payroll_runs', 'company_id = $1', 'period'),
   (72, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (73, 'employee_loans', 'company_id = $1', 'loan_no'),
   (74, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (75, 'asset_custodians', 'company_id = $1', 'code'),
   (76, 'fixed_assets', 'company_id = $1', 'code'),
   (77, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (78, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (79, 'asset_movements', 'company_id = $1', 'mov_no'),
   (80, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (81, 'custody_docs', 'company_id = $1', 'doc_no'),
   (82, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (83, 'bank_recons', 'company_id = $1', 'created_at'),
   (84, 'bank_cleared', 'company_id = $1', 'line_id'),
   (85, 'message_log', 'company_id = $1', 'sent_at'),
   (86, 'doc_follow', 'company_id = $1', 'updated_at'),
   (87, 'doc_follow_log', 'company_id = $1', 'set_at'),
   (88, 'attachments', 'company_id = $1', 'created_at'),
   (89, 'fiscal_periods', 'company_id = $1', 'start_date')
$$;
