-- =====================================================================
--  السمو ERP — المرحلة 27: حساب «الإنتاج تحت التشغيل» لأوامر الإنتاج (الجرد المستمر)
--  سند إخراج المواد: من ح/ الإنتاج تحت التشغيل إلى ح/ المخزون
--  سند إدخال المنتج:  من ح/ المخزون إلى ح/ الإنتاج تحت التشغيل (كلفة المواد + الكلفة الإضافية)
--  الكلفة الإضافية (أجور، تشغيل) بتنقيّد على نفس الحساب بسند قيد، فبيتصفّر.
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

alter table public.company_settings add column if not exists wip_account_id uuid references public.accounts(id) on delete set null;

-- سندات أمر الإنتاج بتاخذ حساب الإنتاج تحت التشغيل كحساب مقابل
create or replace function public.ab_production_wip() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.production_id is not null and new.account_id is null then
    select wip_account_id into new.account_id from public.company_settings where company_id = new.company_id;
  end if;
  return new;
end $$;
drop trigger if exists ab_production_wip on public.stock_docs;
create trigger ab_production_wip before insert on public.stock_docs
  for each row execute function public.ab_production_wip();

-- إنشاء الحساب لحاله (أخ لحساب المخزون) وربطه
create or replace function public.ensure_wip_account(p_company uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare st public.company_settings; inv public.accounts; aid uuid; c text; n int := 1;
begin
  if not (public.can(p_company, 'accounts', 'add') and public.can(p_company, 'companies', 'edit')) then raise exception 'ما عندك صلاحية'; end if;
  select * into st from public.company_settings where company_id = p_company;
  if st.wip_account_id is not null then return st.wip_account_id; end if;
  select * into inv from public.accounts where id = st.inventory_account_id;
  if inv.id is null then
    select * into inv from public.accounts where company_id = p_company and code = '1105' and not is_group;
  end if;
  if inv.id is null then raise exception 'حدّد حساب المخزون أول بشاشة «حسابات الربط»'; end if;
  select id into aid from public.accounts where company_id = p_company and name = 'الإنتاج تحت التشغيل' and not is_group limit 1;
  if aid is null then
    loop
      c := coalesce((select code from public.accounts where id = inv.parent_id), left(inv.code, greatest(length(inv.code) - 2, 1))) || lpad((90 + n)::text, 2, '0');
      exit when not exists (select 1 from public.accounts where company_id = p_company and code = c);
      n := n + 1; if n > 9 then raise exception 'ما لقيت رمز فاضي للحساب، اعمله بإيدك من دليل الحسابات'; end if;
    end loop;
    insert into public.accounts (company_id, code, name, parent_id, level, is_group, category, nature, account_type)
    values (p_company, c, 'الإنتاج تحت التشغيل', inv.parent_id, inv.level, false, 'assets', 'debit', 'general') returning id into aid;
  end if;
  update public.company_settings set wip_account_id = aid where company_id = p_company;
  -- سندات الإنتاج المسودة اللي ما إلها حساب
  update public.stock_docs set account_id = aid
   where company_id = p_company and production_id is not null and account_id is null and entry_id is null and status = 'draft';
  return aid;
end $$;
grant execute on function public.ensure_wip_account(uuid) to authenticated;
