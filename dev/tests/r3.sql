\set ON_ERROR_STOP 0
update user_companies set group_id=(select id from user_groups where name='محاسب') where user_id='22222222-2222-2222-2222-222222222222';
update fiscal_years set is_closed=true;
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false) \g /dev/null
update fiscal_years set is_closed=false returning is_closed;
-- change fy dates so posted entries fall outside
update fiscal_years set start_date='2026-07-01' returning start_date;
