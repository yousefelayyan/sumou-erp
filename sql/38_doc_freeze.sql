-- =====================================================================
--  السمو ERP — المرحلة 38: تجميد المستندات
--  المستند المجمّد ما بينعدّل ولا بينحذف ولا بيترحّل (ولا سطوره) لحد ما ينفك تجميده.
--  التجميد وفكّه من set_doc_frozen بس، بصلاحية edit على شاشة المستند.
-- =====================================================================
alter table public.journal_entries add column if not exists is_frozen boolean not null default false;
alter table public.invoices        add column if not exists is_frozen boolean not null default false;
alter table public.stock_docs      add column if not exists is_frozen boolean not null default false;
alter table public.orders          add column if not exists is_frozen boolean not null default false;

-- الرأس: الحقل is_frozen من الدالة بس، والمجمّد ما بيتغيّر/بينحذف (حتى الترحيل الداخلي)
create or replace function public.ab_doc_frozen_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare flip boolean := coalesce(current_setting('sumou.freeze', true), '') = public.internal_token();
begin
  if tg_op = 'INSERT' then
    if not public.is_internal() then new.is_frozen := false; end if;
    return new;
  end if;
  if tg_op = 'DELETE' then
    if old.is_frozen then raise exception 'المستند مجمّد، فك التجميد أول عشان تحذفه'; end if;
    return old;
  end if;
  if new.is_frozen is distinct from old.is_frozen and not flip and not public.is_internal() then
    raise exception 'التجميد بيصير من كبسة «تجميد» بس';
  end if;
  if old.is_frozen and new.is_frozen and not flip then
    raise exception 'المستند مجمّد، ما بينعدّل ولا بيترحّل. فك التجميد أول';
  end if;
  return new;
end $$;
do $$ declare t text; begin
  foreach t in array array['journal_entries','invoices','stock_docs','orders'] loop
    execute format('drop trigger if exists ab_doc_frozen_guard on public.%I', t);
    execute format('create trigger ab_doc_frozen_guard before insert or update or delete on public.%I for each row execute function public.ab_doc_frozen_guard()', t);
  end loop;
end $$;

-- السطور: ممنوعة إذا الرأس مجمّد
create or replace function public.ab_doc_lines_frozen() returns trigger
language plpgsql security definer set search_path = public as $$
declare pid uuid; fr boolean;
begin
  if public.is_internal() then return case when tg_op = 'DELETE' then old else new end; end if;
  -- النقل من مستند مجمّد لمستند ثاني ممنوع كمان
  if tg_op = 'UPDATE' then
    if tg_table_name = 'journal_lines' then
      if old.entry_id is distinct from new.entry_id then select is_frozen into fr from public.journal_entries where id = old.entry_id; end if;
    elsif tg_table_name = 'invoice_lines' then
      if old.invoice_id is distinct from new.invoice_id then select is_frozen into fr from public.invoices where id = old.invoice_id; end if;
    elsif tg_table_name = 'stock_doc_lines' then
      if old.doc_id is distinct from new.doc_id then select is_frozen into fr from public.stock_docs where id = old.doc_id; end if;
    else
      if old.order_id is distinct from new.order_id then select is_frozen into fr from public.orders where id = old.order_id; end if;
    end if;
    if coalesce(fr, false) then raise exception 'المستند مجمّد، ما بتتعدّل سطوره'; end if;
  end if;
  if tg_table_name = 'journal_lines' then
    pid := case when tg_op = 'DELETE' then old.entry_id else new.entry_id end;
    select is_frozen into fr from public.journal_entries where id = pid;
  elsif tg_table_name = 'invoice_lines' then
    pid := case when tg_op = 'DELETE' then old.invoice_id else new.invoice_id end;
    select is_frozen into fr from public.invoices where id = pid;
  elsif tg_table_name = 'stock_doc_lines' then
    pid := case when tg_op = 'DELETE' then old.doc_id else new.doc_id end;
    select is_frozen into fr from public.stock_docs where id = pid;
  else
    pid := case when tg_op = 'DELETE' then old.order_id else new.order_id end;
    select is_frozen into fr from public.orders where id = pid;
  end if;
  if coalesce(fr, false) then raise exception 'المستند مجمّد، ما بتتعدّل سطوره'; end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
do $$ declare t text; begin
  foreach t in array array['journal_lines','invoice_lines','stock_doc_lines','order_lines'] loop
    execute format('drop trigger if exists ab_doc_lines_frozen on public.%I', t);
    execute format('create trigger ab_doc_lines_frozen before insert or update or delete on public.%I for each row execute function public.ab_doc_lines_frozen()', t);
  end loop;
end $$;

create or replace function public.set_doc_frozen(p_table text, p_id uuid, p_frozen boolean) returns void
language plpgsql security definer set search_path = public as $$
declare cid uuid; scr text; t text; st text; no text;
begin
  if p_table = 'journal_entries' then select company_id, public.entry_screen(entry_type), coalesce(doc_code, entry_no::text) into cid, scr, no from public.journal_entries where id = p_id;
  elsif p_table = 'invoices' then select company_id, public.invoice_screen(inv_type), coalesce(doc_code, inv_no::text) into cid, scr, no from public.invoices where id = p_id;
  elsif p_table = 'stock_docs' then select company_id, 'inventory', coalesce(doc_code, doc_no::text) into cid, scr, no from public.stock_docs where id = p_id;
  elsif p_table = 'orders' then select company_id, case order_type when 'sales_order' then 'sales_orders' else 'purchase_orders' end, order_no::text into cid, scr, no from public.orders where id = p_id;
  else raise exception 'نوع مستند مش معروف'; end if;
  if cid is null then raise exception 'المستند مش موجود'; end if;
  if not public.can(cid, scr, 'edit') then raise exception 'ما عندك صلاحية تجميد هالمستند'; end if;
  -- داخلي عشان أقفال المستند المرحّل ما تمنع تغيير علامة التجميد بس
  perform set_config('sumou.freeze', public.internal_token(), true);
  perform set_config('sumou.internal', public.internal_token(), true);
  execute format('update public.%I set is_frozen = $1 where id = $2', p_table) using p_frozen, p_id;
  perform set_config('sumou.internal', '', true);
  perform set_config('sumou.freeze', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), cid, 'تعديل', p_table, p_id::text, jsonb_build_object('no', no, 'frozen', p_frozen));
end $$;
revoke execute on function public.set_doc_frozen(text, uuid, boolean) from public, anon;
grant execute on function public.set_doc_frozen(text, uuid, boolean) to authenticated;
