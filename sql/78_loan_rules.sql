-- =====================================================================
--  السمو ERP — المرحلة 78: ضوابط القروض وطلبات التأجيل والسلف من سندات الصرف
--  company_settings.loan_rules = {max_multiple, max_inst_pct, advance_max_pct, max_open, min_service_months, max_installments}
--  (الفاضي = بدون ضابط). loan_rule_issues(loan) بترجع المخالفات: طلب الموظف لحاله بينرفض، والاعتماد بينرفض إلا للمدير.
--  loan_installments.defer_request/defer_requested_at: الموظف بيطلب تأجيل قسط، والمشرف بيأجّل (loan_defer) أو بيرفض.
--  employee_loans.entry_id: سلفة انصرفت بسند صرف/قيد على حساب سلف الموظفين (سطر عليه الموظف) بتصير أقساط من الراتب (loan_from_entry).
-- =====================================================================
alter table public.company_settings add column if not exists loan_rules jsonb not null default '{}'::jsonb;
alter table public.loan_installments add column if not exists defer_request text;
alter table public.loan_installments add column if not exists defer_requested_at timestamptz;
alter table public.employee_loans add column if not exists entry_id uuid references public.journal_entries(id) on delete restrict;
create unique index if not exists employee_loans_entry_emp on public.employee_loans (entry_id, employee_id) where entry_id is not null and status <> 'cancelled';

