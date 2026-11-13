-- =====================================================================
--  السمو ERP — المرحلة 46: القروض والسلف و«راتبي»
--  employees.user_id: الموظف ↔ مستخدم البرنامج (عشان «راتبي» وطلب القرض من حسابه)
--  employee_loans + loan_installments: طلب (الموظف أو الموارد البشرية) → اعتماد المشرف (payroll post) → أقساط شهرية
--  الأقساط المستحقة بتنخصم لحالها بمسيّر الرواتب (advances) وبتصير مدفوعة لما يترحّل، وبترجع لما ينلغى.
--  تأجيل قسط: بينقل لآخر الجدول. «راتبي»: my_payroll() و my_loans() للموظف المربوط.
-- =====================================================================
alter table public.employees add column if not exists user_id uuid references auth.users(id) on delete set null;
create unique index if not exists employees_user_uq on public.employees (company_id, user_id) where user_id is not null;

create or replace function public.ad_employee_user_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- الاسترجاع/نسخ التجربة: الربط المكرر بنفس المستخدم بينشال
  if new.user_id is not null and public.is_internal() and exists (select 1 from public.employees x where x.company_id = new.company_id and x.user_id = new.user_id and x.id <> new.id) then
    new.user_id := null;
  end if;
  if new.user_id is not null and (tg_op = 'INSERT' or new.user_id is distinct from old.user_id)
     and not exists (select 1 from public.profiles p join public.companies c on c.id = new.company_id and c.tenant_id = p.tenant_id where p.id = new.user_id) then
    if public.is_internal() then new.user_id := null; else raise exception 'المستخدم مش من نفس المشترك'; end if;   -- الاسترجاع على قاعدة ثانية
  end if;
  return new;
end $$;
drop trigger if exists ad_employee_user_check on public.employees;
create trigger ad_employee_user_check before insert or update of user_id on public.employees for each row execute function public.ad_employee_user_check();

