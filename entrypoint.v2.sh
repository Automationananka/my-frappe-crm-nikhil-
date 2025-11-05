#!/bin/bash
# Entrypoint v3 - Fixed MariaDB authentication
set -e

echo "🚀 Starting Frappe/ERPNext setup on Railway..."
echo "=============================================="
echo "🔍 Environment Variables:"
echo "----------------------------------------------"
echo "SITE_NAME        = ${SITE_NAME}"
echo "DB_HOST          = ${DB_HOST}"
echo "DB_PORT          = ${DB_PORT}"
echo "DB_NAME          = ${DB_NAME}"
echo "ADMIN_PASSWORD   = ${ADMIN_PASSWORD}"
echo "DB_ROOT_USER     = ${DB_ROOT_USER:-root}"
echo "DB_PASSWORD      = ${DB_PASSWORD:0:3}*"
echo "REDIS_CACHE      = ${REDIS_CACHE}"
echo "REDIS_QUEUE      = ${REDIS_QUEUE}"
echo "REDIS_SOCKETIO   = ${REDIS_SOCKETIO}"
echo "----------------------------------------------"

echo "--- Entrypoint v3: Installing dependencies ---"
apt-get update && apt-get install -y mariadb-client redis-tools

# Wait for MariaDB with better connection testing
echo "=============================================="
echo "--- Entrypoint v3: Waiting for MariaDB to be ready ---"
MAX_RETRIES=30
RETRY_COUNT=0

until mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_ROOT_USER:-root}" -p"${DB_PASSWORD}" -e "SELECT 1" &>/dev/null; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    echo "❌ Failed to connect to MariaDB after $MAX_RETRIES attempts"
    echo "Attempting to diagnose connection..."
    echo "Testing basic connectivity:"
    nc -zv "${DB_HOST}" "${DB_PORT}" || echo "Port ${DB_PORT} not reachable"
    exit 1
  fi
  echo "... MariaDB attempt $RETRY_COUNT/$MAX_RETRIES (sleeping 5s) ..."
  sleep 5
done
echo "✅ MariaDB is ready!"

# Wait for Redis Cache
echo "--- Entrypoint v3: Waiting for Redis Cache... ---"
until redis-cli -u "${REDIS_CACHE}" ping 2>/dev/null | grep -q PONG; do
  echo "... redis-cache sleeping 5s ..."
  sleep 5
done
echo "✅ Redis Cache ready!"

# Wait for Redis Queue
echo "--- Entrypoint v3: Waiting for Redis Queue... ---"
until redis-cli -u "${REDIS_QUEUE}" ping 2>/dev/null | grep -q PONG; do
  echo "... redis-queue sleeping 5s ..."
  sleep 5
done
echo "✅ Redis Queue ready!"

# Wait for Redis SocketIO
echo "--- Entrypoint v3: Waiting for Redis SocketIO... ---"
until redis-cli -u "${REDIS_SOCKETIO}" ping 2>/dev/null | grep -q PONG; do
  echo "... redis-socketio sleeping 5s ..."
  sleep 5
done
echo "✅ Redis SocketIO ready!"

echo "--- Entrypoint v3: All services ready ---"

cd /home/frappe/frappe-bench

echo "--- Entrypoint v3: Recreating apps.txt ---"
rm -f sites/apps.txt
echo "frappe" > sites/apps.txt
echo "erpnext" >> sites/apps.txt

echo "--- Entrypoint v3: Fixing permissions ---"
chown -R frappe:frappe /home/frappe/frappe-bench/sites

# Create site_config.json with database credentials
echo "--- Entrypoint v3: Creating site config for ${SITE_NAME} ---"
mkdir -p "sites/${SITE_NAME}"
cat > "sites/${SITE_NAME}/site_config.json" <<EOF
{
  "db_host": "${DB_HOST}",
  "db_port": ${DB_PORT},
  "db_name": "${DB_NAME}",
  "db_type": "mariadb",
  "db_password": "${DB_PASSWORD}"
}
EOF
chown frappe:frappe "sites/${SITE_NAME}/site_config.json"

echo "--- Entrypoint v3: Creating new site (${SITE_NAME}) ---"
exec su - frappe -c "
cd /home/frappe/frappe-bench && \
bench new-site \"${SITE_NAME}\" \
  --db-type mariadb \
  --db-host \"${DB_HOST}\" \
  --db-port ${DB_PORT} \
  --db-name \"${DB_NAME}\" \
  --db-root-username \"${DB_ROOT_USER:-root}\" \
  --db-root-password \"${DB_PASSWORD}\" \
  --mariadb-root-username \"${DB_ROOT_USER:-root}\" \
  --mariadb-root-password \"${DB_PASSWORD}\" \
  --admin-password \"${ADMIN_PASSWORD}\" \
  --no-mariadb-socket \
  --install-app erpnext \
  --force && \
bench --site \"${SITE_NAME}\" set-config db_host \"${DB_HOST}\" && \
bench --site \"${SITE_NAME}\" set-config db_port ${DB_PORT} && \
bench start
"
