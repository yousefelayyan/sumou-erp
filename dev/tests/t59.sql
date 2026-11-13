-- ملف العميل الإحصائي
\set ON_ERROR_STOP 0
\set C 'c0000000-0000-0000-0000-000000000001'
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select p.id as cust from parties p where p.company_id = :'C' and p.party_type = 'customer' and exists (select 1 from invoices i where i.party_id = p.id and i.status = 'posted') order by code limit 1 \gset
select (j->>'invoice_count')::int > 0 as has_invoices, j ? 'balance' as has_bal, jsonb_array_length(j->'monthly') as months, jsonb_typeof(j->'top_items') as top, j ? 'open_amount' as has_open
  from (select party_profile(:'C', :'cust') j) x;
select id as sup from parties where company_id = :'C' and party_type = 'supplier' order by code limit 1 \gset
select (party_profile(:'C', :'sup')->'party'->>'type') as sup_type;
\echo == other company party (expected ERROR)
select party_profile(:'C', gen_random_uuid());
reset role;
