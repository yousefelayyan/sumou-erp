-- =====================================================================
--  السمو ERP — المرحلة 33: حركات الأصول الثابتة
--  استبعاد/إتلاف، بيع مباشر لزبون، ونقل بين الدوائر — مستند واحد بقيده.
--  الكتابة كلها من دوال (asset_mov_*)؛ الجداول للعرض بس.
--  القيد نوعه depreciation (قيود الأصول، داخلي)، وسطر لكل أصل.
-- =====================================================================
alter table public.fixed_assets add column if not exists department_id uuid references public.departments(id) on delete set null;
alter table public.company_settings add column if not exists asset_disposal_account_id uuid references public.accounts(id) on delete set null;

create table if not exists public.asset_movements (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies(id) on delete cascade,
  mov_no         int not null,
  kind           text not null check (kind in ('dispose','sale','transfer')),
  mov_date       date not null,
  status         text not null default 'draft' check (status in ('draft','posted','cancelled')),
  party_id       uuid references public.parties(id),   -- الزبون (البيع)
  tax_rate       numeric(6,3) not null default 16 check (tax_rate >= 0),
  from_department_id uuid references public.departments(id) on delete set null,
  to_department_id   uuid references public.departments(id) on delete set null,
  reference      text,
  notes          text,
  entry_id       uuid references public.journal_entries(id) on delete set null,
  cancel_entry_id uuid references public.journal_entries(id) on delete set null,
  total_cost     numeric(18,3) not null default 0,
  total_accum    numeric(18,3) not null default 0,
  total_price    numeric(18,3) not null default 0,
  total_tax      numeric(18,3) not null default 0,
  created_by     uuid default auth.uid(),
  created_at     timestamptz not null default now(),
  posted_at      timestamptz,
  unique (company_id, mov_no)
);
create table if not exists public.asset_movement_lines (
  id            uuid primary key default gen_random_uuid(),
  movement_id   uuid not null references public.asset_movements(id) on delete cascade,
  line_no       int not null,
  asset_id      uuid not null references public.fixed_assets(id),
  sale_price    numeric(18,3) not null default 0 check (sale_price >= 0),
  tax_amount    numeric(18,3) not null default 0 check (tax_amount >= 0),
  cost          numeric(18,3),          -- لقطة وقت الترحيل
  accum         numeric(18,3),
  book_value    numeric(18,3),
  prev_status   text,
  prev_department_id uuid,
  notes         text,
  unique (movement_id, asset_id)
);
create index if not exists asset_mov_lines_asset on public.asset_movement_lines (asset_id);

alter table public.asset_movements enable row level security;
alter table public.asset_movement_lines enable row level security;
drop policy if exists am_select on public.asset_movements;
create policy am_select on public.asset_movements for select to authenticated using (public.can(company_id, 'fixed_assets', 'view'));
drop policy if exists aml_select on public.asset_movement_lines;
create policy aml_select on public.asset_movement_lines for select to authenticated
  using (exists (select 1 from public.asset_movements m where m.id = movement_id and public.can(m.company_id, 'fixed_assets', 'view')));
revoke insert, update, delete on public.asset_movements, public.asset_movement_lines from authenticated;
grant select on public.asset_movements, public.asset_movement_lines to authenticated;

