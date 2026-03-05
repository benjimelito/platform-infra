#!/usr/bin/env bash
set -euo pipefail

# Required env vars:
#   INSTANCE_ID
#   APP_SLUG
#   RDS_HOST
#   RDS_ADMIN_USER
#   RDS_ADMIN_PASSWORD
#
# Outputs:
#   Prints DATABASE_URL to stdout.

if [[ -z "${INSTANCE_ID:-}" || -z "${APP_SLUG:-}" || -z "${RDS_HOST:-}" || -z "${RDS_ADMIN_USER:-}" || -z "${RDS_ADMIN_PASSWORD:-}" ]]; then
  echo "Missing required env vars. Need INSTANCE_ID, APP_SLUG, RDS_HOST, RDS_ADMIN_USER, RDS_ADMIN_PASSWORD."
  exit 1
fi

DB_NAME="${APP_SLUG}"
DB_USER="${APP_SLUG}_app"
DB_PASS="$(openssl rand -base64 48 | tr -d '\n' | tr '+/' '-_' | cut -c1-32)"

# Remote command to run on EB instance via SSM
read -r -d '' REMOTE_CMD <<'EOF' || true
set -euo pipefail

if ! command -v psql >/dev/null 2>&1; then
  sudo yum -y install postgresql15 || sudo yum -y install postgresql || true
fi

export PGPASSWORD="${RDS_ADMIN_PASSWORD}"

psql -h "${RDS_HOST}" -U "${RDS_ADMIN_USER}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 \
  || psql -h "${RDS_HOST}" -U "${RDS_ADMIN_USER}" -d postgres -c "CREATE DATABASE \"${DB_NAME}\";"

psql -h "${RDS_HOST}" -U "${RDS_ADMIN_USER}" -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 \
  || psql -h "${RDS_HOST}" -U "${RDS_ADMIN_USER}" -d postgres -c "CREATE USER \"${DB_USER}\";"

psql -h "${RDS_HOST}" -U "${RDS_ADMIN_USER}" -d postgres -c "ALTER USER \"${DB_USER}\" WITH PASSWORD '${DB_PASS}';"
psql -h "${RDS_HOST}" -U "${RDS_ADMIN_USER}" -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\";"

export PGPASSWORD="${DB_PASS}"
psql -h "${RDS_HOST}" -U "${DB_USER}" -d "${DB_NAME}" -c "GRANT USAGE, CREATE ON SCHEMA public TO \"${DB_USER}\";"
EOF

# Replace placeholders with real values before sending
REMOTE_CMD="${REMOTE_CMD//'${RDS_HOST}'/${RDS_HOST}}"
REMOTE_CMD="${REMOTE_CMD//'${RDS_ADMIN_USER}'/${RDS_ADMIN_USER}}"
REMOTE_CMD="${REMOTE_CMD//'${RDS_ADMIN_PASSWORD}'/${RDS_ADMIN_PASSWORD}}"
REMOTE_CMD="${REMOTE_CMD//'${DB_NAME}'/${DB_NAME}}"
REMOTE_CMD="${REMOTE_CMD//'${DB_USER}'/${DB_USER}}"
REMOTE_CMD="${REMOTE_CMD//'${DB_PASS}'/${DB_PASS}}"

COMMAND_ID="$(aws ssm send-command \
  --instance-ids "${INSTANCE_ID}" \
  --document-name "AWS-RunShellScript" \
  --parameters commands="$(jq -n --arg cmd "$REMOTE_CMD" '{commands:[$cmd]}')" \
  --query "Command.CommandId" \
  --output text)"

aws ssm wait command-executed --command-id "${COMMAND_ID}" --instance-id "${INSTANCE_ID}"

INVOCATION="$(aws ssm get-command-invocation --command-id "${COMMAND_ID}" --instance-id "${INSTANCE_ID}")"
STATUS="$(echo "$INVOCATION" | jq -r '.Status')"

if [[ "$STATUS" != "Success" ]]; then
  echo "SSM command failed with status: $STATUS"
  echo "---- STDOUT ----"
  echo "$INVOCATION" | jq -r '.StandardOutputContent'
  echo "---- STDERR ----"
  echo "$INVOCATION" | jq -r '.StandardErrorContent'
  exit 1
fi

DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@${RDS_HOST}:5432/${DB_NAME}?schema=public"

# Print only the URL (workflow will mask it)
echo "${DATABASE_URL}"