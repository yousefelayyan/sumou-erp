\set ON_ERROR_STOP 0
-- فحص مندوبي المبيعات (المرحلة 24)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
\set F 'f0000000-0000-0000-0000-000000000001'
insert into lookups(id,company_id,kind,code,name,rate) values ('1c000000-0000-0000-0000-000000000024',:'C','sales_rep','01','خالد',2.5) returning kind, rate;
\echo == customer default rep
update parties set sales_rep_id='1c000000-0000-0000-0000-000000000024' where company_id=:'C' and party_type='customer' and code=(select min(code) from parties where company_id=:'C' and party_type='customer') returning code;
\echo == new invoice takes the customer rep
insert into invoices(company_id,fiscal_year_id,inv_type,inv_date,payment_type,party_id)
 values (:'C',:'F','sale','2026-07-01','credit',(select id from parties where sales_rep_id='1c000000-0000-0000-0000-000000000024' limit 1))
 returning (select name from lookups where id=sales_rep_id) as rep;
\echo == a bank as rep (expected ERROR)
update parties set sales_rep_id=(select id from lookups where kind='bank' and company_id=:'C' limit 1) where company_id=:'C' and party_type='customer';
insert into lookups(id,company_id,kind,code,name) values ('1c000000-0000-0000-0000-000000000025',:'C','bank','24','بنك فحص') on conflict do nothing;
update invoices set sales_rep_id='1c000000-0000-0000-0000-000000000025' where inv_date='2026-07-01' and company_id=:'C';
\echo == inactive rep on a new invoice (expected ERROR)
update lookups set is_active=false where id='1c000000-0000-0000-0000-000000000024';
insert into invoices(company_id,fiscal_year_id,inv_type,inv_date,payment_type,party_id,sales_rep_id)
 values (:'C',:'F','sale','2026-07-02','credit',(select id from parties where sales_rep_id='1c000000-0000-0000-0000-000000000024' limit 1),'1c000000-0000-0000-0000-000000000024');
update lookups set is_active=true where id='1c000000-0000-0000-0000-000000000024';
reset role;
