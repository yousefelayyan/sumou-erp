-- =====================================================================
--  السمو ERP — المرحلة 77: مندوب لكل سطر وهيكل المندوبين
--  invoice_lines.sales_rep_id: مندوب السطر (فاتورة بيع/مرتجع بيع)، الفاضي = مندوب الفاتورة.
--  lookups.supervisor_id (المشرف/المدير المباشر، مندوب ثاني من نفس الشركة، بدون دوائر) و lookups.rep_role (rep/supervisor/manager).
--  rep_commissions انعادت تعريفها: صافي المبيعات حسب مندوب السطر.
-- =====================================================================
alter table public.invoice_lines add column if not exists sales_rep_id uuid references public.lookups(id) on delete restrict;
alter table public.lookups add column if not exists supervisor_id uuid references public.lookups(id) on delete set null deferrable initially deferred;   -- مؤجل عشان الاسترجاع
alter table public.lookups add column if not exists rep_role text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'lookups_rep_role_chk') then
    alter table public.lookups add constraint lookups_rep_role_chk check (rep_role is null or rep_role in ('rep','supervisor','manager'));
  end if;
end $$;

create or replace function public.ab_rep_hierarchy_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare cur uuid; n int := 0;
begin
  if new.kind <> 'sales_rep' then new.supervisor_id := null; new.rep_role := null; return new; end if;
  if new.supervisor_id is not null and not public.is_internal() then
    if new.supervisor_id = new.id then raise exception 'المندوب ما بيكون مشرف على حاله'; end if;
    if not exists (select 1 from public.lookups where id = new.supervisor_id and company_id = new.company_id and kind = 'sales_rep') then
      raise exception 'المشرف لازم يكون مندوب من نفس الشركة'; end if;
    cur := new.supervisor_id;
    while cur is not null and n < 30 loop
      if cur = new.id then raise exception 'هيكل المندوبين فيه دائرة (المشرف تابع للمندوب نفسه)'; end if;
      select supervisor_id into cur from public.lookups where id = cur; n := n + 1;
    end loop;
  end if;
  return new;
end $$;
drop trigger if exists ab_rep_hierarchy_check on public.lookups;
create trigger ab_rep_hierarchy_check before insert or update of supervisor_id, rep_role, kind on public.lookups for each row execute function public.ab_rep_hierarchy_check();

create or replace function public.ab_line_rep_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv public.invoices;
begin
  if new.sales_rep_id is null then return new; end if;
  if tg_op = 'UPDATE' and new.sales_rep_id is not distinct from old.sales_rep_id then return new; end if;
  select * into inv from public.invoices where id = new.invoice_id;
  if inv.inv_type not in ('sale','sale_return') then new.sales_rep_id := null; return new; end if;
  if not exists (select 1 from public.lookups l where l.id = new.sales_rep_id and l.company_id = inv.company_id and l.kind = 'sales_rep'
                 and (l.is_active or public.is_internal())) then
    raise exception 'مندوب السطر مش موجود أو مش فعّال بهالشركة';
  end if;
  return new;
end $$;
drop trigger if exists ab_line_rep_check on public.invoice_lines;
create trigger ab_line_rep_check before insert or update of sales_rep_id on public.invoice_lines for each row execute function public.ab_line_rep_check();
revoke execute on function public.ab_rep_hierarchy_check(), public.ab_line_rep_check() from public, anon, authenticated;

