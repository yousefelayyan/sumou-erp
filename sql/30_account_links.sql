-- =====================================================================
--  السمو ERP — المرحلة 30: طبيعة «مدين ودائن» للحساب + ربط الموظف بحساب
--  الحساب ممكن يكون مرة مدين ومرة دائن (nature = 'both')؛ الرصيد بيظهر
--  بالجهة اللي طلع عليها. والموظف إله حساب من الدليل (مثل ذمم الموظفين).
-- =====================================================================

alter table public.accounts drop constraint if exists accounts_nature_check;
alter table public.accounts add constraint accounts_nature_check check (nature in ('debit', 'credit', 'both'));

alter table public.employees add column if not exists account_id uuid references public.accounts(id) on delete restrict;
create index if not exists employees_account_idx on public.employees (account_id) where account_id is not null;

create or replace function public.employee_account_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.account_id is not null and (tg_op = 'INSERT' or new.account_id is distinct from old.account_id)
     and not exists (select 1 from public.accounts a where a.id = new.account_id and a.company_id = new.company_id and not a.is_group) then
    raise exception 'حساب الموظف لازم يكون حساب فرعي من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists ad_employee_account_check on public.employees;
create trigger ad_employee_account_check before insert or update of account_id on public.employees
  for each row execute function public.employee_account_check();