-- حساب «أرباح (خسائر) بيع وشطب أصول ثابتة»: أخ لحساب المبيعات، طبيعته مدين ودائن
create or replace function public.ensure_asset_disposal_account(p_company uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare st public.company_settings; sa public.accounts; aid uuid; c text; n int := 1;
begin
  if not (public.can(p_company, 'accounts', 'add') and public.can(p_company, 'companies', 'edit')) then raise exception 'ما عندك صلاحية'; end if;
  perform public.ensure_company_settings(p_company);
  select * into st from public.company_settings where company_id = p_company;
  if st.asset_disposal_account_id is not null then return st.asset_disposal_account_id; end if;
  select * into sa from public.accounts where id = st.sales_account_id;
  if sa.id is null then raise exception 'حدّد حساب المبيعات أول بشاشة «حسابات الربط»'; end if;
  select id into aid from public.accounts where company_id = p_company and name = 'أرباح (خسائر) بيع وشطب أصول ثابتة' and not is_group limit 1;
  if aid is null then
    loop
      c := coalesce((select code from public.accounts where id = sa.parent_id), left(sa.code, greatest(length(sa.code) - 2, 1))) || lpad((90 + n)::text, 2, '0');
      exit when not exists (select 1 from public.accounts where company_id = p_company and code = c);
      n := n + 1; if n > 9 then raise exception 'ما لقيت رمز فاضي للحساب، اعمله بإيدك من دليل الحسابات'; end if;
    end loop;
    insert into public.accounts (company_id, code, name, parent_id, level, is_group, category, nature, account_type)
    values (p_company, c, 'أرباح (خسائر) بيع وشطب أصول ثابتة', sa.parent_id, sa.level, false, 'revenue', 'both', 'general') returning id into aid;
  end if;
  update public.company_settings set asset_disposal_account_id = aid where company_id = p_company;
  return aid;
end $$;

-- الأصل اللي انستبعد/انباع بحركة مرحّلة ما بترجع حالته إلا بإلغاء الحركة
create or replace function public.ab_asset_mov_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then return new; end if;
  if new.status is distinct from old.status and exists (select 1 from public.asset_movement_lines l join public.asset_movements m on m.id = l.movement_id
       where l.asset_id = old.id and m.status = 'posted' and m.kind in ('dispose','sale')) then
    raise exception 'الأصل مستبعد بحركة أصول مرحّلة. ألغِ الحركة بدل ما تغيّر حالته';
  end if;
  if new.status = 'disposed' and old.status = 'active' and exists (select 1 from public.asset_movement_lines l join public.asset_movements m on m.id = l.movement_id
       where l.asset_id = old.id and m.status = 'draft') then
    raise exception 'الأصل عليه حركة أصول لسا ما ترحّلت';
  end if;
  return new;
end $$;
drop trigger if exists ab_asset_mov_guard on public.fixed_assets;
create trigger ab_asset_mov_guard before update of status on public.fixed_assets for each row execute function public.ab_asset_mov_guard();

-- حفظ مسودة (جديدة أو تعديل): p = {id?, company_id, kind, mov_date, party_id, tax_rate, from_department_id, to_department_id, reference, notes, lines:[{asset_id, sale_price, tax_amount?, notes}]}
create or replace function public.asset_mov_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid := (p ->> 'company_id')::uuid; mid uuid := nullif(p ->> 'id', '')::uuid; m public.asset_movements; k text := p ->> 'kind';
  l jsonb; a public.fixed_assets; n int := 0; pty public.parties; fd uuid := nullif(p ->> 'from_department_id', '')::uuid; td uuid := nullif(p ->> 'to_department_id', '')::uuid;
  rate numeric := coalesce(nullif(p ->> 'tax_rate', '')::numeric, 16); pr numeric; tx numeric;
begin
  if mid is not null then
    select * into m from public.asset_movements where id = mid for update;
    if m.id is null then raise exception 'الحركة مش موجودة'; end if;
    cid := m.company_id; k := m.kind;
    if m.status <> 'draft' then raise exception 'الحركة مرحّلة أو ملغاة، ما بتتعدّل'; end if;
    if not public.can(cid, 'fixed_assets', 'edit') then raise exception 'ما عندك صلاحية تعديل حركات الأصول'; end if;
  elsif not public.can(cid, 'fixed_assets', 'add') then raise exception 'ما عندك صلاحية إضافة حركات الأصول';
  end if;
  if k not in ('dispose', 'sale', 'transfer') then raise exception 'نوع الحركة مش صحيح'; end if;
  if nullif(p ->> 'mov_date', '') is null then raise exception 'اكتب تاريخ الحركة'; end if;
  if k = 'sale' then
    select * into pty from public.parties where id = nullif(p ->> 'party_id', '')::uuid;
    if pty.id is null or pty.company_id <> cid or pty.party_type <> 'customer' then raise exception 'البيع لازم إله زبون من نفس الشركة'; end if;
    if rate < 0 or rate > 100 then raise exception 'نسبة الضريبة مش منطقية'; end if;
  end if;
  if k = 'transfer' then
    if td is null then raise exception 'حدّد الدائرة اللي بينتقل لها الأصل'; end if;
    if fd is not distinct from td then raise exception 'الدائرة المنقول منها والمنقول لها لازم يختلفوا'; end if;
    if not exists (select 1 from public.departments where id = td and company_id = cid and is_active)
       or (fd is not null and not exists (select 1 from public.departments where id = fd and company_id = cid)) then raise exception 'الدائرة مش من نفس الشركة'; end if;
  end if;
  if coalesce(jsonb_typeof(p -> 'lines'), '') <> 'array' or jsonb_array_length(p -> 'lines') = 0 then raise exception 'أضف أصل واحد على الأقل'; end if;

  if mid is null then
    perform pg_advisory_xact_lock(hashtext('assetmov:' || cid::text));
    insert into public.asset_movements (company_id, mov_no, kind, mov_date, party_id, tax_rate, from_department_id, to_department_id, reference, notes)
    values (cid, coalesce((select max(mov_no) from public.asset_movements where company_id = cid), 0) + 1, k, (p ->> 'mov_date')::date,
            pty.id, case when k = 'sale' then rate else 0 end, fd, td, nullif(trim(p ->> 'reference'), ''), nullif(trim(p ->> 'notes'), ''))
    returning id into mid;
  else
    update public.asset_movements set mov_date = (p ->> 'mov_date')::date, party_id = pty.id, tax_rate = case when k = 'sale' then rate else 0 end,
           from_department_id = fd, to_department_id = td, reference = nullif(trim(p ->> 'reference'), ''), notes = nullif(trim(p ->> 'notes'), '')
     where id = mid;
    delete from public.asset_movement_lines where movement_id = mid;
  end if;

  for l in select * from jsonb_array_elements(p -> 'lines') loop
    n := n + 1;
    select * into a from public.fixed_assets where id = (l ->> 'asset_id')::uuid;
    if a.id is null or a.company_id <> cid then raise exception 'أصل مش موجود (سطر %)', n; end if;
    if a.status <> 'active' then raise exception 'الأصل «%» مستبعد', a.name; end if;
    if k = 'transfer' and fd is not null and a.department_id is distinct from fd then raise exception 'الأصل «%» مش بالدائرة المنقول منها', a.name; end if;
    if exists (select 1 from public.asset_movement_lines x join public.asset_movements y on y.id = x.movement_id
               where x.asset_id = a.id and y.status = 'draft' and y.id <> mid) then
      raise exception 'الأصل «%» بحركة ثانية لسا ما ترحّلت', a.name;
    end if;
    pr := case when k = 'sale' then round(coalesce(nullif(l ->> 'sale_price', '')::numeric, 0), 3) else 0 end;
    if k = 'sale' and pr <= 0 then raise exception 'اكتب سعر البيع للأصل «%»', a.name; end if;
    tx := case when k = 'sale' then round(pr * rate / 100, 3) else 0 end;
    insert into public.asset_movement_lines (movement_id, line_no, asset_id, sale_price, tax_amount, notes)
    values (mid, n, a.id, pr, tx, nullif(trim(l ->> 'notes'), ''));
  end loop;
  update public.asset_movements set total_price = (select coalesce(sum(sale_price), 0) from public.asset_movement_lines where movement_id = mid),
         total_tax = (select coalesce(sum(tax_amount), 0) from public.asset_movement_lines where movement_id = mid) where id = mid;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), cid, case when p ? 'id' and nullif(p ->> 'id', '') is not null then 'تعديل' else 'إضافة' end, 'asset_movements', mid::text, jsonb_build_object('kind', k, 'lines', n));
  return mid;