-- الضوابط (المرحلة 78): قراءة بصلاحية payroll view وحفظ بـ payroll edit
create or replace function public.loan_rules_get(p_company uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public.can(p_company, 'payroll', 'view') or public.my_employee(p_company) is not null
    then coalesce((select loan_rules from public.company_settings where company_id = p_company), '{}'::jsonb) end;
$$;
create or replace function public.loan_rules_save(p_company uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare k text; r jsonb := '{}'::jsonb; v numeric;
begin
  if not public.can(p_company, 'payroll', 'edit') or not public.tenant_writable() then raise exception 'ما عندك صلاحية'; end if;
  foreach k in array array['max_multiple','max_inst_pct','advance_max_pct','max_open','min_service_months','max_installments'] loop
    if nullif(p ->> k, '') is not null then
      v := (p ->> k)::numeric;
      if v < 0 or v > 1000 then raise exception 'قيمة «%» مش منطقية', k; end if;
      r := r || jsonb_build_object(k, v);
    end if;
  end loop;
  perform public.ensure_company_settings(p_company);
  update public.company_settings set loan_rules = r where company_id = p_company;
end $$;

-- مخالفات الطلب للضوابط
create or replace function public.loan_rule_issues(p_loan uuid) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare l public.employee_loans; e public.employees; r jsonb; sal numeric; inst numeric; n int; out text[] := '{}';
begin
  select * into l from public.employee_loans where id = p_loan;
  if l.id is null then return out; end if;
  select * into e from public.employees where id = l.employee_id;
  r := coalesce((select loan_rules from public.company_settings where company_id = l.company_id), '{}'::jsonb);
  sal := coalesce(e.basic_salary, 0) + coalesce(e.allowances, 0);
  inst := l.amount / greatest(l.installments, 1);
  if r ? 'max_multiple' and sal > 0 and l.kind = 'loan' and l.amount > sal * (r ->> 'max_multiple')::numeric + 0.0005 then
    out := out || format('المبلغ أكثر من %s ضعف الراتب (%s)', r ->> 'max_multiple', round(sal * (r ->> 'max_multiple')::numeric, 3)); end if;
  if r ? 'max_inst_pct' and sal > 0 and l.kind = 'loan' and inst > sal * (r ->> 'max_inst_pct')::numeric / 100 + 0.0005 then
    out := out || format('القسط (%s) أكثر من %s%% من الراتب', round(inst, 3), r ->> 'max_inst_pct'); end if;
  if r ? 'advance_max_pct' and sal > 0 and l.kind = 'advance' and l.amount > sal * (r ->> 'advance_max_pct')::numeric / 100 + 0.0005 then
    out := out || format('السلفة أكثر من %s%% من الراتب (%s)', r ->> 'advance_max_pct', round(sal * (r ->> 'advance_max_pct')::numeric / 100, 3)); end if;
  if r ? 'max_installments' and l.installments > (r ->> 'max_installments')::numeric then
    out := out || format('عدد الأقساط أكثر من %s', r ->> 'max_installments'); end if;
  if r ? 'max_open' then
    select count(*) into n from public.employee_loans x where x.employee_id = l.employee_id and x.id <> l.id
       and (x.status = 'pending' or (x.status = 'approved' and exists (select 1 from public.loan_installments i where i.loan_id = x.id and i.status = 'pending')));
    if n >= (r ->> 'max_open')::numeric then out := out || format('عنده %s قرض/سلفة مفتوحة (الحد %s)', n, r ->> 'max_open'); end if;
  end if;
  if r ? 'min_service_months' and e.hire_date is not null
     and e.hire_date + make_interval(months => (r ->> 'min_service_months')::int) > l.request_date then
    out := out || format('مدة خدمته أقل من %s شهر', r ->> 'min_service_months'); end if;
  return out;
end $$;
revoke execute on function public.loan_rule_issues(uuid) from public, anon;
grant execute on function public.loan_rule_issues(uuid) to authenticated;

-- الطلب من الموظف لحاله بينرفض إذا خالف، والاعتماد بينرفض إلا للمدير
create or replace function public.zb_loan_rules_after() returns trigger
language plpgsql security definer set search_path = public as $$
declare iss text[];
begin
  if public.is_internal() or new.entry_id is not null then return null; end if;
  if tg_op = 'INSERT' and new.employee_id is distinct from public.my_employee(new.company_id) then return null; end if;
  if tg_op = 'UPDATE' and (not (old.status = 'pending' and new.status = 'approved') or public.is_admin()) then return null; end if;
  iss := public.loan_rule_issues(new.id);
  if array_length(iss, 1) > 0 then raise exception 'الطلب مخالف لضوابط القروض: %', array_to_string(iss, '، '); end if;
  return null;
end $$;
drop trigger if exists ab_loan_rules on public.employee_loans;
drop function if exists public.ab_loan_rules();
drop trigger if exists zb_loan_rules_after on public.employee_loans;
create constraint trigger zb_loan_rules_after after insert or update of status on public.employee_loans
  deferrable initially immediate for each row execute function public.zb_loan_rules_after();
revoke execute on function public.zb_loan_rules_after() from public, anon, authenticated;

-- طلب تأجيل قسط من الموظف نفسه
create or replace function public.loan_defer_request(p_inst uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare x public.loan_installments; l public.employee_loans;
begin
  select * into x from public.loan_installments where id = p_inst for update;
  select * into l from public.employee_loans where id = x.loan_id;
  if l.id is null then raise exception 'القسط مش موجود'; end if;
  if l.employee_id is distinct from public.my_employee(l.company_id) then raise exception 'بتقدر تطلب تأجيل أقساطك بس'; end if;
  if x.status <> 'pending' or l.status <> 'approved' then raise exception 'القسط مدفوع أو القرض مش فعّال'; end if;
  if x.defer_request is not null then raise exception 'في طلب تأجيل لهالقسط بالانتظار'; end if;
  update public.loan_installments set defer_request = coalesce(nullif(left(trim(p_note), 300), ''), 'طلب تأجيل'), defer_requested_at = now() where id = p_inst;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), l.company_id, 'طلب تأجيل', 'loan', l.id::text, jsonb_build_object('no', l.loan_no, 'seq', x.seq, 'month', x.due_month));
end $$;
create or replace function public.loan_defer_reject(p_inst uuid) returns void
language plpgsql security definer set search_path = public as $$
declare x public.loan_installments; l public.employee_loans;
begin
  select * into x from public.loan_installments where id = p_inst for update;
  select * into l from public.employee_loans where id = x.loan_id;
  if l.id is null or not public.can(l.company_id, 'payroll', 'post') then raise exception 'ما عندك صلاحية'; end if;
  update public.loan_installments set defer_request = null, defer_requested_at = null where id = p_inst;
end $$;
-- التأجيل بيمسح الطلب
create or replace function public.ab_loan_inst_defer_clear() returns trigger
language plpgsql as $$
begin
  if new.deferred > old.deferred or new.status = 'paid' then new.defer_request := null; new.defer_requested_at := null; end if;
  return new;
end $$;
drop trigger if exists ab_loan_inst_defer_clear on public.loan_installments;
create trigger ab_loan_inst_defer_clear before update on public.loan_installments for each row execute function public.ab_loan_inst_defer_clear();

-- سلفة من سند صرف/قيد مرحّل: سطر مدين على حساب سلف الموظفين وعليه الموظف
create or replace function public.loan_from_entry(p_entry uuid, p_employee uuid, p_installments int, p_first_month text) returns uuid
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries; st public.company_settings; amt numeric; lid uuid; no int; per numeric; m date; i int;
begin
  select * into e from public.journal_entries where id = p_entry;
  if e.id is null then raise exception 'السند مش موجود'; end if;
  if not public.can(e.company_id, 'payroll', 'add') or not public.can(e.company_id, 'payroll', 'post') or not public.tenant_writable() then
    raise exception 'بدها صلاحية إضافة واعتماد القروض'; end if;
  if e.status <> 'posted' or e.entry_type not in ('payment','journal') then raise exception 'لازم سند صرف أو قيد مرحّل'; end if;
  if exists (select 1 from public.journal_entries r where r.reversal_of = e.id) then raise exception 'السند معكوس'; end if;
  if not exists (select 1 from public.employees where id = p_employee and company_id = e.company_id) then raise exception 'الموظف مش من نفس الشركة'; end if;
  if coalesce(p_installments, 0) not between 1 and 120 then raise exception 'عدد الأقساط من 1 لـ 120'; end if;
  if p_first_month !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'شهر أول قسط مش صحيح'; end if;
  if p_first_month < to_char(public.local_today(), 'YYYY-MM') then raise exception 'شهر أول قسط فات'; end if;
  select * into st from public.company_settings where company_id = e.company_id;
  if st.advances_account_id is null then raise exception 'حدّد حساب سلف الموظفين بحسابات الربط'; end if;
  select round(coalesce(sum(debit - credit), 0), 3) into amt from public.journal_lines
   where entry_id = e.id and employee_id = p_employee and account_id = st.advances_account_id;
  if amt <= 0 then raise exception 'ما في بالسند مبلغ مدين على حساب سلف الموظفين لهالموظف'; end if;
  if exists (select 1 from public.employee_loans where entry_id = e.id and employee_id = p_employee and status <> 'cancelled') then
    raise exception 'السند محوّل لسلفة من قبل'; end if;
  perform pg_advisory_xact_lock(hashtext('loan:' || e.company_id));
  select coalesce(max(loan_no), 0) + 1 into no from public.employee_loans where company_id = e.company_id;
  insert into public.employee_loans (company_id, employee_id, loan_no, kind, request_date, amount, installments, first_month, reason, status, decided_by, decided_at, entry_id)
  values (e.company_id, p_employee, no, case when p_installments = 1 then 'advance' else 'loan' end, e.entry_date, amt, p_installments, p_first_month,
          'من سند رقم ' || coalesce(e.doc_code, e.entry_no::text), 'approved', auth.uid(), now(), e.id) returning id into lid;
  per := trunc(amt / p_installments, 3); m := (p_first_month || '-01')::date;
  for i in 1..p_installments loop
    insert into public.loan_installments (loan_id, employee_id, seq, due_month, amount)
    values (lid, p_employee, i, to_char(m + make_interval(months => i - 1), 'YYYY-MM'), case when i = p_installments then amt - per * (p_installments - 1) else per end);
  end loop;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), e.company_id, 'سلفة من سند', 'loan', lid::text, jsonb_build_object('no', no, 'amount', amt, 'entry', e.id));
  return lid;
