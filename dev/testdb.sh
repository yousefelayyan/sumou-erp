#!/bin/bash
# يبني قاعدة تجريبية نظيفة ويشغّل ملفات SQL بالترتيب
B=/usr/lib/postgresql/16/bin
su postgres -c "$B/pg_ctl -D /tmp/pgdata -m immediate stop" >/dev/null 2>&1
rm -rf /tmp/pgdata /tmp/.s.PGSQL.5433*; mkdir /tmp/pgdata; chown postgres /tmp/pgdata
su postgres -c "$B/initdb -D /tmp/pgdata -A trust >/dev/null && $B/pg_ctl -D /tmp/pgdata -o '-k /tmp -p 5433' -l /tmp/pgdata/log -w start >/dev/null"
cat > /tmp/stub.sql <<'S'
create schema auth;
create schema extensions; create extension pgcrypto with schema extensions;
create table auth.users(id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb, created_at timestamptz default now(), instance_id uuid, aud text, role text, encrypted_password text, email_confirmed_at timestamptz, raw_app_meta_data jsonb, updated_at timestamptz, confirmation_token text, email_change text, email_change_token_new text, recovery_token text);
create table auth.identities(id uuid primary key, user_id uuid references auth.users on delete cascade, provider_id text, identity_data jsonb, provider text, last_sign_in_at timestamptz, created_at timestamptz, updated_at timestamptz);
create role authenticated; create role anon;
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
grant usage on schema public, auth to authenticated;
S
psql -h /tmp -p 5433 -U postgres -q -v ON_ERROR_STOP=1 -f /tmp/stub.sql
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for f in "$ROOT"/sql/[0-9][0-9]_*.sql; do
  psql -h /tmp -p 5433 -U postgres -q -v ON_ERROR_STOP=1 -f "$f" 2>&1 | grep -iv notice || true
  echo "ran $(basename $f)"
done
