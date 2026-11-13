#!/bin/bash
# فحص الاسترجاع الحقيقي: بيعبّي القاعدة التجريبية بالفحوصات، بياخذ نسخة من الشركة، بيبني قاعدة جديدة، وبيسترجع
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd /tmp && bash "$ROOT/dev/testdb.sh" >/dev/null 2>&1
for t in t2 t4 t5 t9 t11 t12 t13 t15 t16 t17 t18 t20 t21 t22 t23 t24 t25 t26 t27 t28 t29 t30 t31 t32 t33 t34 t35 t36 t37 t38 t39 t40 t41 t42 t43 t44 t45 t46 t47 t48 t49 t50 t51 t53 t54 t55 t53; do psql -h /tmp -p 5433 -U postgres -q -f "$ROOT/dev/tests/$t.sql" >/dev/null 2>&1 || true; done
psql -h /tmp -p 5433 -U postgres -qAt -c "set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false); select backup_company('c0000000-0000-0000-0000-000000000001');" | tail -1 > /tmp/bk.json
psql -h /tmp -p 5433 -U postgres -qAt -c "select (select count(*) from journal_entries)||' '||(select count(*) from invoices)||' '||(select count(*) from stock_moves)||' '||(select count(*) from orders)||' '||(select count(*) from productions)||' '||(select count(*) from service_tickets)" > /tmp/before.txt
bash "$ROOT/dev/testdb.sh" >/dev/null 2>&1
psql -h /tmp -p 5433 -U postgres -q -v ON_ERROR_STOP=1 <<'S'
insert into auth.users(id,email) values ('11111111-1111-1111-1111-111111111111','a@x.com');
\set bk `cat /tmp/bk.json`
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false) \g /dev/null
select restore_company(:'bk'::jsonb) is not null as restored;
S
psql -h /tmp -p 5433 -U postgres -qAt -c "select (select count(*) from journal_entries)||' '||(select count(*) from invoices)||' '||(select count(*) from stock_moves)||' '||(select count(*) from orders)||' '||(select count(*) from productions)||' '||(select count(*) from service_tickets)" > /tmp/after.txt
echo "قبل: $(cat /tmp/before.txt)   بعد: $(cat /tmp/after.txt)"
cmp -s /tmp/before.txt /tmp/after.txt && echo "الاسترجاع تمام ✅" || { echo "الاسترجاع ناقص ❌"; exit 1; }
