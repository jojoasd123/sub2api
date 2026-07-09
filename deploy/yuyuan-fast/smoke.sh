#!/usr/bin/env bash
set -euo pipefail

FAST_EMAIL="${SUB2API_FAST_SMOKE_FAST_EMAIL:-}"
NORMAL_EMAIL="${SUB2API_FAST_SMOKE_NORMAL_EMAIL:-}"
MODEL="${SUB2API_FAST_SMOKE_MODEL:-gpt-5.4-mini}"
INJECTOR_URL="${SUB2API_FAST_SMOKE_URL:-http://127.0.0.1:18082/v1/chat/completions}"

if [ -z "$FAST_EMAIL" ] || [ -z "$NORMAL_EMAIL" ]; then
  echo "Set SUB2API_FAST_SMOKE_FAST_EMAIL and SUB2API_FAST_SMOKE_NORMAL_EMAIL." >&2
  exit 2
fi

psql_at() {
  docker exec sub2api-postgres psql -U sub2api -d sub2api -At "$@"
}

key_for_email() {
  local email="$1"
  docker exec -i sub2api-postgres psql -U sub2api -d sub2api -v ON_ERROR_STOP=1 -v "email=$email" -At <<'SQL'
select k.key
from api_keys k
join users u on u.id=k.user_id
where lower(u.email)=lower(:'email')
  and k.status='active'
  and k.deleted_at is null
order by k.id
limit 1;
SQL
}

user_id_for_email() {
  local email="$1"
  docker exec -i sub2api-postgres psql -U sub2api -d sub2api -v ON_ERROR_STOP=1 -v "email=$email" -At <<'SQL'
select id
from users
where lower(email)=lower(:'email')
  and deleted_at is null
order by id
limit 1;
SQL
}

run_chat() {
  local label="$1"
  local key="$2"
  local body="$3"
  local outfile="/tmp/sub2api-fast-${label}.json"
  local code
  code=$(curl -sS -m 120 -o "$outfile" -w "%{http_code}" \
    "$INJECTOR_URL" \
    -H "Authorization: Bearer $key" \
    -H "Content-Type: application/json" \
    --data "$body")
  python3 - "$label" "$code" "$outfile" <<'PY'
import json
import sys

label, code, path = sys.argv[1:4]
data = json.load(open(path, encoding="utf-8"))
err = data.get("error")
if err:
    reason = err.get("code") or err.get("type") or err.get("message") or "error"
    print(f"{label}: http={code} error={reason}")
    raise SystemExit(1)
print(f"{label}: http={code} ok")
PY
}

START_TS="$(psql_at -c 'select now();')"
FAST_USER_ID="$(user_id_for_email "$FAST_EMAIL")"
NORMAL_USER_ID="$(user_id_for_email "$NORMAL_EMAIL")"
FAST_KEY="$(key_for_email "$FAST_EMAIL")"
NORMAL_KEY="$(key_for_email "$NORMAL_EMAIL")"

if [ -z "$FAST_KEY" ] || [ -z "$NORMAL_KEY" ]; then
  echo "missing active API key for one or both smoke users" >&2
  exit 1
fi

run_chat fast "$FAST_KEY" "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK only. fast policy smoke fast\"}],\"max_tokens\":8}"
run_chat normal "$NORMAL_KEY" "{\"model\":\"$MODEL\",\"service_tier\":\"priority\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK only. fast policy smoke normal\"}],\"max_tokens\":8}"

psql_at -F '|' -c "
with latest as (
  select distinct on (user_id)
         user_id, api_key_id, coalesce(service_tier, '<null>') as service_tier,
         model, duration_ms, created_at
  from usage_logs
  where user_id in ($FAST_USER_ID, $NORMAL_USER_ID)
    and created_at >= '$START_TS'::timestamptz
  order by user_id, created_at desc
)
select user_id, api_key_id, service_tier, model, duration_ms, created_at
from latest
order by user_id;"
