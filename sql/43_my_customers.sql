-- =====================================================================
--  السمو ERP — المرحلة 43: «زبائني» للمندوب
--  المندوب (lookups kind = sales_rep) بينربط بمستخدم (user_id)، والمسار (kind = route) إله أيام بالأسبوع (weekdays: 0 أحد … 6 سبت).
--  rep_customers_dash: حركات الفترة، أرقام الزبائن، حالتهم (نشط/متراجع/متوقف)، وأكثر وأقل الزبائن شراء.
-- =====================================================================
alter table public.lookups add column if not exists user_id uuid references auth.users(id) on delete set null;
alter table public.lookups add column if not exists weekdays int[];

create or replace function public.ad_lookup_rep_user_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.user_id is not null then
    if new.kind <> 'sales_rep' then new.user_id := null;
    elsif not exists (select 1 from public.profiles p join public.companies c on c.id = new.company_id and c.tenant_id = p.tenant_id where p.id = new.user_id) then
      raise exception 'المستخدم مش من نفس المشترك';
    end if;
  end if;
  if new.weekdays is not null then
    if new.kind <> 'route' then new.weekdays := null;
    elsif exists (select 1 from unnest(new.weekdays) d where d not between 0 and 6) then raise exception 'أيام المسار مش صحيحة';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists ad_lookup_rep_user_check on public.lookups;
create trigger ad_lookup_rep_user_check before insert or update of user_id, weekdays, kind on public.lookups for each row execute function public.ad_lookup_rep_user_check();

-- p_rep: مندوب معيّن (للمشرف)؛ null = مندوبي أنا (أو الكل للمشرف إذا p_all)؛ p_day: يوم المسار
create or replace function public.rep_customers_dash(p_company uuid, p_from date, p_to date, p_rep uuid default null, p_day int default null, p_all boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare sup boolean := public.can(p_company, 'rep_visits', 'edit') or public.can(p_company, 'reports', 'view');
  reps uuid[]; res jsonb; today date := public.local_today();
begin
  if not (public.can(p_company, 'rep_visits', 'view') or sup) then raise exception 'ما عندك صلاحية'; end if;
  if p_rep is not null then
    if not sup and not exists (select 1 from public.lookups where id = p_rep and company_id = p_company and kind = 'sales_rep' and user_id = auth.uid()) then
      raise exception 'هالمندوب مش إلك';
    end if;
    reps := array[p_rep];
  elsif p_all and sup then reps := null;
  else
    select array_agg(id) into reps from public.lookups where company_id = p_company and kind = 'sales_rep' and user_id = auth.uid();
    if reps is null then reps := '{}'; end if;
  end if;
  with cust as (
    select p.id, p.code, p.name from public.parties p left join public.lookups r on r.id = p.route_id
     where p.company_id = p_company and p.party_type = 'customer' and p.is_active
       and (reps is null or p.sales_rep_id = any (reps))
       and (p_day is null or p_day = any (coalesce(r.weekdays, '{}')))
  ), inv as (
    select v.party_id, v.inv_date, case when v.inv_type = 'sale_return' then -1 else 1 end * v.total amt, v.inv_type
      from public.invoices v where v.company_id = p_company and v.status = 'posted' and v.inv_type in ('sale','sale_return') and v.party_id in (select id from cust)
       and public.dept_ok(p_company, v.department_id)
  ), per as (select * from inv where inv_date between p_from and p_to),
  pay as (
    select l.party_id, sum(l.credit - l.debit) amt from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
     where e.company_id = p_company and e.status = 'posted' and e.entry_type in ('receipt','cheque') and e.entry_date between p_from and p_to
       and l.party_id in (select id from cust) and public.dept_ok(p_company, e.department_id)
     group by l.party_id
  ), ord as (
    select o.party_id, o.total from public.orders o where o.company_id = p_company and o.order_type = 'sales_order' and o.status <> 'cancelled'
       and o.order_date between p_from and p_to and o.party_id in (select id from cust)
  ), last as (select party_id, max(inv_date) d, min(inv_date) first_d from inv where inv_type = 'sale' group by party_id),
  sales as (select party_id, sum(amt) s, count(*) filter (where inv_type = 'sale') n from per group by party_id)
  select jsonb_build_object(
    'payments', coalesce((select sum(amt) from pay), 0), 'payments_n', (select count(*) from pay where amt > 0),
    'invoices', coalesce((select sum(amt) from per), 0), 'invoices_n', (select count(*) from per where inv_type = 'sale'),
    'orders', coalesce((select sum(total) from ord), 0), 'orders_n', (select count(*) from ord),
    'customers', (select count(*) from cust),
    'buyers', (select count(*) from sales where s > 0),
    'first_time', (select count(*) from last where first_d between p_from and p_to),
    'payers', (select count(*) from pay where amt > 0),
    'avg_invoice', coalesce((select round(sum(amt) filter (where inv_type = 'sale') / nullif(count(*) filter (where inv_type = 'sale'), 0), 3) from per), 0),
    'active', (select count(*) from cust c join last l on l.party_id = c.id where today - l.d <= 30),
    'slipping', (select count(*) from cust c join last l on l.party_id = c.id where today - l.d between 31 and 60),
    'stopped', (select count(*) from cust c join last l on l.party_id = c.id where today - l.d > 60),
    'never', (select count(*) from cust c where not exists (select 1 from last l where l.party_id = c.id)),
    'top', coalesce((select jsonb_agg(x) from (select c.id, c.code, c.name, round(s.s, 3) amount, s.n from sales s join cust c on c.id = s.party_id where s.s > 0 order by s.s desc limit 10) x), '[]'),
    'bottom', coalesce((select jsonb_agg(x) from (select c.id, c.code, c.name, round(coalesce(s.s, 0), 3) amount, coalesce(s.n, 0) n, l.d last_date
                         from cust c left join sales s on s.party_id = c.id left join last l on l.party_id = c.id order by coalesce(s.s, 0), c.name limit 10) x), '[]'),
    'reps', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name), '[]') from public.lookups where company_id = p_company and kind = 'sales_rep' and is_active
              and (sup or user_id = auth.uid())),
    'routes_days', (select coalesce(jsonb_agg(distinct d), '[]') from public.lookups r, unnest(r.weekdays) d where r.company_id = p_company and r.kind = 'route'),
    'supervisor', sup, 'has_rep', array_length(reps, 1) is not null or reps is null)
  into res;
  return res;
end $$;
grant execute on function public.rep_customers_dash(uuid, date, date, uuid, int, boolean) to authenticated;
revoke execute on function public.rep_customers_dash(uuid, date, date, uuid, int, boolean) from anon;
