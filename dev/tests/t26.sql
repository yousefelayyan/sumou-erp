\set ON_ERROR_STOP 0
-- فحص التصنيع والصيانة (المرحلة 26)
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
\set C 'c0000000-0000-0000-0000-000000000001'
insert into items(id,company_id,code,name,item_type,sale_price) values
 ('1e000000-0000-0000-0000-000000000001',:'C','MFG-P1','عصير جاهز','goods',5),
 ('1e000000-0000-0000-0000-000000000002',:'C','MFG-R1','برتقال كيلو','goods',1),
 ('1e000000-0000-0000-0000-000000000003',:'C','MFG-R2','علبة فاضية','goods',0.1) on conflict do nothing;
\echo == stock in raw materials
do $$ declare d uuid; w uuid; begin
  select id into w from public.warehouses where company_id='c0000000-0000-0000-0000-000000000001' limit 1;
  insert into public.stock_docs(company_id,doc_type,doc_date,warehouse_id) values ('c0000000-0000-0000-0000-000000000001','in','2026-05-01',w) returning id into d;
  insert into public.stock_doc_lines(doc_id,line_no,item_id,qty,unit_cost) values (d,1,'1e000000-0000-0000-0000-000000000002',100,0.8),(d,2,'1e000000-0000-0000-0000-000000000003',100,0.05);
  perform public.post_stock_doc(d);
end $$;
insert into boms(id,company_id,code,name,item_id,output_qty,extra_cost) values ('1b000000-0000-0000-0000-000000000001',:'C','01','وصفة عصير','1e000000-0000-0000-0000-000000000001',10,2) returning name;
insert into bom_lines(bom_id,line_no,item_id,qty) values ('1b000000-0000-0000-0000-000000000001',1,'1e000000-0000-0000-0000-000000000002',5),('1b000000-0000-0000-0000-000000000001',2,'1e000000-0000-0000-0000-000000000003',10);
\echo == product as its own material (expected ERROR)
insert into bom_lines(bom_id,item_id,qty) values ('1b000000-0000-0000-0000-000000000001','1e000000-0000-0000-0000-000000000001',1);
\echo == production of 2 batches: cost = (5*0.8+10*0.05+2)*2 = 13, unit = 0.65
select create_production('1b000000-0000-0000-0000-000000000001',2,'2026-05-10',(select id from warehouses where company_id=:'C' limit 1)) is not null as created;
\echo == posting a production doc directly (expected ERROR)
select post_stock_doc((select in_doc_id from productions limit 1));
\echo == editing a production doc line (expected ERROR)
update stock_doc_lines set unit_cost=99 where doc_id=(select in_doc_id from productions limit 1);
\echo == deleting a production doc directly (expected ERROR)
delete from stock_docs where id=(select out_doc_id from productions limit 1);
select post_production((select id from productions limit 1)) as cost;
select total_cost, (select unit_cost from stock_doc_lines where doc_id=p.in_doc_id) unit_cost, (select count(*) from stock_doc_lines where doc_id=p.out_doc_id) out_lines from productions p;
\echo == production outside open year (expected ERROR)
select create_production('1b000000-0000-0000-0000-000000000001',1,'2015-01-01',(select id from warehouses where company_id=:'C' limit 1));
\echo == delete production with posted docs (expected ERROR)
select delete_production((select id from productions limit 1));
\echo == production with zero batches (expected ERROR)
select create_production('1b000000-0000-0000-0000-000000000001',0,'2026-05-10',(select id from warehouses where company_id=:'C' limit 1));
\echo == total_cost not editable
update productions set total_cost=1, notes='ملاحظة' returning total_cost, notes;
\echo == service ticket
insert into service_tickets(company_id,device,problem,estimate) values (:'C','لابتوب HP','ما بيشتغل',25) returning ticket_no, status;
update service_tickets set status='delivered' where company_id=:'C' returning delivered_at is not null as stamped;
\echo == empty device (expected ERROR)
insert into service_tickets(company_id,device) values (:'C',' ');
\echo == employee cannot see tickets
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select count(*) as visible from service_tickets;
\echo == employee cannot create production (expected ERROR)
select create_production('1b000000-0000-0000-0000-000000000001',1,'2026-05-10',(select id from warehouses limit 1));
reset role;