-- حساب العمولات (المرحلة 77: صافي المبيعات حسب مندوب السطر)
create or replace function public.rep_commissions(p_company uuid, p_from date, p_to date)
returns table (rep_id uuid, month date, plan_id uuid, basis text, target numeric, sales numeric, returns numeric, net_sales numeric,
               collections numeric, base numeric, achieved_pct numeric, rate numeric, commission numeric, bonus numeric, total numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare own uuid[];
begin
  if p_to < p_from or p_to > p_from + 731 then raise exception 'الفترة مش صحيحة (لحد سنتين)'; end if;
  if not public.can(p_company, 'rep_commissions', 'view') then
    if not public.has_company(p_company) then raise exception 'ما عندك صلاحية'; end if;
    select array_agg(id) into own from public.lookups where company_id = p_company and kind = 'sales_rep' and user_id = auth.uid();
    if own is null then raise exception 'ما عندك صلاحية'; end if;
  end if;
  return query
  with reps as (
    select l.id, l.rate, l.commission_plan_id from public.lookups l
     where l.company_id = p_company and l.kind = 'sales_rep' and (own is null or l.id = any (own))),
  months as (select generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month')::date m),
  inv as (   -- على مستوى السطر: مندوب السطر أولاً ثم مندوب الفاتورة (المرحلة 77)
    select coalesce(il.sales_rep_id, i.sales_rep_id, o.sales_rep_id) rep, date_trunc('month', i.inv_date)::date m, i.inv_type, il.subtotal
      from public.invoices i join public.invoice_lines il on il.invoice_id = i.id
      left join public.invoices o on o.id = i.original_invoice_id
     where i.company_id = p_company and i.status = 'posted' and i.inv_type in ('sale','sale_return')
       and i.inv_date between date_trunc('month', p_from)::date and (date_trunc('month', p_to) + interval '1 month - 1 day')::date
       and public.dept_ok(p_company, i.department_id)),
  col as (
    select i.sales_rep_id rep, date_trunc('month', e.entry_date)::date m, sum(a.amount) amt
      from public.invoice_allocations a join public.invoices i on i.id = a.invoice_id join public.journal_entries e on e.id = a.entry_id
     where a.company_id = p_company and i.inv_type = 'sale' and public.alloc_live(a.entry_id) and public.dept_ok(p_company, i.department_id)
       and e.entry_date between date_trunc('month', p_from)::date and (date_trunc('month', p_to) + interval '1 month - 1 day')::date
     group by 1, 2),
  base as (
    select r.id rep, mo.m, r.rate flat, p.id pid, coalesce(p.basis, 'sales') basis, p.tiers, p.no_target_rate, p.bonus_at_pct, p.bonus_amount,
           t.target,
           coalesce((select sum(subtotal) from inv where inv.rep = r.id and inv.m = mo.m and inv.inv_type = 'sale'), 0) s,
           coalesce((select sum(subtotal) from inv where inv.rep = r.id and inv.m = mo.m and inv.inv_type = 'sale_return'), 0) rt,
           coalesce((select amt from col where col.rep = r.id and col.m = mo.m), 0) c
      from reps r cross join months mo
      left join public.commission_plans p on p.id = r.commission_plan_id and p.is_active
      left join public.rep_targets t on t.rep_id = r.id and t.month = mo.m),
  calc as (
    select b.*, b.s - b.rt ns, case when b.basis = 'collections' then b.c else b.s - b.rt end bs from base b),
  pct as (
    select c.*, case when coalesce(c.target, 0) > 0 then round(c.bs * 100 / c.target, 2) end ach from calc c),
  rated as (
    select p.*,
      case when p.pid is null then coalesce(p.flat, 0)
           when p.ach is null then p.no_target_rate
           else coalesce((select (x ->> 'rate')::numeric from jsonb_array_elements(p.tiers) x
                           where (x ->> 'min_pct')::numeric <= p.ach order by (x ->> 'min_pct')::numeric desc limit 1), 0) end rt_pct,
      case when p.pid is not null and p.bonus_at_pct is not null and p.ach is not null and p.ach >= p.bonus_at_pct then p.bonus_amount else 0 end bn
      from pct p)
  select r.rep, r.m, r.pid, r.basis, r.target, round(r.s, 3), round(r.rt, 3), round(r.ns, 3), round(r.c, 3), round(r.bs, 3), r.ach, r.rt_pct,
         round(greatest(r.bs, 0) * r.rt_pct / 100, 3), r.bn, round(greatest(r.bs, 0) * r.rt_pct / 100, 3) + r.bn
    from rated r
   where r.s <> 0 or r.rt <> 0 or r.c <> 0 or r.target is not null
   order by r.m, r.rep;
end $$;
revoke execute on function public.rep_commissions(uuid, date, date) from public, anon;
grant execute on function public.rep_commissions(uuid, date, date) to authenticated;
