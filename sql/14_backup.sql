-- =====================================================================
--  السمو ERP — المرحلة 14: النسخ الاحتياطي والاسترجاع لكل شركة
--  النسخة = ملف JSON فيه كل جداول الشركة. الاسترجاع بيرجّع الشركة كاملة
--  بنفس أرقامها (لما تكون الشركة مش موجودة: قاعدة جديدة أو شركة انحذفت)
-- =====================================================================

-- ترتيب الجداول مهم للاسترجاع (الأب قبل الابن)
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1,  'companies',          'id = $1', 'code'),
   (2,  'fiscal_years',       'company_id = $1', 'start_date'),
   (3,  'accounts',           'company_id = $1', 'level, code'),
   (4,  'cost_centers',       'company_id = $1', 'code'),
   (5,  'currencies',         'company_id = $1', 'code'),
   (6,  'company_settings',   'company_id = $1', 'company_id'),
   (7,  'parties',            'company_id = $1', 'code'),
   (8,  'items',              'company_id = $1', 'code'),
   (9,  'warehouses',         'company_id = $1', 'code'),
   (10, 'journal_entries',    'company_id = $1', 'created_at'),
   (11, 'journal_lines',      'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (12, 'invoices',           'company_id = $1', 'created_at'),
   (13, 'invoice_lines',      'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (14, 'cheques',            'company_id = $1', 'created_at'),
   (15, 'cheque_events',      'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (16, 'stock_docs',         'company_id = $1', 'created_at'),
   (17, 'stock_doc_lines',    'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (18, 'stock_moves',        'company_id = $1', 'created_at'),
   (19, 'obligations',        'company_id = $1', 'due_date'),
   (20, 'recurring_entries',  'company_id = $1', 'created_at'),
   (21, 'employees',          'company_id = $1', 'code'),
   (22, 'payroll_runs',       'company_id = $1', 'period'),
   (23, 'payroll_lines',      'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (24, 'fixed_assets',       'company_id = $1', 'code'),
   (25, 'depreciation_runs',  'company_id = $1', 'created_at'),
   (26, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (27, 'bank_recons',        'company_id = $1', 'created_at'),
   (28, 'bank_cleared',       'company_id = $1', 'line_id'),
   (29, 'attachments',        'company_id = $1', 'created_at');
$$;

create or replace function public.backup_company(p_company uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r record; out jsonb := '{}'::jsonb; part jsonb; c public.companies;
begin
  if not public.is_admin() then raise exception 'النسخ الاحتياطي لمدير النظام بس'; end if;
  select * into c from public.companies where id = p_company;
  if c.id is null then raise exception 'الشركة مش موجودة'; end if;
  for r in select * from public.backup_tables() order by ord loop
    execute format('select coalesce(jsonb_agg(to_jsonb(t) order by %s), ''[]''::jsonb) from public.%I t where %s', r.ordby, r.tbl, r.cond)
      into part using p_company;
    out := out || jsonb_build_object(r.tbl, part);
  end loop;
  return jsonb_build_object('app', 'sumou-erp', 'version', 1, 'company_id', p_company, 'company_name', c.name,
                            'created_at', now(), 'created_by', auth.uid(), 'tables', out);
end $$;

create or replace function public.restore_company(p_data jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare r record; cid uuid; rows jsonb; n int; cols text;
begin
  if not public.is_admin() then raise exception 'الاسترجاع لمدير النظام بس'; end if;
  if p_data ->> 'app' <> 'sumou-erp' or p_data -> 'tables' is null then raise exception 'الملف مش نسخة احتياطية من السمو ERP'; end if;
  cid := (p_data ->> 'company_id')::uuid;
  if exists (select 1 from public.companies where id = cid) then
    raise exception 'الشركة «%» موجودة. الاسترجاع بيرجّع شركة انحذفت أو لقاعدة جديدة بس', p_data ->> 'company_name';
  end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  for r in select * from public.backup_tables() order by ord loop
    rows := coalesce(p_data -> 'tables' -> r.tbl, '[]'::jsonb);
    if jsonb_array_length(rows) = 0 then continue; end if;
    -- الروابط الذاتية والحالات اللي بتمنع الإدخال بتنحط بعدين
    if r.tbl = 'journal_entries' then
      rows := (select jsonb_agg(x - 'reversal_of' - 'reversed_by') from jsonb_array_elements(rows) x);
    elsif r.tbl = 'invoices' then
      rows := (select jsonb_agg(x - 'original_invoice_id') from jsonb_array_elements(rows) x);
    elsif r.tbl = 'bank_recons' then
      rows := (select jsonb_agg(jsonb_set(x, '{status}', '"open"')) from jsonb_array_elements(rows) x);
    elsif r.tbl = 'accounts' then
      rows := (select jsonb_agg(x order by (x ->> 'level')::int) from jsonb_array_elements(rows) x);
    end if;
    -- الأعمدة الموجودة بالنسخة بس (عشان نسخة قديمة تنفع على إصدار أحدث)
    select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into cols
      from pg_attribute a where a.attrelid = ('public.' || r.tbl)::regclass and a.attnum > 0 and not a.attisdropped
       and exists (select 1 from jsonb_array_elements(rows) x where x ? a.attname);
    execute format('insert into public.%I (%s) select %s from jsonb_populate_recordset(null::public.%I, $1)', r.tbl, cols, cols, r.tbl) using rows;
  end loop;
  -- إرجاع الروابط
  update public.journal_entries e set reversal_of = (x ->> 'reversal_of')::uuid, reversed_by = (x ->> 'reversed_by')::uuid
    from jsonb_array_elements(p_data -> 'tables' -> 'journal_entries') x
   where e.id = (x ->> 'id')::uuid and (x ->> 'reversal_of' is not null or x ->> 'reversed_by' is not null);
  update public.invoices i set original_invoice_id = (x ->> 'original_invoice_id')::uuid
    from jsonb_array_elements(p_data -> 'tables' -> 'invoices') x
   where i.id = (x ->> 'id')::uuid and x ->> 'original_invoice_id' is not null;
  update public.bank_recons b set status = x ->> 'status'
    from jsonb_array_elements(coalesce(p_data -> 'tables' -> 'bank_recons', '[]'::jsonb)) x where b.id = (x ->> 'id')::uuid;
  -- المدير بيوصل للشركة المسترجعة
  insert into public.user_companies (user_id, company_id) values (auth.uid(), cid) on conflict do nothing;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), cid, 'استرجاع', 'backup', cid::text, jsonb_build_object('from', p_data ->> 'created_at'));
  return cid;
end $$;

revoke execute on function public.backup_company(uuid), public.restore_company(jsonb) from public, anon;
grant execute on function public.backup_company(uuid), public.restore_company(jsonb) to authenticated;
