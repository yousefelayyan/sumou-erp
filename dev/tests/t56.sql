-- الكلفة المحمّلة
\set ON_ERROR_STOP 0
\set C 'c0000000-0000-0000-0000-000000000001'
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select id as sup from parties where company_id = :'C' and party_type = 'supplier' order by code limit 1 \gset
select m.item_id as it, m.warehouse_id as wh, m.qty as pq from stock_moves m where m.source_id = '20000000-0000-0000-0000-0000000000b1' limit 1 \gset
select coalesce(sum(qty*unit_cost),0) as v0, coalesce(sum(qty),0) as q0 from stock_moves where company_id = :'C' and item_id = :'it' and warehouse_id = :'wh' \gset
\echo == draft invoice not allowed (expected ERROR)
select landed_save(jsonb_build_object('company_id',:'C','doc_date','2026-06-30','invoices',jsonb_build_array('0d000000-0000-0000-0000-0000000000bb'),'charges',jsonb_build_array(jsonb_build_object('party_id',:'sup','amount',10))));
select landed_save(jsonb_build_object('company_id',:'C','doc_date','2026-12-30','description','شحن وجمارك','method','value',
  'invoices',jsonb_build_array('20000000-0000-0000-0000-0000000000b1','20000000-0000-0000-0000-0000000000d1'),
  'charges',jsonb_build_array(jsonb_build_object('description','شحن','party_id',:'sup','amount',30),
                              jsonb_build_object('description','جمارك','account_id',(select id from accounts where company_id = :'C' and account_type = 'cash' and not is_group order by code limit 1),'amount',20.5)))) as lid \gset
select sum(amount) as alloc_total, sum(to_stock) + sum(to_cogs) as split from landed_preview(:'lid');
select landed_post(:'lid') as eid \gset
select status, total from landed_costs where id = :'lid';
select sum(debit) = sum(credit) as balanced, sum(debit) as amt from journal_lines where entry_id = :'eid';
select round(coalesce(sum(qty*unit_cost),0) - :v0, 3) as value_added, coalesce(sum(qty),0) - :q0 as qty_change from stock_moves where company_id = :'C' and item_id = :'it' and warehouse_id = :'wh';
\echo == edit posted (expected ERROR)
select landed_save(jsonb_build_object('id',:'lid','company_id',:'C','doc_date','2026-06-30','invoices',jsonb_build_array('20000000-0000-0000-0000-0000000000b1'),'charges',jsonb_build_array(jsonb_build_object('party_id',:'sup','amount',1))));
\echo == unpost purchase invoice used by landed doc (expected ERROR)
select unpost_invoice('20000000-0000-0000-0000-0000000000b1','stock');
\echo == reverse its entry directly (expected ERROR)
select reverse_entry(:'eid', '2026-12-31');
\echo == frozen landed entry blocks cancel (expected ERROR)
select set_doc_frozen('journal_entries', :'eid', true);
select landed_cancel(:'lid', '2026-12-31');
select set_doc_frozen('journal_entries', :'eid', false);
select landed_cancel(:'lid', '2026-12-31');
select status from landed_costs where id = :'lid';
select round(coalesce(sum(qty*unit_cost),0) - :v0, 3) as value_after_cancel from stock_moves where company_id = :'C' and item_id = :'it' and warehouse_id = :'wh';
\echo == employee no permission (expected ERROR)
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
select landed_save(jsonb_build_object('company_id',:'C','doc_date','2026-06-30','invoices',jsonb_build_array('20000000-0000-0000-0000-0000000000b1'),'charges',jsonb_build_array(jsonb_build_object('party_id',:'sup','amount',1))));
reset role;
