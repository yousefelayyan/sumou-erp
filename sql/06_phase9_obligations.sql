-- =====================================================================
--  نظام السمو ERP — متابعة إقرارات العملاء ومواعيدها
--  التزامات كل شركة (ضريبة مبيعات، ضريبة دخل، اقتطاعات، ضمان اجتماعي، تجديدات...)
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

create table if not exists public.obligations (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  ob_type       text not null check (ob_type in ('sales_tax','income_tax','withholding','social_security','registration','license','audit','other')),
  title         text not null,
  period_label  text,                -- مثل: كانون الثاني - شباط 2026
  period_start  date,
  period_end    date,
  due_date      date not null,
  status        text not null default 'pending' check (status in ('pending','done','not_required')),
  done_date     date,
  amount        numeric(18,3),
  reference     text,                -- رقم الإقرار / رقم الإيصال
  assigned_to   uuid references public.profiles(id) on delete set null,
  notes         text,
  auto_key      text,                -- لمنع التكرار عند التوليد التلقائي
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  unique (company_id, auto_key)
);
create index if not exists obligations_due_idx on public.obligations (due_date);

-- توليد الالتزامات السنوية لشركة حسب بياناتها (المواعيد افتراضية وبتنعدّل)
create or replace function public.generate_obligations(p_company uuid, p_year int, p_social boolean default true, p_withholding boolean default true)
returns int
language plpgsql security definer set search_path = public as $$
declare c public.companies; n int := 0; i int; ps date; pe date; months text[] :=
  array['كانون الثاني','شباط','آذار','نيسان','أيار','حزيران','تموز','آب','أيلول','تشرين الأول','تشرين الثاني','كانون الأول'];
begin
  if not public.can(p_company, 'obligations', 'add') then raise exception 'ما عندك صلاحية'; end if;
  select * into c from public.companies where id = p_company;
  select count(*) into n from public.obligations where company_id = p_company;

  -- إقرار ضريبة الدخل السنوي عن السنة السابقة: آخر موعد 30 نيسان
  insert into public.obligations (company_id, ob_type, title, period_label, period_start, period_end, due_date, auto_key)
  values (p_company, 'income_tax', 'إقرار ضريبة الدخل السنوي', 'السنة المالية ' || (p_year - 1),
          make_date(p_year - 1, 1, 1), make_date(p_year - 1, 12, 31), make_date(p_year, 4, 30), 'IT-' || (p_year - 1))
  on conflict (company_id, auto_key) do nothing;

  -- ضريبة المبيعات: خلال 30 يوم من نهاية الفترة
  if c.subject_to_sales_tax then
    if c.sales_tax_period = 'monthly' then
      for i in 1..12 loop
        ps := make_date(p_year, i, 1); pe := (ps + interval '1 month - 1 day')::date;
        insert into public.obligations (company_id, ob_type, title, period_label, period_start, period_end, due_date, auto_key)
        values (p_company, 'sales_tax', 'إقرار ضريبة المبيعات', months[i] || ' ' || p_year, ps, pe, pe + 30, 'ST-' || p_year || '-' || i)
        on conflict (company_id, auto_key) do nothing;
      end loop;
    else
      for i in 1..6 loop
        ps := make_date(p_year, i * 2 - 1, 1); pe := (ps + interval '2 month - 1 day')::date;
        insert into public.obligations (company_id, ob_type, title, period_label, period_start, period_end, due_date, auto_key)
        values (p_company, 'sales_tax', 'إقرار ضريبة المبيعات', months[i * 2 - 1] || ' - ' || months[i * 2] || ' ' || p_year, ps, pe, pe + 30, 'ST-' || p_year || '-B' || i)
        on conflict (company_id, auto_key) do nothing;
      end loop;
    end if;
  end if;

  for i in 1..12 loop
    ps := make_date(p_year, i, 1); pe := (ps + interval '1 month - 1 day')::date;
    if p_withholding then   -- الاقتطاعات (رواتب/خدمات): خلال 30 يوم
      insert into public.obligations (company_id, ob_type, title, period_label, period_start, period_end, due_date, auto_key)
      values (p_company, 'withholding', 'كشف الاقتطاعات الشهري', months[i] || ' ' || p_year, ps, pe, pe + 30, 'WH-' || p_year || '-' || i)
      on conflict (company_id, auto_key) do nothing;
    end if;
    if p_social then        -- الضمان الاجتماعي: لغاية 15 من الشهر اللي بعده
      insert into public.obligations (company_id, ob_type, title, period_label, period_start, period_end, due_date, auto_key)
      values (p_company, 'social_security', 'اشتراكات الضمان الاجتماعي', months[i] || ' ' || p_year, ps, pe, (pe + 15), 'SS-' || p_year || '-' || i)
      on conflict (company_id, auto_key) do nothing;
    end if;
  end loop;

  n := (select count(*) from public.obligations where company_id = p_company) - n;
  insert into public.activity_log (user_id, company_id, action, entity, details)
  values (auth.uid(), p_company, 'توليد', 'obligations', jsonb_build_object('year', p_year));
  return n;
end $$;

alter table public.obligations enable row level security;
drop policy if exists ob_select on public.obligations;
create policy ob_select on public.obligations for select to authenticated using (public.can(company_id, 'obligations', 'view'));
drop policy if exists ob_insert on public.obligations;
create policy ob_insert on public.obligations for insert to authenticated with check (public.can(company_id, 'obligations', 'add'));
drop policy if exists ob_update on public.obligations;
create policy ob_update on public.obligations for update to authenticated
  using (public.can(company_id, 'obligations', 'edit')) with check (public.can(company_id, 'obligations', 'edit'));
drop policy if exists ob_delete on public.obligations;
create policy ob_delete on public.obligations for delete to authenticated using (public.can(company_id, 'obligations', 'delete'));

grant select, insert, update, delete on public.obligations to authenticated;
grant execute on function public.generate_obligations(uuid, int, boolean, boolean) to authenticated;

update public.user_groups set permissions = permissions || '{"obligations":{"view":true,"add":true,"edit":true,"print":true}}'::jsonb
 where name = 'محاسب' and not (permissions ? 'obligations');
update public.user_groups set permissions = permissions || '{"obligations":{"view":true,"print":true}}'::jsonb
 where name in ('مدخل بيانات', 'مشاهد') and not (permissions ? 'obligations');

-- انتهى ✅