end $$;
-- سند مربوط بسلفة فعّالة ما بيتعكس ولا بينلغى ترحيله
create or replace function public.ab_loan_entry_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'posted' and new.status <> 'posted'
     and exists (select 1 from public.employee_loans where entry_id = old.id and status in ('pending','approved','closed')) then
    raise exception 'السند مربوط بسلفة موظف؛ ألغِ السلفة أول (من القروض والسلف)';
  end if;
  return new;
end $$;
drop trigger if exists ab_loan_entry_guard on public.journal_entries;
create trigger ab_loan_entry_guard before update of status on public.journal_entries for each row execute function public.ab_loan_entry_guard();
revoke execute on function public.ab_loan_entry_guard(), public.ab_loan_inst_defer_clear() from public, anon, authenticated;
revoke execute on function public.loan_rules_get(uuid), public.loan_rules_save(uuid, jsonb), public.loan_defer_request(uuid, text), public.loan_defer_reject(uuid),
  public.loan_from_entry(uuid, uuid, int, text) from public, anon;
grant execute on function public.loan_rules_get(uuid), public.loan_rules_save(uuid, jsonb), public.loan_defer_request(uuid, text), public.loan_defer_reject(uuid),
  public.loan_from_entry(uuid, uuid, int, text) to authenticated;