end $$;

-- الترحيل: القيد + تطبيق الحركة على الأصول
create or replace function public.asset_mov_post(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare m public.asset_movements; st public.company_settings; fy uuid; eid uuid := null; ln int := 0; r record; prev_m date;
  acc_asset uuid; acc_accum uuid; disp uuid; party_acc uuid; v_book numeric; v_accum numeric; t_cost numeric := 0; t_acc numeric := 0; tot numeric := 0;
  descr text; gl numeric; prev text := current_setting('sumou.internal', true);
begin
  select * into m from public.asset_movements where id = p_id for update;
  if m.id is null then raise exception 'الحركة مش موجودة'; end if;
  if not public.can(m.company_id, 'fixed_assets', 'post') then raise exception 'ما عندك صلاحية ترحيل حركات الأصول'; end if;
  if m.status <> 'draft' then raise exception 'الحركة مرحّلة أو ملغاة'; end if;
  if not exists (select 1 from public.asset_movement_lines where movement_id = p_id) then raise exception 'ما في أصول بالحركة'; end if;
  perform public.ensure_company_settings(m.company_id);
  perform public.ensure_payroll_settings(m.company_id);
  select * into st from public.company_settings where company_id = m.company_id;
  prev_m := (date_trunc('month', m.mov_date) - interval '1 day')::date;
  descr := case m.kind when 'dispose' then 'استبعاد أصول' when 'sale' then 'بيع أصول' else 'نقل أصول بين الدوائر' end || ' — حركة ' || m.mov_no;

  if m.kind in ('dispose', 'sale') then
    select id into fy from public.fiscal_years where company_id = m.company_id and m.mov_date between start_date and end_date and not is_closed order by start_date desc limit 1;
    if fy is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ الحركة'; end if;
    disp := st.asset_disposal_account_id;
    if disp is null then raise exception 'حدّد حساب «أرباح وخسائر بيع وشطب الأصول» بحسابات الربط'; end if;
    if m.kind = 'sale' then
      select account_id into party_acc from public.parties where id = m.party_id;
      if party_acc is null then raise exception 'الزبون ما إله حساب'; end if;
      if m.total_tax > 0 and st.output_tax_account_id is null then raise exception 'حدّد حساب ضريبة المبيعات بحسابات الربط'; end if;
    end if;
    perform set_config('sumou.internal', public.internal_token(), true);
    insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
    values (m.company_id, fy, 'depreciation', m.mov_date, descr, coalesce(m.reference, 'حركة أصول ' || m.mov_no), 'draft') returning id into eid;
  else
    if not exists (select 1 from public.fiscal_years where company_id = m.company_id and m.mov_date between start_date and end_date and not is_closed) then
      raise exception 'ما في سنة مالية مفتوحة بتاريخ الحركة';
    end if;
    perform set_config('sumou.internal', public.internal_token(), true);
  end if;

  for r in select l.*, a.name, a.code, a.cost acost, a.salvage, a.dep_start, a.status astatus, a.department_id adept,
                  a.asset_account_id, a.accum_account_id, a.cost_center_id cc
             from public.asset_movement_lines l join public.fixed_assets a on a.id = l.asset_id
            where l.movement_id = p_id order by l.line_no for update of a loop
    if r.astatus <> 'active' then raise exception 'الأصل «%» مستبعد', r.name; end if;
    v_accum := least(greatest(coalesce(public.asset_accum(r.asset_id), 0), 0), r.acost);
    v_book := r.acost - v_accum;
    if public.asset_last_dep(r.asset_id) > (date_trunc('month', m.mov_date) + interval '1 month - 1 day')::date then
      raise exception 'الأصل «%» إله استهلاك مرحّل بعد شهر الحركة. ألغِ دورة الاستهلاك أو غيّر التاريخ', r.name;
    end if;
    if m.kind = 'transfer' and m.from_department_id is not null and r.adept is distinct from m.from_department_id then
      raise exception 'الأصل «%» ما عاد بالدائرة المنقول منها', r.name;
    end if;
    if m.kind in ('dispose', 'sale') then
      -- لازم يكون مستهلك لنهاية الشهر السابق (عشان القيمة الدفترية تكون صح)
      if r.dep_start <= prev_m and v_accum < r.acost - r.salvage - 0.0005
         and coalesce(public.asset_last_dep(r.asset_id), r.dep_start - 1) < prev_m then
        raise exception 'الأصل «%» لازم يكون مستهلك لنهاية %. رحّل الاستهلاك أول', r.name, to_char(prev_m, 'MM/YYYY');
      end if;
      acc_asset := r.asset_account_id; acc_accum := coalesce(r.accum_account_id, st.accum_dep_account_id);
      if acc_asset is null or acc_accum is null then raise exception 'حدّد حساب الأصل ومجمع الاستهلاك للأصل «%»', r.name; end if;
      -- مدين: المجمع، دائن: الأصل بالكلفة
      if v_accum > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, acc_accum, 'مجمع استهلاك ' || r.code || ' ' || r.name, v_accum, 0); end if;
      ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, cost_center_id) values (eid, ln, acc_asset, r.code || ' ' || r.name, 0, r.acost, r.cc);
      if m.kind = 'dispose' then
        if v_book > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, disp, 'خسارة استبعاد ' || r.code || ' ' || r.name, v_book, 0); end if;
      else
        ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, party_id) values (eid, ln, party_acc, 'بيع ' || r.code || ' ' || r.name, r.sale_price + r.tax_amount, 0, m.party_id);
        if r.tax_amount > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, st.output_tax_account_id, 'ضريبة بيع ' || r.code, 0, r.tax_amount); end if;
        gl := r.sale_price - v_book;   -- موجب = ربح (دائن)، سالب = خسارة (مدين)
        if gl <> 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, disp, case when gl > 0 then 'ربح بيع ' else 'خسارة بيع ' end || r.code || ' ' || r.name, greatest(-gl, 0), greatest(gl, 0)); end if;
      end if;
      update public.fixed_assets set status = 'disposed', disposed_date = m.mov_date where id = r.asset_id;
    else
      update public.fixed_assets set department_id = m.to_department_id where id = r.asset_id;
    end if;
    update public.asset_movement_lines set cost = r.acost, accum = v_accum, book_value = v_book, prev_status = r.astatus, prev_department_id = r.adept where id = r.id;
    t_cost := t_cost + r.acost; t_acc := t_acc + v_accum;
  end loop;

  if eid is not null then
    select sum(debit) into tot from public.journal_lines where entry_id = eid;
    if coalesce(tot, 0) = 0 or tot <> (select sum(credit) from public.journal_lines where entry_id = eid) then
      raise exception 'قيد الحركة مش متوازن، راجع بيانات الأصول (الكلفة ومجمع الاستهلاك السابق)';
    end if;
    update public.journal_entries set status = 'posted', total = tot, posted_by = auth.uid(), posted_at = now() where id = eid;
  end if;
  update public.asset_movements set status = 'posted', entry_id = eid, total_cost = t_cost, total_accum = t_acc, posted_at = now() where id = p_id;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), m.company_id, 'ترحيل', 'asset_movements', p_id::text, jsonb_build_object('no', m.mov_no, 'kind', m.kind));
  return eid;
