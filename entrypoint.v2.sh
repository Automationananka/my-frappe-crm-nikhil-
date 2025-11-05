#!/bin/bash
# Entrypoint v7 - Railway Production with MySQL (FIXED)
set -e

echo "🚀 Starting Frappe/ERPNext setup on Railway (MySQL version)..."
echo "=============================================="

# Install dependencies
echo "--- Installing dependencies ---"
apt-get update && apt-get install -y default-mysql-client redis-tools netcat-openbsd

echo "=============================================="

# CRITICAL FIX: Assign Railway MySQL variables directly (no fallbacks yet)
# Railway provides MYSQLHOST, MYSQLPORT, MYSQLDATABASE, MYSQLUSER, MYSQLPASSWORD
DB_HOST="${MYSQLHOST}"
DB_PORT="${MYSQLPORT:-3306}"
DB_NAME="${MYSQLDATABASE}"
DB_USER="${MYSQLUSER}"
DB_PASSWORD="${MYSQLPASSWORD}"
SITE_NAME="${SITE_NAME:-erpnext.localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

echo "🔍 Environment Variables (After Assignment):"
echo "SITE_NAME=${SITE_NAME}"
echo "DB_HOST=${DB_HOST}"
echo "DB_PORT=${DB_PORT}"
echo "DB_NAME=${DB_NAME}"
echo "DB_USER=${DB_USER}"
echo "DB_PASSWORD=${DB_PASSWORD:+***SET***}"
echo "=============================================="

# Validate required variables
if [ -z "${DB_HOST}" ] || [ -z "${DB_USER}" ] || [ -z "${DB_PASSWORD}" ] || [ -z "${DB_NAME}" ]; then
    echo "❌ ERROR: Missing required MySQL environment variables!"
    echo "DB_HOST: ${DB_HOST:-NOT SET}"
    echo "DB_USER: ${DB_USER:-NOT SET}"
    echo "DB_PASSWORD: ${DB_PASSWORD:+SET}${DB_PASSWORD:-NOT SET}"
    echo "DB_NAME: ${DB_NAME:-NOT SET}"
    exit 1
fi

# Wait for MySQL
echo "--- Waiting for MySQL to be reachable ---"
MAX_RETRIES=30
RETRY_COUNT=0
while ! nc -z "${DB_HOST}" "${DB_PORT}" 2>/dev/null; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "❌ MySQL not reachable after $MAX_RETRIES attempts"
        exit 1
    fi
    echo "... waiting for MySQL (attempt $RETRY_COUNT/$MAX_RETRIES) ..."
    sleep 2
done
echo "✅ MySQL is reachable!"

# Verify DB connection
echo "--- Testing MySQL connection ---"
if mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" --connect-timeout=10 -e "SELECT 1;" 2>/dev/null; then
    echo "✅ MySQL connection verified!"
else
    echo "❌ MySQL connection failed!"
    echo "Connection details:"
    echo "  Host: ${DB_HOST}"
    echo "  Port: ${DB_PORT}"
    echo "  User: ${DB_USER}"
    echo "  Database: ${DB_NAME}"
    echo ""
    echo "Testing with verbose error output:"
    mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" -e "SELECT 1;" 2>&1 || true
    exit 1
fi

# Ensure database exists
echo "--- Ensuring database exists ---"
mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>&1
echo "✅ Database ${DB_NAME} ready!"

# Wait for Redis services
for redis_var in REDIS_CACHE REDIS_QUEUE REDIS_SOCKETIO; do
    redis_url="${!redis_var}"
    echo "--- Waiting for $redis_var ---"
    MAX_REDIS_RETRIES=30
    REDIS_RETRY=0
    until redis-cli -u "${redis_url}" ping 2>/dev/null | grep -q PONG; do
        REDIS_RETRY=$((REDIS_RETRY + 1))
        if [ $REDIS_RETRY -ge $MAX_REDIS_RETRIES ]; then
            echo "❌ ${redis_var} not reachable after $MAX_REDIS_RETRIES attempts"
            exit 1
        fi
        echo "... waiting for ${redis_var} (attempt $REDIS_RETRY/$MAX_REDIS_RETRIES) ..."
        sleep 2
    done
    echo "✅ ${redis_var} ready!"
done

echo "=============================================="
echo "--- All services ready ---"

cd /home/frappe/frappe-bench

# Configure apps
echo "--- Configuring apps ---"
rm -f sites/apps.txt
echo "frappe" > sites/apps.txt
echo "erpnext" >> sites/apps.txt

# Fix permissions
chown -R frappe:frappe /home/frappe/frappe-bench/sites

# Check if site exists
if [ -d "sites/${SITE_NAME}" ]; then
    echo "--- Site ${SITE_NAME} already exists, starting bench ---"
    exec su - frappe -c "cd /home/frappe/frappe-bench && bench start"
else
    echo "--- Creating new site: ${SITE_NAME} ---"
    exec su - frappe -c "
cd /home/frappe/frappe-bench && \
bench new-site \"${SITE_NAME}\" \
  --db-type mysql \
  --db-host \"${DB_HOST}\" \
  --db-port ${DB_PORT} \
  --db-name \"${DB_NAME}\" \
  --mariadb-root-username \"${DB_USER}\" \
  --mariadb-root-password \"${DB_PASSWORD}\" \
  --admin-password \"${ADMIN_PASSWORD}\" \
  --no-mariadb-socket \
  --install-app erpnext \
  --force && \
echo '✅ Site created successfully!' && \
bench --site \"${SITE_NAME}\" set-config db_host \"${DB_HOST}\" && \
bench --site \"${SITE_NAME}\" set-config db_port ${DB_PORT} && \
bench start
"
fi
