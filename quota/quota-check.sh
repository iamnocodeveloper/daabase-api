#!/usr/bin/env bash
# daabase quota enforcement
# Reads per-app sizes from triples_size_aggregate (populated by engine every 5 min)
# Toggles apps.status between 'active' and 'read-only'
# Auto-restores when user deletes data and drops below limit
#
# Logs to stdout (captured by entrypoint → /data/logs/quota.log)

PLAN_FILE="${PLAN_FILE:-/app/quota/plans.yaml}"

# ── Parse plans.yaml (no jq/python/bc needed) ──────────────────────

get_limit() {
  local plan="$1"
  awk -v p="$plan" '
    $0 ~ "^  " p ":" { found=1; next }
    found && /max_bytes:/ { print $2; exit }
    found && /^  [a-z]/ { exit }
  ' "$PLAN_FILE"
}

get_warn_pct() {
  local plan="$1"
  awk -v p="$plan" '
    $0 ~ "^  " p ":" { found=1; next }
    found && /warn_pct:/ { print $2; exit }
    found && /^  [a-z]/ { exit }
  ' "$PLAN_FILE"
}

DEFAULT_PLAN=$(awk '/^default:/ { print $2 }' "$PLAN_FILE")

# ── Human-readable size (pure bash, no bc) ──────────────────────────

human_bytes() {
  local b=${1%%.*}
  if   [ "$b" -ge 1073741824 ]; then echo "$(( b / 1073741824 ))GB"
  elif [ "$b" -ge 1048576 ];    then echo "$(( b / 1048576 ))MB"
  elif [ "$b" -ge 1024 ];       then echo "$(( b / 1024 ))KB"
  else                                echo "${b}B"
  fi
}

# ── Main check ──────────────────────────────────────────────────────

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Verify plan file exists
if [ ! -f "$PLAN_FILE" ]; then
  echo "[$ts] [QUOTA-ERROR] plan file not found: $PLAN_FILE"
  exit 1
fi

# Fetch all non-disabled apps with their sizes
APP_DATA=$(su postgres -c "psql -tA -d instant" <<'SQL'
  SELECT
    a.id::text,
    COALESCE(a.title, 'unnamed'),
    COALESCE(st.name, 'free'),
    COALESCE(a.status, 'active'),
    COALESCE(agg.total_bytes, 0)
  FROM apps a
  LEFT JOIN instant_subscriptions sub ON a.subscription_id = sub.id
  LEFT JOIN instant_subscription_types st ON sub.subscription_type_id = st.id
  LEFT JOIN (
    SELECT
      ag.app_id,
      SUM(ag.pg_size) + SUM(COALESCE(ag.files_size, 0)) as total_bytes
    FROM triples_size_aggregate ag
    JOIN attrs at ON ag.attr_id = at.id
    WHERE at.deletion_marked_at IS NULL
    GROUP BY ag.app_id
  ) agg ON a.id = agg.app_id
  WHERE COALESCE(a.status, 'active') != 'disabled';
SQL
)

if [ -z "$APP_DATA" ]; then
  echo "[$ts] [QUOTA-CHECK] no active apps found"
  exit 0
fi

while IFS='|' read -r app_id app_name plan current_status total_bytes; do
  # Strip whitespace
  app_id=$(echo "$app_id" | xargs)
  app_name=$(echo "$app_name" | xargs)
  plan=$(echo "$plan" | xargs | tr '[:upper:]' '[:lower:]')
  current_status=$(echo "$current_status" | xargs)
  total_bytes=${total_bytes:-0}
  total_bytes=$(echo "$total_bytes" | xargs)

  # Skip if total_bytes is not a number
  case "$total_bytes" in
    ''|*[!0-9]*) echo "[$ts] [QUOTA-WARN] app=$app_name invalid total_bytes=$total_bytes, skipping"; continue ;;
  esac

  # Get limit for this plan (fallback to default)
  max_bytes=$(get_limit "$plan")
  [ -z "$max_bytes" ] && max_bytes=$(get_limit "$DEFAULT_PLAN")
  [ -z "$max_bytes" ] && { echo "[$ts] [QUOTA-ERROR] no limit found for plan=$plan app=$app_id"; continue; }

  warn_pct=$(get_warn_pct "$plan")
  [ -z "$warn_pct" ] && warn_pct=80
  warn_bytes=$(( max_bytes * warn_pct / 100 ))

  total_h=$(human_bytes "$total_bytes")
  max_h=$(human_bytes "$max_bytes")

  if [ "$total_bytes" -gt "$max_bytes" ]; then
    # OVER LIMIT
    if [ "$current_status" = "active" ]; then
      su postgres -c "psql -d instant -c \"UPDATE apps SET status = 'read-only' WHERE id = '$app_id'::uuid;\"" >/dev/null 2>&1
      echo "[$ts] [QUOTA-EXCEEDED] app=$app_name($app_id) plan=$plan total=${total_h}/${max_h} -> read-only"
    else
      echo "[$ts] [QUOTA-CHECK] app=$app_name($app_id) plan=$plan total=${total_h}/${max_h} status=$current_status (already enforced)"
    fi

  elif [ "$total_bytes" -gt "$warn_bytes" ]; then
    # WARNING ZONE (80-100%)
    if [ "$current_status" = "active" ]; then
      pct=$(( total_bytes * 100 / max_bytes ))
      echo "[$ts] [QUOTA-WARN] app=$app_name($app_id) plan=$plan total=${total_h}/${max_h} (${pct}%)"
    fi
  fi

  # AUTO-RESTORE: if under limit and currently read-only, reactivate
  if [ "$total_bytes" -le "$max_bytes" ] && [ "$current_status" = "read-only" ]; then
    su postgres -c "psql -d instant -c \"UPDATE apps SET status = 'active' WHERE id = '$app_id'::uuid;\"" >/dev/null 2>&1
    echo "[$ts] [QUOTA-RESTORED] app=$app_name($app_id) plan=$plan total=${total_h}/${max_h} -> active"
  fi

done <<< "$APP_DATA"

echo "[$ts] [QUOTA-CHECK] done ($(echo "$APP_DATA" | wc -l | xargs) apps scanned)"