end $$;

-- الإلغاء: المسودة بتنلغى؛ المرحّلة بقيد عكسي وبيرجع الأصل لحالته (إذا ما عليه حركة بعدها)
create or replace function public.asset_mov_cancel(p_id uuid, p_date date default null) returns void
language plpgsql security definer set search_path = public as $$
declare m public.asset_movements; nid uuid; r record; prev text := current_setting('sumou.internal', true);
begin
  select * into m from public.asset_movements where id = p_id for update;
  if m.id is null then raise exception 'الحركة مش موجودة'; end if;
  if not public.can(m.company_id, 'fixed_assets', case when m.status = 'posted' then 'post' else 'edit' end) then raise exception 'ما عندك صلاحية'; end if;
  if m.status = 'cancelled' then raise exception 'الحركة ملغاة من قبل'; end if;
  if m.status = 'posted' then
    for r in select l.asset_id, a.name, a.department_id dept from public.asset_movement_lines l join public.fixed_assets a on a.id = l.asset_id where l.movement_id = p_id loop
      if m.kind = 'transfer' and r.dept is distinct from m.to_department_id then
        raise exception 'الأصل «%» ما عاد بالدائرة المنقول لها، ما بينلغى النقل', r.name;
      end if;
      if exists (select 1 from public.asset_movement_lines x join public.asset_movements y on y.id = x.movement_id
                 where x.asset_id = r.asset_id and y.status = 'posted' and y.posted_at > m.posted_at) then
        raise exception 'على الأصل «%» حركة بعد هاي، ألغِها أول', r.name;
      end if;
      if m.kind in ('dispose', 'sale') and exists (select 1 from public.depreciation_lines dl join public.depreciation_runs dr on dr.id = dl.run_id
                 where dl.asset_id = r.asset_id and dr.status = 'posted' and dl.to_date >= m.mov_date) then
        raise exception 'الأصل «%» إله استهلاك مرحّل بعد تاريخ الحركة', r.name;
      end if;
    end loop;
    if m.entry_id is not null then
      nid := public.reverse_internal(m.entry_id, greatest(coalesce(p_date, public.local_today()), m.mov_date), 'إلغاء حركة أصول ' || m.mov_no);
    end if;
    perform set_config('sumou.internal', public.internal_token(), true);
    if m.kind = 'transfer' then
      update public.fixed_assets a set department_id = l.prev_department_id
        from public.asset_movement_lines l where l.movement_id = p_id and l.asset_id = a.id;
    else
      update public.fixed_assets a set status = coalesce(l.prev_status, 'active'),
             disposed_date = case when coalesce(l.prev_status, 'active') = 'active' then null else a.disposed_date end
        from public.asset_movement_lines l where l.movement_id = p_id and l.asset_id = a.id;
    end if;
  end if;
  update public.asset_movements set status = 'cancelled', cancel_entry_id = nid where id = p_id;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), m.company_id, 'إلغاء', 'asset_movements', p_id::text, jsonb_build_object('no', m.mov_no));
