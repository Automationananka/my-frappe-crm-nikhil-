#!/bin/bash
# Entrypoint v6 - Railway Production with MySQL
set -e

echo "🚀 Starting Frappe/ERPNext setup on Railway (MySQL version)..."
echo "=============================================="

# Install dependencies
echo "--- Installing dependencies ---"
apt-get update && apt-get install -y default-mysql-client redis-tools netcat-openbsd

echo "=============================================="
echo "🔍 Environment Variables:"
echo SITE_NAME=erpnext-production-6e19.up.railway.app
echo DB_HOST=mariadb.railway.internal
echo DB_PORT=3306
echo DB_NAME=erpnext
echo DB_USER=erpnext_user
echo "=============================================="

# Assign DB variables (use DB_* vars if MYSQL* vars don't exist)
DB_HOST=${MYSQLHOST:-${DB_HOST}}
DB_PORT=${MYSQLPORT:-${DB_PORT:-3306}}
DB_NAME=${MYSQLDATABASE:-${DB_NAME}}
DB_USER=${MYSQLUSER:-${DB_USER}}
DB_PASSWORD=${MYSQLPASSWORD:-${DB_PASSWORD}}

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
if mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" --connect-timeout=5 -e "SELECT 1" &>/dev/null; then
    echo "✅ MySQL connection verified!"
else
    echo "❌ MySQL connection failed. Check MYSQLUSER and MYSQLPASSWORD."
    exit 1
fi

# Wait for Redis
for redis_var in REDIS_CACHE REDIS_QUEUE REDIS_SOCKETIO; do
    redis_url="${!redis_var}"
    echo "--- Waiting for $redis_var ---"
    until redis-cli -u "${redis_url}" ping 2>/dev/null | grep -q PONG; do
        echo "... waiting for ${redis_var} ..."
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
