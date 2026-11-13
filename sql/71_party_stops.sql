-- =====================================================================
--  السمو ERP — المرحلة 71: إيقاف البيع على العميل وفئته
--  parties / party_categories: stop_credit (وقف البيع الآجل)، stop_cheques (وقف استلام شيكات منه)،
--  stop_if_debit (وقف البيع الآجل إذا عليه رصيد مدين). العلامة على الفئة بتنطبق على كل عملائها.
--  المنع وقت ترحيل فاتورة البيع (حتى من الكاشير والعقود) ووقت تسجيل الشيك الوارد؛ التجاوز للمدير أو شاشة credit_override edit.
-- =====================================================================
alter table public.parties add column if not exists stop_credit boolean not null default false;
alter table public.parties add column if not exists stop_cheques boolean not null default false;
alter table public.parties add column if not exists stop_if_debit boolean not null default false;
alter table public.party_categories add column if not exists stop_credit boolean not null default false;
alter table public.party_categories add column if not exists stop_cheques boolean not null default false;
alter table public.party_categories add column if not exists stop_if_debit boolean not null default false;

-- العلامات الفعلية للطرف (الطرف أو فئته)
create or replace function public.party_stops(p_party uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'stop_credit',   coalesce(p.stop_credit, false)   or coalesce(c.stop_credit, false),
    'stop_cheques',  coalesce(p.stop_cheques, false)  or coalesce(c.stop_cheques, false),
    'stop_if_debit', coalesce(p.stop_if_debit, false) or coalesce(c.stop_if_debit, false),
    'by_category',   coalesce(c.stop_credit or c.stop_cheques or c.stop_if_debit, false),
    'category',      c.name)
    from public.parties p left join public.party_categories c on c.id = p.category_id
   where p.id = p_party and public.has_company(p.company_id);
$$;
revoke execute on function public.party_stops(uuid) from public, anon;
grant execute on function public.party_stops(uuid) to authenticated;

create or replace function public.ab_party_stop_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare s jsonb; bal numeric;
begin
  if new.inv_type <> 'sale' or new.party_id is null then return new; end if;
  if not (new.status = 'posted' and old.status = 'draft') then return new; end if;
  s := public.party_stops(new.party_id);
  if s is null or not ((s ->> 'stop_credit')::boolean or (s ->> 'stop_if_debit')::boolean) then return new; end if;
  if new.payment_type <> 'credit' then return new; end if;
  if public.is_admin() or public.can(new.company_id, 'credit_override', 'edit') then return new; end if;
  if (s ->> 'stop_credit')::boolean then
    raise exception 'البيع الآجل موقوف على هالعميل%. بدها صلاحية «تجاوز سقف الائتمان وإيقاف البيع»',
      case when (s ->> 'by_category')::boolean then ' (أو على فئته «' || coalesce(s ->> 'category', '') || '»)' else '' end;
  end if;
  bal := public.party_balance_fy(new.party_id, new.fiscal_year_id)
       - coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                    where l.entry_id = new.entry_id and l.party_id = new.party_id and e.status in ('posted','reversed')), 0);
  if bal > 0.0005 then
    raise exception 'العميل عليه رصيد مدين % والبيع الآجل موقوف لحد ما يسدّد. بدها صلاحية «تجاوز سقف الائتمان وإيقاف البيع»', round(bal, 3);
  end if;
  return new;
end $$;
drop trigger if exists ab_party_stop_check on public.invoices;
create trigger ab_party_stop_check before update of status on public.invoices for each row execute function public.ab_party_stop_check();

-- الشيك الوارد من عميل موقوفة شيكاته (الحركات القديمة = استرجاع، ما بتتفحص)
create or replace function public.ab_cheque_party_stop() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.direction <> 'in' or new.party_id is null then return new; end if;
  if new.created_at < now() - interval '2 minutes' then return new; end if;
  if not coalesce((public.party_stops(new.party_id) ->> 'stop_cheques')::boolean, false) then return new; end if;
  if public.is_admin() or public.can(new.company_id, 'credit_override', 'edit') then return new; end if;
  raise exception 'استلام الشيكات موقوف من هالعميل. بدها صلاحية «تجاوز سقف الائتمان وإيقاف البيع»';
end $$;
drop trigger if exists ab_cheque_party_stop on public.cheques;
create trigger ab_cheque_party_stop before insert on public.cheques for each row execute function public.ab_cheque_party_stop();
revoke execute on function public.ab_party_stop_check(), public.ab_cheque_party_stop() from public, anon, authenticated;