end $$;

create or replace function public.asset_mov_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m public.asset_movements;
begin
  select * into m from public.asset_movements where id = p_id;
  if m.id is null then return; end if;
  if not public.can(m.company_id, 'fixed_assets', 'delete') then raise exception 'ما عندك صلاحية'; end if;
  if m.status = 'posted' then raise exception 'الحركة مرحّلة، ألغِها بدل الحذف'; end if;
  if m.status <> 'draft' then raise exception 'الحركة الملغاة بتضل للسجل، ما بتنحذف'; end if;
  delete from public.asset_movements where id = p_id;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), m.company_id, 'حذف', 'asset_movements', p_id::text, jsonb_build_object('no', m.mov_no, 'kind', m.kind));
end $$;

revoke execute on function public.ensure_asset_disposal_account(uuid), public.asset_mov_save(jsonb), public.asset_mov_post(uuid),
  public.asset_mov_cancel(uuid, date), public.asset_mov_delete(uuid) from public, anon;
grant execute on function public.ensure_asset_disposal_account(uuid), public.asset_mov_save(jsonb), public.asset_mov_post(uuid),
  public.asset_mov_cancel(uuid, date), public.asset_mov_delete(uuid) to authenticated;

-- النسخ الاحتياطي: حركات الأصول بعد الاستهلاك
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1,  'companies',          'id = $1', 'code'),
   (2,  'fiscal_years',       'company_id = $1', 'start_date'),
   (3,  'accounts',           'company_id = $1', 'level, code'),
   (4,  'cost_centers',       'company_id = $1', 'code'),
   (5,  'currencies',         'company_id = $1', 'code'),
   (6,  'company_settings',   'company_id = $1', 'company_id'),
   (7,  'lookups',            'company_id = $1', 'parent_id nulls first, kind, code'),
   (8,  'custom_fields',      'company_id = $1', 'entity, sort'),
   (9,  'party_categories',   'company_id = $1', 'party_type, code'),
   (10, 'parties',            'company_id = $1', 'code'),
   (11, 'item_categories',    'company_id = $1', 'code'),
   (12, 'items',              'company_id = $1', 'code'),
   (13, 'promotions',         'company_id = $1', 'date_from'),
   (14, 'warehouses',         'company_id = $1', 'code'),
   (15, 'departments',        'company_id = $1', 'level, code'),
   (16, 'boms',               'company_id = $1', 'code'),
   (17, 'bom_lines',          'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (18, 'journal_entries',    'company_id = $1', 'created_at'),
   (19, 'journal_lines',      'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (20, 'invoices',           'company_id = $1', 'created_at'),
   (21, 'invoice_lines',      'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (22, 'orders',             'company_id = $1', 'created_at'),
   (23, 'order_lines',        'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (24, 'service_tickets',    'company_id = $1', 'ticket_no'),
   (25, 'cheques',            'company_id = $1', 'created_at'),
   (26, 'cheque_events',      'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (27, 'stock_docs',         'company_id = $1', 'created_at'),
   (28, 'stock_doc_lines',    'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (29, 'stock_moves',        'company_id = $1', 'created_at'),
   (30, 'productions',        'company_id = $1', 'prod_no'),
   (31, 'obligations',        'company_id = $1', 'due_date'),
   (32, 'recurring_entries',  'company_id = $1', 'created_at'),
   (33, 'employees',          'company_id = $1', 'code'),
   (34, 'payroll_runs',       'company_id = $1', 'period'),
   (35, 'payroll_lines',      'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (36, 'fixed_assets',       'company_id = $1', 'code'),
   (37, 'depreciation_runs',  'company_id = $1', 'created_at'),
   (38, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (39, 'asset_movements',    'company_id = $1', 'mov_no'),
   (40, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (41, 'bank_recons',        'company_id = $1', 'created_at'),
   (42, 'bank_cleared',       'company_id = $1', 'line_id'),
   (43, 'attachments',        'company_id = $1', 'created_at'),
   (44, 'fiscal_periods',     'company_id = $1', 'start_date');
$$;

-- إلغاء دورة استهلاك: ممنوع إذا أصل فيها انستبعد/انباع بحركة مرحّلة
create or replace function public.cancel_depreciation(p_run uuid, p_date date default current_date) returns void
language plpgsql security definer set search_path = public as $$
declare r public.depreciation_runs; nid uuid; nm text;
begin
  select * into r from public.depreciation_runs where id = p_run for update;
  if r.id is null or not public.can(r.company_id, 'fixed_assets', 'post') then raise exception 'ما عندك صلاحية'; end if;
  if r.status <> 'posted' then raise exception 'الدورة ملغاة من قبل'; end if;
  if exists (select 1 from public.depreciation_runs x where x.company_id = r.company_id and x.status = 'posted' and x.created_at > r.created_at) then
    raise exception 'ألغِ دورات الاستهلاك الأحدث أول';
  end if;
  select a.name into nm from public.depreciation_lines dl join public.fixed_assets a on a.id = dl.asset_id
   where dl.run_id = p_run and exists (select 1 from public.asset_movement_lines l join public.asset_movements m on m.id = l.movement_id
                                        where l.asset_id = dl.asset_id and m.status = 'posted' and m.kind in ('dispose', 'sale')) limit 1;
  if nm is not null then raise exception 'الأصل «%» انستبعد أو انباع بحركة مرحّلة؛ ألغِ الحركة أول', nm; end if;
  nid := public.reverse_internal(r.entry_id, greatest(p_date, r.period_to), 'إلغاء استهلاك لغاية ' || to_char(r.period_to, 'DD/MM/YYYY'));
  update public.depreciation_runs set status = 'cancelled', cancel_entry_id = nid where id = p_run;
  perform set_config('sumou.internal', '', true);
end $$;