create or replace function public.my_employee(p_company uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select e.id from public.employees e where e.company_id = p_company and e.user_id = auth.uid() and public.has_company(p_company) limit 1;
$$;

create table if not exists public.employee_loans (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  employee_id     uuid not null references public.employees(id) on delete restrict,
  loan_no         int not null,
  kind            text not null default 'loan' check (kind in ('loan','advance')),
  request_date    date not null default current_date,
  amount          numeric(18,3) not null check (amount > 0),
  installments    int not null default 1 check (installments between 1 and 120),
  first_month     text not null check (first_month ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  reason          text,
  employee_note   text,
  supervisor_note text,
  status          text not null default 'pending' check (status in ('pending','approved','rejected','cancelled','closed')),
  decided_by      uuid,
  decided_at      timestamptz,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  unique (company_id, loan_no)
);
create table if not exists public.loan_installments (
  id          uuid primary key default gen_random_uuid(),
  loan_id     uuid not null references public.employee_loans(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  seq         int not null,
  due_month   text not null,
  amount      numeric(18,3) not null check (amount > 0),
  status      text not null default 'pending' check (status in ('pending','paid')),
  deferred    int not null default 0,
  paid_run_id uuid references public.payroll_runs(id) on delete set null,
  paid_at     timestamptz,
  unique (loan_id, seq)
);
-- القسط محجوز بمسيّر رواتب (مسودة) من وقت التعبئة لحد الترحيل؛ حذف المسيّر بيفكّ الحجز
alter table public.loan_installments add column if not exists run_id uuid references public.payroll_runs(id) on delete set null;
create index if not exists loan_inst_emp on public.loan_installments (employee_id, status, due_month);

alter table public.employee_loans enable row level security;
alter table public.loan_installments enable row level security;
revoke insert, update, delete on public.employee_loans, public.loan_installments from authenticated;
grant select on public.employee_loans, public.loan_installments to authenticated;
-- الموارد البشرية بتشوف الكل؛ الموظف بيشوف قروضه
drop policy if exists el_select on public.employee_loans;
create policy el_select on public.employee_loans for select to authenticated using (
  public.can(company_id, 'payroll', 'view') or employee_id = public.my_employee(company_id));
drop policy if exists li_select on public.loan_installments;
create policy li_select on public.loan_installments for select to authenticated using (
  exists (select 1 from public.employee_loans l where l.id = loan_id));



-- طلب قرض/سلفة: p = {company_id, employee_id (للموارد البشرية؛ الموظف بياخذ حاله)، kind, amount, installments, first_month, reason, note}
create or replace function public.loan_request(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid := (p ->> 'company_id')::uuid; emp uuid; me uuid; amt numeric := round(coalesce(nullif(p ->> 'amount', '')::numeric, 0), 3);
  n int := coalesce(nullif(p ->> 'installments', '')::int, 1); fm text := coalesce(nullif(p ->> 'first_month', ''), to_char(public.local_today() + interval '1 month', 'YYYY-MM'));
  lid uuid; no int;
begin
  if not public.tenant_writable() then raise exception 'الاشتراك منتهي'; end if;
  me := public.my_employee(cid);
  emp := nullif(p ->> 'employee_id', '')::uuid;
  if emp is null or emp = me then
    if me is null then raise exception 'حسابك مش مربوط بموظف'; end if;
    emp := me;
  elsif not public.can(cid, 'payroll', 'add') then raise exception 'ما عندك صلاحية تسجيل قروض لموظفين';
  end if;
  if not exists (select 1 from public.employees where id = emp and company_id = cid and is_active) then raise exception 'الموظف مش موجود'; end if;
  if amt <= 0 then raise exception 'المبلغ لازم أكبر من صفر'; end if;
  if n < 1 or n > 120 then raise exception 'عدد الأقساط من 1 لـ 120'; end if;
  if amt < n * 0.001 then raise exception 'المبلغ صغير على عدد الأقساط'; end if;
  if not exists (select 1 from public.tenants t join public.companies c on c.tenant_id = t.id where c.id = cid
                   and (t.modules is null or public.screen_module('payroll') = 'core' or public.screen_module('payroll') = any (t.modules))) then
    raise exception 'قسم الرواتب مش ضمن اشتراكك';
  end if;
  if fm !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'شهر أول قسط مش صحيح'; end if;
  perform pg_advisory_xact_lock(hashtext('loan:' || cid));
  select coalesce(max(loan_no), 0) + 1 into no from public.employee_loans where company_id = cid;
  insert into public.employee_loans (company_id, employee_id, loan_no, kind, amount, installments, first_month, reason, employee_note)
  values (cid, emp, no, case when p ->> 'kind' = 'advance' then 'advance' else 'loan' end, amt, n, fm, left(nullif(trim(p ->> 'reason'), ''), 300), left(nullif(trim(p ->> 'note'), ''), 1000))
  returning id into lid;
  return lid;
end $$;

-- اعتماد/رفض (المشرف = payroll post): الاعتماد بيولّد الأقساط
create or replace function public.loan_decide(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare l public.employee_loans; i int; per numeric; m date;
begin
  select * into l from public.employee_loans where id = p_id for update;
  if l.id is null then raise exception 'الطلب مش موجود'; end if;
  if not public.can(l.company_id, 'payroll', 'post') then raise exception 'الاعتماد للمشرف (ترحيل الرواتب)'; end if;
  if l.status <> 'pending' then raise exception 'الطلب مش بالانتظار'; end if;
  if l.employee_id = public.my_employee(l.company_id) and not public.is_admin() then raise exception 'ما بتقدر تعتمد طلبك'; end if;
  if not p_approve then
    update public.employee_loans set status = 'rejected', supervisor_note = left(nullif(trim(p_note), ''), 1000), decided_by = auth.uid(), decided_at = now() where id = p_id;
    insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
    values (auth.uid(), l.company_id, 'رفض', 'loan', p_id::text, jsonb_build_object('no', l.loan_no, 'amount', l.amount));
    return;
  end if;
  if not exists (select 1 from public.employees where id = l.employee_id and is_active) then raise exception 'الموظف مش على رأس عمله'; end if;
  if l.first_month < to_char(public.local_today(), 'YYYY-MM') then raise exception 'شهر أول قسط (%) فات؛ لازم من الشهر الحالي أو بعده', l.first_month; end if;
  per := trunc(l.amount / l.installments, 3);
  m := (l.first_month || '-01')::date;
  for i in 1..l.installments loop
    insert into public.loan_installments (loan_id, employee_id, seq, due_month, amount)
    values (l.id, l.employee_id, i, to_char(m + make_interval(months => i - 1), 'YYYY-MM'),
            case when i = l.installments then l.amount - per * (l.installments - 1) else per end);
  end loop;
  update public.employee_loans set status = 'approved', supervisor_note = left(nullif(trim(p_note), ''), 1000), decided_by = auth.uid(), decided_at = now() where id = p_id;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), l.company_id, 'موافقة', 'loan', p_id::text, jsonb_build_object('no', l.loan_no, 'amount', l.amount));
end $$;

-- فك حجز قسط عن مسيّر مسودة: بينزّل مبلغه من «خصم السلف» بسطر الموظف
create or replace function public.loan_release(p_inst uuid) returns void
language plpgsql security definer set search_path = public as $$
declare x public.loan_installments;
begin
  select * into x from public.loan_installments where id = p_inst;
  if x.run_id is null or x.status <> 'pending' then return; end if;
  update public.payroll_lines set advances = greatest(0, advances - x.amount) where run_id = x.run_id and employee_id = x.employee_id;
  update public.loan_installments set run_id = null where id = p_inst;
end $$;
revoke execute on function public.loan_release(uuid) from public, anon, authenticated;

-- تأجيل قسط: بينقل لشهر بعد آخر قسط
create or replace function public.loan_defer(p_inst uuid) returns void
language plpgsql security definer set search_path = public as $$
declare x public.loan_installments; l public.employee_loans; lastm text;
begin
  select * into x from public.loan_installments where id = p_inst for update;
  select * into l from public.employee_loans where id = x.loan_id;
  if l.id is null then raise exception 'القسط مش موجود'; end if;
  if not public.can(l.company_id, 'payroll', 'post') then raise exception 'التأجيل للمشرف'; end if;
  if x.status <> 'pending' or l.status <> 'approved' then raise exception 'القسط مدفوع أو القرض مش فعّال'; end if;
  if l.employee_id = public.my_employee(l.company_id) and not public.is_admin() then raise exception 'ما بتقدر تأجّل قسطك'; end if;
  perform public.loan_release(p_inst);
  select max(due_month) into lastm from public.loan_installments where loan_id = l.id;
  update public.loan_installments set due_month = to_char((lastm || '-01')::date + interval '1 month', 'YYYY-MM'), deferred = deferred + 1 where id = p_inst;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), l.company_id, 'تأجيل', 'loan', l.id::text, jsonb_build_object('no', l.loan_no, 'seq', x.seq, 'from', x.due_month));
end $$;

create or replace function public.loan_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l public.employee_loans;
begin
  select * into l from public.employee_loans where id = p_id for update;
  if l.id is null then raise exception 'الطلب مش موجود'; end if;
  if not public.tenant_writable() then raise exception 'الاشتراك منتهي'; end if;
  if not (public.can(l.company_id, 'payroll', 'post') or (l.status = 'pending' and l.employee_id = public.my_employee(l.company_id))) then raise exception 'ما عندك صلاحية'; end if;
  if l.status not in ('pending','approved') then raise exception 'الطلب منتهي'; end if;
  if exists (select 1 from public.loan_installments where loan_id = p_id and status = 'paid') then raise exception 'في أقساط انخصمت؛ ما بينلغى'; end if;
  perform public.loan_release(i.id) from public.loan_installments i where i.loan_id = p_id;
  delete from public.loan_installments where loan_id = p_id;
  update public.employee_loans set status = 'cancelled' where id = p_id;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), l.company_id, 'إلغاء', 'loan', p_id::text, jsonb_build_object('no', l.loan_no, 'amount', l.amount));
