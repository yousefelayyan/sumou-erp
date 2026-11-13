\set ON_ERROR_STOP 0
-- شيكات الضمان (المرحلة 81)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
select id as cust from parties where company_id=:'C' and party_type='customer' order by code limit 1 \gset
insert into guarantee_cheques (company_id, direction, cheque_no, bank_name, party_id, amount, due_date, purpose, status, cheque_id)
values (:'C','in','G-100','البنك العربي',:'cust',5000,null,'ضمان عقد توريد','converted',null) returning doc_no, status, cheque_id is null as no_link \gset
\echo :doc_no :status :no_link
select id as g from guarantee_cheques where company_id=:'C' and cheque_no='G-100' \gset
insert into guarantee_cheques (company_id, direction, cheque_no, drawer_name, amount, purpose) values (:'C','out','G-200','مؤسسة المناقصات',750,'كفالة دخول عطاء') returning doc_no;
\echo == user cannot set status directly (stays held)
update guarantee_cheques set status = 'returned', amount = 5100 where id = :'g' returning status, amount;
select guarantee_set_status(:'g', 'returned', '2026-10-01', 'انتهى العقد') \g /dev/null
\echo == edit amount after return (expected ERROR)
update guarantee_cheques set amount = 5200 where id = :'g';
update guarantee_cheques set notes = 'ملاحظة' where id = :'g' returning notes;
\echo == convert a returned cheque (expected ERROR)
select guarantee_convert(:'g', '{}');
select guarantee_set_status(:'g', 'held') \g /dev/null
select count(*) as before_cheques from cheques where company_id=:'C' \gset
select guarantee_convert(:'g', '{"date":"2026-10-05","due_date":"2026-10-20"}') is not null as converted;
select g.status, c.status as cheque_status, c.amount, c.due_date, (select count(*) from cheques where company_id=:'C') - :before_cheques as new_cheques
  from guarantee_cheques g join cheques c on c.id = g.cheque_id where g.id = :'g';
\echo == undo a converted cheque (expected ERROR)
select guarantee_set_status(:'g', 'held');
\echo == delete a converted guarantee (expected ERROR)
delete from guarantee_cheques where id = :'g';
\echo == party from another company (expected ERROR)
insert into guarantee_cheques (company_id, direction, cheque_no, party_id, amount) values (:'C','in','X1',gen_random_uuid(),10);
\echo == user without rights sees nothing
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false) \g /dev/null
select count(*) from guarantee_cheques;
reset role;
delete from guarantee_cheques where cheque_no = 'G-200';
