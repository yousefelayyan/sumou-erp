-- =====================================================================
--  المرحلة 92: عمولة وسيلة الدفع بفواتير البيع النقدية ونقطة البيع
--  invoices.payment_method_id = وسيلة الدفع اللي انختارت بالفاتورة (نقطة البيع بتستعمل pos_method_id).
--  بعد ترحيل فاتورة بيع نقدية: إذا الوسيلة إلها نسبة عمولة وحساب عمولة (المرحلة 48)، سطر الصندوق/البنك بينزل
--  بالعمولة وبينضاف سطر مدين على حساب العمولة (يعني البنك بياخذ الصافي). القيد العكسي (إلغاء الفاتورة) بينسخهم.
-- =====================================================================
alter table public.invoices add column if not exists payment_method_id uuid references public.lookups(id) on delete set null;
alter table public.invoices add column if not exists pm_commission numeric(18,3) not null default 0;

create or replace function public.ad_invoice_pm_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.payment_method_id is not null and (tg_op = 'INSERT' or new.payment_method_id is distinct from old.payment_method_id)
     and not exists (select 1 from public.lookups where id = new.payment_method_id and company_id = new.company_id and kind = 'payment_method') then
    raise exception 'وسيلة الدفع مش من هالشركة';
  end if;
  if new.payment_type <> 'cash' then new.payment_method_id := null; end if;
  if not public.is_internal() then new.pm_commission := coalesce(case when tg_op = 'UPDATE' then old.pm_commission end, 0); end if;
  return new;
end $$;
drop trigger if exists ad_invoice_pm_check on public.invoices;
create trigger ad_invoice_pm_check before insert or update on public.invoices for each row execute function public.ad_invoice_pm_check();
revoke execute on function public.ad_invoice_pm_check() from public, anon, authenticated;

create or replace function public.zj_invoice_pm_commission() returns trigger
language plpgsql security definer set search_path = public as $$
declare pm public.lookups; c numeric; cl public.journal_lines; ln int; prev text := current_setting('sumou.internal', true);
begin
  if not (old.status = 'draft' and new.status = 'posted' and new.inv_type = 'sale' and new.payment_type = 'cash' and new.entry_id is not null) then return null; end if;
  if new.pm_commission <> 0 then
    perform set_config('sumou.internal', public.internal_token(), true);
    update public.invoices set pm_commission = 0 where id = new.id;
    perform set_config('sumou.internal', coalesce(prev, ''), true);
  end if;
  select * into pm from public.lookups where id = coalesce(new.payment_method_id, new.pos_method_id) and company_id = new.company_id and kind = 'payment_method';
  if pm.id is null or coalesce(pm.rate, 0) <= 0 or pm.commission_account_id is null then return null; end if;
  c := round(new.total * pm.rate / 100, 3);
  if c <= 0 then return null; end if;
  select * into cl from public.journal_lines where entry_id = new.entry_id and debit > 0
     and account_id = coalesce(new.cash_account_id, (select cash_account_id from public.company_settings where company_id = new.company_id)) order by line_no limit 1;
  if cl.id is null or cl.debit < c then return null; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.journal_lines set debit = debit - c where id = cl.id;
  select coalesce(max(line_no), 0) + 1 into ln from public.journal_lines where entry_id = new.entry_id;
  insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, cost_center_id)
  values (new.entry_id, ln, pm.commission_account_id, 'عمولة ' || pm.name || ' ' || pm.rate || '% — ' || coalesce(cl.description, 'فاتورة بيع'), c, 0, cl.cost_center_id);
  update public.invoices set pm_commission = c where id = new.id;
  if (select abs(sum(debit) - sum(credit)) from public.journal_lines where entry_id = new.entry_id) > 0.0005 then raise exception 'قيد الفاتورة مش متوازن بعد العمولة'; end if;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  return null;
end $$;
drop trigger if exists zj_invoice_pm_commission on public.invoices;
create trigger zj_invoice_pm_commission after update of status on public.invoices for each row execute function public.zj_invoice_pm_commission();
revoke execute on function public.zj_invoice_pm_commission() from public, anon, authenticated;