end $$;

-- تعليق الموظف/المشرف
create or replace function public.loan_comment(p_id uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare l public.employee_loans;
begin
  select * into l from public.employee_loans where id = p_id;
  if l.id is null then raise exception 'الطلب مش موجود'; end if;
  if not public.tenant_writable() then raise exception 'الاشتراك منتهي'; end if;
  if l.employee_id = public.my_employee(l.company_id) and not public.can(l.company_id, 'payroll', 'post') then
    if l.status not in ('pending','approved') then raise exception 'الطلب منتهي'; end if;
    update public.employee_loans set employee_note = left(nullif(trim(p_note), ''), 1000) where id = p_id;
  elsif public.can(l.company_id, 'payroll', 'post') then
    update public.employee_loans set supervisor_note = left(nullif(trim(p_note), ''), 1000) where id = p_id;
  else raise exception 'ما عندك صلاحية'; end if;
end $$;

-- بعد ترحيل المسيّر: الأقساط المستحقة بتصير مدفوعة بحدود «خصم السلف» لكل موظف
create or replace function public.loan_mark_paid(p_run uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.payroll_runs;
begin
  select * into r from public.payroll_runs where id = p_run;
  update public.loan_installments set status = 'paid', paid_run_id = p_run, paid_at = now(), run_id = null where run_id = p_run and status = 'pending';
  update public.employee_loans l set status = 'closed' where l.company_id = r.company_id and l.status = 'approved'
     and not exists (select 1 from public.loan_installments i where i.loan_id = l.id and i.status = 'pending');
end $$;
revoke execute on function public.loan_mark_paid(uuid) from public, anon, authenticated;

-- «راتبي»: قسائم الرواتب المرحّلة للموظف المربوط بالمستخدم
create or replace function public.my_payroll(p_company uuid)
returns table (period text, run_date date, basic numeric, allowances numeric, overtime numeric, other_add numeric, gross numeric,
               ss_employee numeric, income_tax numeric, advances numeric, other_ded numeric, net numeric, notes text, emp_name text)
language sql stable security definer set search_path = public as $$
  select r.period, r.run_date, l.basic, l.allowances, l.overtime, l.other_add, l.gross, l.ss_employee, l.income_tax, l.advances, l.other_ded, l.net, l.notes, e.name
    from public.payroll_lines l join public.payroll_runs r on r.id = l.run_id join public.employees e on e.id = l.employee_id
   where e.id = public.my_employee(p_company) and r.status = 'posted'
   order by r.period desc limit 36;
$$;

-- مستخدمين الشركة لربطهم بالموظفين (للموارد البشرية)
create or replace function public.company_users(p_company uuid) returns table (id uuid, username text, full_name text)
language sql stable security definer set search_path = public as $$
  select p.id, p.username, p.full_name from public.profiles p
   where public.can(p_company, 'payroll', 'edit') and p.is_active and p.tenant_id = (select c.tenant_id from public.companies c where c.id = p_company)
     and (p.is_admin or exists (select 1 from public.user_companies uc where uc.user_id = p.id and uc.company_id = p_company))
   order by p.username;
$$;
revoke execute on function public.company_users(uuid) from public, anon;
grant execute on function public.company_users(uuid) to authenticated;

revoke execute on function public.loan_request(jsonb), public.loan_decide(uuid, boolean, text), public.loan_defer(uuid), public.loan_cancel(uuid),
  public.loan_comment(uuid, text), public.my_payroll(uuid), public.my_employee(uuid) from public, anon;
grant execute on function public.loan_request(jsonb), public.loan_decide(uuid, boolean, text), public.loan_defer(uuid), public.loan_cancel(uuid),
  public.loan_comment(uuid, text), public.my_payroll(uuid), public.my_employee(uuid) to authenticated;

create or replace function public.payroll_fill(p_run uuid) returns int
language plpgsql security definer set search_path = public as $$
declare r public.payroll_runs; st public.company_settings; n int;
begin
  select * into r from public.payroll_runs where id = p_run;
  if r.id is null then raise exception 'المسيّر مش موجود'; end if;
  if not public.can(r.company_id, 'payroll', 'edit') then raise exception 'ما عندك صلاحية على الرواتب'; end if;
  if r.status <> 'draft' then raise exception 'مسيّر الرواتب مرحّل'; end if;
  perform public.ensure_payroll_settings(r.company_id);
  select * into st from public.company_settings where company_id = r.company_id;
  delete from public.payroll_lines where run_id = p_run;
  insert into public.payroll_lines (run_id, employee_id, basic, allowances, ss_wage, ss_employee, ss_employer, income_tax)
  select p_run, e.id, e.basic_salary, e.allowances, w.wage,
         case when e.ss_subject then round(w.wage * st.ss_employee_rate / 100, 3) else 0 end,
         case when e.ss_subject then round(w.wage * st.ss_employer_rate / 100, 3) else 0 end,
         e.income_tax
  from public.employees e
  cross join lateral (select case when not e.ss_subject then 0
                                  when st.ss_ceiling > 0 then least(coalesce(e.ss_wage, e.basic_salary + e.allowances), st.ss_ceiling)
                                  else coalesce(e.ss_wage, e.basic_salary + e.allowances) end as wage) w
  where e.company_id = r.company_id and e.is_active
    and (e.hire_date is null or e.hire_date <= (r.period || '-01')::date + interval '1 month' - interval '1 day')
    and (e.end_date is null or e.end_date >= (r.period || '-01')::date);
  get diagnostics n = row_count;
  -- أقساط القروض والسلف المستحقة لهالشهر (والمتأخرة) بتنخصم لحالها
  -- كل قسط بيتحجز لمسيّر واحد بس (المسيّرات الثانية ما بتعدّه)
  update public.loan_installments set run_id = null where run_id = p_run and status = 'pending';
  update public.loan_installments i set run_id = p_run
    from public.employee_loans ln, public.payroll_lines pl
   where ln.id = i.loan_id and ln.company_id = r.company_id and ln.status = 'approved' and i.status = 'pending' and i.run_id is null
     and i.due_month <= r.period and pl.run_id = p_run and pl.employee_id = i.employee_id;
  update public.payroll_lines l set advances = x.amt, notes = coalesce(l.notes || ' — ', '') || 'أقساط: ' || x.n
    from (select i.employee_id, sum(i.amount) amt, count(*) n from public.loan_installments i where i.run_id = p_run and i.status = 'pending' group by i.employee_id) x
   where l.run_id = p_run and l.employee_id = x.employee_id;
  return n;
end $$;

create or replace function public.post_payroll(p_run uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare r public.payroll_runs; st public.company_settings; fy uuid; eid uuid; ln int := 0; s record; ln_chk record; descr text; d date;
begin
  select * into r from public.payroll_runs where id = p_run for update;
  if r.id is null then raise exception 'المسيّر مش موجود'; end if;
  if not public.can(r.company_id, 'payroll', 'post') then raise exception 'ما عندك صلاحية ترحيل الرواتب'; end if;
  if r.status <> 'draft' then raise exception 'المسيّر مرحّل من قبل'; end if;
  perform public.ensure_payroll_settings(r.company_id);
  select * into st from public.company_settings where company_id = r.company_id;
  if st.salaries_account_id is null or st.salaries_payable_account_id is null or st.ss_payable_account_id is null or st.ss_expense_account_id is null then
    raise exception 'حدّد حسابات الرواتب بشاشة «حسابات الربط»';
  end if;
  select coalesce(sum(gross),0) g, coalesce(sum(ss_employee),0) se, coalesce(sum(ss_employer),0) sr, coalesce(sum(income_tax),0) t,
         coalesce(sum(advances),0) a, coalesce(sum(other_ded),0) o, coalesce(sum(net),0) n, count(*) c into s
    from public.payroll_lines where run_id = p_run;
  if s.c = 0 or s.g <= 0 then raise exception 'المسيّر فاضي'; end if;
  -- «خصم السلف» لازم يغطي الأقساط المحجوزة لكل موظف
  select e.name, x.amt, coalesce(pl.advances, 0) adv into ln_chk from (select employee_id, sum(amount) amt from public.loan_installments where run_id = p_run and status = 'pending' group by employee_id) x
    join public.employees e on e.id = x.employee_id left join public.payroll_lines pl on pl.run_id = p_run and pl.employee_id = x.employee_id
   where coalesce(pl.advances, 0) + 0.0005 < x.amt limit 1;
  if ln_chk.name is not null then
    raise exception '«خصم السلف» للموظف % (%) أقل من أقساط القروض المستحقة (%)؛ عدّله أو أجّل القسط', ln_chk.name, ln_chk.adv, ln_chk.amt;
  end if;
  if s.t > 0 and st.wht_payable_account_id is null then raise exception 'حدّد حساب أمانات ضريبة الدخل'; end if;
  if s.a > 0 and st.advances_account_id is null then raise exception 'حدّد حساب ذمم/سلف الموظفين'; end if;
  d := r.run_date;
  select id into fy from public.fiscal_years where company_id = r.company_id and d between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ المسيّر'; end if;
  descr := 'رواتب شهر ' || r.period;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (r.company_id, fy, 'payroll', d, descr, 'رواتب ' || r.period, 'draft') returning id into eid;
  -- المصروف (حسب مركز كلفة الموظف)
  for s in select e.cost_center_id cc, sum(l.gross) g, sum(l.ss_employer) sr from public.payroll_lines l join public.employees e on e.id = l.employee_id
           where l.run_id = p_run group by 1 loop
    if s.g > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, cost_center_id) values (eid, ln, st.salaries_account_id, descr, s.g, 0, s.cc); end if;
    if s.sr > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, cost_center_id) values (eid, ln, st.ss_expense_account_id, 'حصة المنشأة بالضمان - ' || descr, s.sr, 0, s.cc); end if;
  end loop;
  select coalesce(sum(ss_employee),0) se, coalesce(sum(ss_employer),0) sr, coalesce(sum(income_tax),0) t, coalesce(sum(advances),0) a,
         coalesce(sum(other_ded),0) o, coalesce(sum(net),0) n into s from public.payroll_lines where run_id = p_run;
  if s.se + s.sr > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, st.ss_payable_account_id, 'اشتراكات الضمان - ' || descr, 0, s.se + s.sr); end if;
  if s.t > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, st.wht_payable_account_id, 'ضريبة دخل مقتطعة - ' || descr, 0, s.t); end if;
  if s.a > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, st.advances_account_id, 'خصم سلف - ' || descr, 0, s.a); end if;
  -- الخصومات الأخرى (جزاءات/غياب) بتخفّض مصروف الرواتب
  if s.o > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, st.salaries_account_id, 'خصومات أخرى - ' || descr, 0, s.o); end if;
  if s.n > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, st.salaries_payable_account_id, 'صافي الرواتب المستحقة - ' || descr, 0, s.n); end if;
  if (select sum(debit) - sum(credit) from public.journal_lines where entry_id = eid) <> 0 then raise exception 'قيد الرواتب مش متوازن'; end if;
  update public.journal_entries set status = 'posted', total = (select sum(debit) from public.journal_lines where entry_id = eid), posted_by = auth.uid(), posted_at = now() where id = eid;
  update public.payroll_runs set status = 'posted', entry_id = eid where id = p_run;
  -- الأقساط اللي انخصمت بهالمسيّر صارت مدفوعة (بالترتيب لحد مبلغ «خصم السلف» بالسطر)
  perform public.loan_mark_paid(p_run);
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details) values (auth.uid(), r.company_id, 'ترحيل', 'payroll', p_run::text, jsonb_build_object('period', r.period));
  return eid;
