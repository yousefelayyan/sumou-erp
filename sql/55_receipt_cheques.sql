-- =====================================================================
--  السمو ERP — المرحلة 55: تسجيل الشيكات من جوّا سند القبض (مثل «الأوراق المالية» بـ Stallion)
--  كل شيك بينسجّل بالمحفظة بقيد استلام لحاله (register_cheque) وبينربط بالسند: cheques.receipt_entry_id.
--  وإذا ما في نقد، الشيكات بتنسجّل بدون سند.
-- =====================================================================
alter table public.cheques add column if not exists receipt_entry_id uuid references public.journal_entries(id) on delete set null;
create index if not exists cheques_receipt_entry_idx on public.cheques(receipt_entry_id) where receipt_entry_id is not null;

create or replace function public.ab_cheque_receipt_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then return new; end if;
  if tg_op = 'INSERT' and new.receipt_entry_id is not null then raise exception 'ربط الشيك بسند القبض من النظام بس'; end if;
  -- حذف السند بيفك الربط (on delete set null)
  if tg_op = 'UPDATE' and new.receipt_entry_id is null and old.receipt_entry_id is not null
     and not exists (select 1 from public.journal_entries where id = old.receipt_entry_id) then return new; end if;
  if tg_op = 'UPDATE' and new.receipt_entry_id is distinct from old.receipt_entry_id then raise exception 'ربط الشيك بسند القبض من النظام بس'; end if;
  return new;
end $$;
drop trigger if exists ab_cheque_receipt_guard on public.cheques;
create trigger ab_cheque_receipt_guard before insert or update of receipt_entry_id on public.cheques
  for each row execute function public.ab_cheque_receipt_guard();

-- p_entry: سند القبض (اختياري). p_rows: [{cheque_no, bank_name, branch, due_date, amount, drawer_name, endorser_name, notes}]
create or replace function public.receipt_cheques(p_company uuid, p_entry uuid, p_party uuid, p_date date, p_rows jsonb)
returns setof uuid language plpgsql security definer set search_path = public as $$
declare e public.journal_entries; pa public.parties; r jsonb; ch uuid; n int := 0; d date; ref text;
begin
  if p_company is null or not public.has_company(p_company) or not public.tenant_writable() then raise exception 'ما عندك صلاحية'; end if;
  if not (public.can(p_company, 'receipt_vouchers', 'add') or public.can(p_company, 'receipt_vouchers', 'edit')) then raise exception 'ما عندك صلاحية على سندات القبض'; end if;
  if not public.can(p_company, 'cheques', 'add') then raise exception 'ما عندك صلاحية تسجيل شيكات'; end if;
  select * into pa from public.parties where id = p_party and company_id = p_company;
  if pa.id is null then raise exception 'اختار العميل اللي استلمنا منه الشيكات'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'ما في شيكات'; end if;
  if jsonb_array_length(p_rows) > 50 then raise exception 'أكثر من 50 شيك بمرة وحدة'; end if;
  d := p_date;
  if p_entry is not null then
    select * into e from public.journal_entries where id = p_entry and company_id = p_company;
    if e.id is null or e.entry_type <> 'receipt' then raise exception 'السند مش سند قبض لهالشركة'; end if;
    if e.status in ('reversed','cancelled') or e.reversal_of is not null or e.is_frozen then raise exception 'السند معكوس أو مجمّد'; end if;
    if not public.dept_ok(p_company, e.department_id) then raise exception 'السند مش من فرعك'; end if;
    d := e.entry_date; ref := coalesce(e.doc_code, e.entry_no::text);
    if not exists (select 1 from public.journal_lines jl where jl.entry_id = e.id and jl.party_id = pa.id) then
      raise exception 'صاحب الشيكات لازم يكون نفس العميل اللي بسطور السند';
    end if;
  end if;
  if d is null then raise exception 'التاريخ مطلوب'; end if;
  if not exists (select 1 from public.fiscal_years where company_id = p_company and d between start_date and end_date and not coalesce(is_closed, false)) then
    raise exception 'ما في سنة مالية مفتوحة بهالتاريخ';
  end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    n := n + 1;
    if coalesce(trim(r ->> 'cheque_no'), '') = '' then raise exception 'الشيك رقم %: رقم الشيك مطلوب', n; end if;
    if nullif(r ->> 'due_date', '') is null then raise exception 'الشيك رقم %: تاريخ الاستحقاق مطلوب', n; end if;
    if coalesce((r ->> 'amount')::numeric, 0) <= 0 then raise exception 'الشيك رقم %: المبلغ لازم أكبر من صفر', n; end if;
    ch := public.register_cheque(jsonb_build_object('company_id', p_company, 'direction', 'in', 'party_id', pa.id,
            'cheque_no', trim(r ->> 'cheque_no'), 'bank_name', nullif(r ->> 'bank_name', ''), 'branch', nullif(r ->> 'branch', ''),
            'issue_date', d, 'due_date', r ->> 'due_date', 'amount', round((r ->> 'amount')::numeric, 3),
            'drawer_name', nullif(r ->> 'drawer_name', ''),
            'notes', coalesce(nullif(r ->> 'notes', ''), case when ref is not null then 'سند قبض رقم ' || ref end)));
    perform set_config('sumou.internal', public.internal_token(), true);
    update public.cheques set receipt_entry_id = p_entry, endorser_name = coalesce(nullif(r ->> 'endorser_name', ''), endorser_name) where id = ch;
    perform set_config('sumou.internal', '', true);
    return next ch;
  end loop;
end $$;
revoke all on function public.receipt_cheques(uuid, uuid, uuid, date, jsonb) from public, anon;
grant execute on function public.receipt_cheques(uuid, uuid, uuid, date, jsonb) to authenticated;
