-- =====================================================================
--  السمو ERP — المرحلة 19: سجل التتبع
--  • كل سند وبطاقة: مين أدخله ومتى، ومين آخر واحد عدّل عليه ومتى (created_by/at، updated_by/at)
--  • كل إضافة وتعديل وحذف وترحيل بينسجّل لحاله بسجل النشاط من قاعدة البيانات (ما بيعتمد على الواجهة)
--  • doc_history(): سجل التتبع لسند واحد بأسماء المستخدمين
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

do $$
declare t text;
begin
  foreach t in array array['journal_entries','invoices','stock_docs','parties','items','accounts','cheques','warehouses',
                           'employees','fixed_assets','payroll_runs','item_categories','party_categories','cost_centers',
                           'fiscal_years','companies','obligations','bank_recons','recurring_entries'] loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format('alter table public.%I add column if not exists created_by uuid default auth.uid()', t);
    execute format('alter table public.%I add column if not exists created_at timestamptz default now()', t);
    execute format('alter table public.%I add column if not exists updated_by uuid', t);
    execute format('alter table public.%I add column if not exists updated_at timestamptz', t);
  end loop;
end $$;

-- ختم المستخدم والوقت (اسمها ac_ عشان تشتغل بعد aa_ و ab_ وقبل باقي الـ triggers)
create or replace function public.ac_audit_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if not public.is_internal() then new.created_by := coalesce(auth.uid(), new.created_by); new.created_at := now(); end if;
    new.created_by := coalesce(new.created_by, auth.uid()); new.created_at := coalesce(new.created_at, now());
    if not public.is_internal() then new.updated_by := null; end if;
  else
    new.created_by := old.created_by; new.created_at := old.created_at;
    if auth.uid() is not null then new.updated_by := auth.uid(); new.updated_at := now();
    else new.updated_by := old.updated_by; new.updated_at := old.updated_at; end if;
  end if;
  return new;
end $$;
revoke execute on function public.ac_audit_stamp() from public, anon, authenticated;

-- تسجيل كل حركة بسجل النشاط
create or replace function public.zy_audit_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare o jsonb; n jsonb; r jsonb; ch text[]; act text; cid uuid; label text;
begin
  if tg_op = 'DELETE' then r := to_jsonb(old); else r := to_jsonb(new); end if;
  if tg_op = 'UPDATE' then
    o := to_jsonb(old); n := to_jsonb(new);
    select array_agg(k order by k) into ch from jsonb_object_keys(n) k
      where k not in ('updated_at','updated_by','seq_key','posting_ready') and (o -> k) is distinct from (n -> k);
    if ch is null then return null; end if;
    act := case
      when (o ->> 'status') is distinct from (n ->> 'status') then
        case n ->> 'status' when 'posted' then 'ترحيل' when 'draft' then 'إلغاء ترحيل' when 'cancelled' then 'إلغاء' when 'reversed' then 'قيد عكسي' else 'تعديل' end
      when (o ->> 'stock_posted') is distinct from (n ->> 'stock_posted') then
        case when (n ->> 'stock_posted')::boolean then 'ترحيل للمخزون' else 'إلغاء ترحيل مخزون' end
      when (o ->> 'entry_id') is distinct from (n ->> 'entry_id') and tg_table_name = 'stock_docs' then
        case when n ->> 'entry_id' is null then 'إلغاء ترحيل محاسبة' else 'ترحيل للمحاسبة' end
      else 'تعديل' end;
  else
    act := case tg_op when 'INSERT' then 'إضافة' else 'حذف' end;
  end if;
  if tg_op = 'INSERT' and public.is_internal() then return null; end if;   -- إدخال من النظام (استرجاع، قيود الترحيل)
  cid := case when tg_table_name = 'companies' then (r ->> 'id')::uuid else (r ->> 'company_id')::uuid end;
  if tg_op = 'DELETE' and not exists (select 1 from public.companies where id = cid) then cid := null; end if;  -- حذف شركة كاملة
  label := coalesce(r ->> 'doc_code', r ->> 'code', r ->> 'name', r ->> 'period', r ->> 'title', r ->> 'cheque_no');
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), cid, act, tg_table_name, r ->> 'id',
          jsonb_strip_nulls(jsonb_build_object('no', label, 'changes', to_jsonb(ch), 'auto', true)));
  return null;
end $$;
revoke execute on function public.zy_audit_log() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['journal_entries','invoices','stock_docs','parties','items','accounts','cheques','warehouses',
                           'employees','fixed_assets','payroll_runs','item_categories','party_categories','cost_centers',
                           'fiscal_years','companies','obligations','bank_recons','recurring_entries'] loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format('drop trigger if exists ac_audit_stamp on public.%I', t);
    execute format('create trigger ac_audit_stamp before insert or update on public.%I for each row execute function public.ac_audit_stamp()', t);
    execute format('drop trigger if exists zy_audit_log on public.%I', t);
    execute format('create trigger zy_audit_log after insert or update or delete on public.%I for each row execute function public.zy_audit_log()', t);
  end loop;
end $$;
create index if not exists activity_log_entity_idx on public.activity_log (entity_id);
create index if not exists activity_log_user_idx on public.activity_log (user_id, created_at desc);

-- أسماء المستخدمين (للعرض بس)
create or replace function public.user_names(p_ids uuid[]) returns table (id uuid, name text)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(nullif(p.full_name, ''), nullif(p.username, ''), split_part(p.email, '@', 1))
  from public.profiles p where public.is_active_user() and p.id = any(p_ids);
$$;
revoke execute on function public.user_names(uuid[]) from public, anon;
grant execute on function public.user_names(uuid[]) to authenticated;

-- سجل التتبع لسند/بطاقة واحدة (لمين إله وصول على شركتها)
create or replace function public.doc_history(p_id uuid)
returns table (created_at timestamptz, user_name text, action text, entity text, details jsonb)
language sql stable security definer set search_path = public as $$
  select l.created_at, coalesce(nullif(p.full_name, ''), nullif(p.username, ''), split_part(p.email, '@', 1)), l.action, l.entity, l.details
  from public.activity_log l left join public.profiles p on p.id = l.user_id
  where l.entity_id = p_id::text and l.company_id is not null and public.has_company(l.company_id)
  order by l.created_at desc, l.id desc limit 500;
$$;
revoke execute on function public.doc_history(uuid) from public, anon;
grant execute on function public.doc_history(uuid) to authenticated;