end $$;

create or replace function public.cancel_payroll(p_run uuid, p_date date default current_date) returns void
language plpgsql security definer set search_path = public as $$
declare r public.payroll_runs; nid uuid;
begin
  select * into r from public.payroll_runs where id = p_run for update;
  if not public.can(r.company_id, 'payroll', 'post') then raise exception 'ما عندك صلاحية'; end if;
  if r.status <> 'posted' then raise exception 'بس المسيّر المرحّل بينلغى'; end if;
  nid := public.reverse_internal(r.entry_id, p_date, 'إلغاء رواتب شهر ' || r.period);
  update public.payroll_runs set status = 'cancelled', cancel_entry_id = nid where id = p_run;
  update public.loan_installments set status = 'pending', paid_run_id = null, paid_at = null, run_id = null where paid_run_id = p_run;
  update public.employee_loans set status = 'approved' where status = 'closed' and id in (select loan_id from public.loan_installments where status = 'pending');
  perform set_config('sumou.internal', '', true);
end $$;

-- النسخ الاحتياطي: القروض بعد الرواتب
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
   (19, 'boms', 'company_id = $1', 'code'),
   (20, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (21, 'journal_entries', 'company_id = $1', 'created_at'),
   (22, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (23, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (24, 'invoices', 'company_id = $1', 'created_at'),
   (25, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (26, 'orders', 'company_id = $1', 'created_at'),
   (27, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (28, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (29, 'cheques', 'company_id = $1', 'created_at'),
   (30, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (31, 'supply_requests', 'company_id = $1', 'req_no'),
   (32, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (33, 'stock_docs', 'company_id = $1', 'created_at'),
   (34, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (35, 'stock_moves', 'company_id = $1', 'created_at'),
   (36, 'productions', 'company_id = $1', 'prod_no'),
   (37, 'obligations', 'company_id = $1', 'due_date'),
   (38, 'recurring_entries', 'company_id = $1', 'created_at'),
   (39, 'employees', 'company_id = $1', 'code'),
   (40, 'payroll_runs', 'company_id = $1', 'period'),
   (41, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (42, 'employee_loans', 'company_id = $1', 'loan_no'),
   (43, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (44, 'asset_custodians', 'company_id = $1', 'code'),
   (45, 'fixed_assets', 'company_id = $1', 'code'),
   (46, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (47, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (48, 'asset_movements', 'company_id = $1', 'mov_no'),
   (49, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (50, 'custody_docs', 'company_id = $1', 'doc_no'),
   (51, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (52, 'bank_recons', 'company_id = $1', 'created_at'),
   (53, 'bank_cleared', 'company_id = $1', 'line_id'),
   (54, 'attachments', 'company_id = $1', 'created_at'),
   (55, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
