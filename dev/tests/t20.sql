\set ON_ERROR_STOP 0
-- فحص بطاقات المصاريف (المرحلة 20)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\echo == expense card on an expense account, auto code E0001
insert into parties(company_id,party_type,name,account_id) values (:'C','expense','كهرباء',(select id from accounts a where company_id=:'C' and category='expenses' and not is_group limit 1)) returning code, party_type;
\echo == expense card on a non-expense account (expected ERROR)
insert into parties(company_id,party_type,name,account_id) values (:'C','expense','غلط',(select id from accounts where company_id=:'C' and account_type='cash' and not is_group limit 1));
\echo == bad party type (expected ERROR)
insert into parties(company_id,party_type,name,account_id) values (:'C','other','غلط',(select id from accounts a where company_id=:'C' and category='expenses' and not is_group limit 1));
\echo == expense category
insert into party_categories(company_id,party_type,code,name) values (:'C','expense','1','مصاريف إدارية') returning party_type;
update parties set category_id=(select id from party_categories where party_type='expense' and company_id=:'C') where party_type='expense' and company_id=:'C' returning code;
\echo == customer category on expense card (expected ERROR)
insert into party_categories(id,company_id,party_type,code,name) values ('9c000000-0000-0000-0000-000000000020',:'C','customer','20','زبائن');
update parties set category_id='9c000000-0000-0000-0000-000000000020' where party_type='expense' and company_id=:'C';
\echo == payment voucher line with expense card, then party movements
do $$ declare e uuid; p public.parties; cash uuid; begin
  select * into p from public.parties where party_type='expense' and company_id='c0000000-0000-0000-0000-000000000001' limit 1;
  select id into cash from public.accounts where company_id=p.company_id and account_type='cash' and not is_group limit 1;
  insert into public.journal_entries(company_id,fiscal_year_id,entry_type,entry_date,description,cash_account_id)
   values (p.company_id,'f0000000-0000-0000-0000-000000000001','payment','2026-03-01','فاتورة كهرباء',cash) returning id into e;
  insert into public.journal_lines(entry_id,line_no,account_id,party_id,debit,credit) values (e,1,p.account_id,p.id,50,0),(e,2,cash,null,0,50);
  perform public.post_entry(e);
end $$;
select party_id is not null as ok, debit from rep_party_movements(:'C','f0000000-0000-0000-0000-000000000001','expense','2026-12-31');
\echo == employee without expense_cards rights sees no add (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
insert into parties(company_id,party_type,name,account_id) values (:'C','expense','ممنوع',(select id from accounts a where company_id=:'C' and category='expenses' and not is_group limit 1));
reset role;
