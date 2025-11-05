#!/bin/bash
# Entrypoint v4 - Railway Private Networking Fix
set -e

echo "🚀 Starting Frappe/ERPNext setup on Railway..."
echo "=============================================="
echo "🔍 Environment Variables:"
echo "----------------------------------------------"
echo "SITE_NAME        = ${SITE_NAME}"
echo "DB_HOST          = ${DB_HOST}"
echo "DB_PORT          = ${DB_PORT:-3306}"
echo "DB_NAME          = ${DB_NAME}"
echo "ADMIN_PASSWORD   = [HIDDEN]"
echo "DB_ROOT_USER     = ${DB_ROOT_USER:-root}"
echo "DB_PASSWORD      = [HIDDEN]"
echo "REDIS_CACHE      = ${REDIS_CACHE}"
echo "REDIS_QUEUE      = ${REDIS_QUEUE}"
echo "REDIS_SOCKETIO   = ${REDIS_SOCKETIO}"
echo "----------------------------------------------"

echo "--- Installing dependencies ---"
apt-get update && apt-get install -y mariadb-client redis-tools netcat-openbsd dnsutils

echo "=============================================="
echo "--- Diagnosing Network Configuration ---"
echo "Hostname: $(hostname)"
echo "IP Address: $(hostname -I)"
echo ""
echo "DNS Resolution for DB_HOST:"
getent hosts "${DB_HOST}" || echo "⚠ DNS resolution failed"
echo ""
echo "Checking TCP connectivity to ${DB_HOST}:${DB_PORT:-3306}:"
timeout 5 bash -c "cat < /dev/null > /dev/tcp/${DB_HOST}/${DB_PORT:-3306}" 2>/dev/null && echo "✅ TCP connection successful" || echo "❌ TCP connection failed"
echo "=============================================="

# Parse Railway private network variables
# Railway can provide MariaDB variables as MYSQL_ or MARIADB_ prefixes
echo "--- Checking for Railway MariaDB/MySQL variables ---"

# Check for MARIADB_* variables first
if [ -n "$MARIADB_HOST" ]; then
    echo "Found MARIADB_HOST: ${MARIADB_HOST}"
    DB_HOST="${MARIADB_HOST}"
fi
if [ -n "$MARIADB_PORT" ]; then
    echo "Found MARIADB_PORT: ${MARIADB_PORT}"
    DB_PORT="${MARIADB_PORT}"
fi
if [ -n "$MARIADB_ROOT_PASSWORD" ]; then
    echo "Found MARIADB_ROOT_PASSWORD: [HIDDEN]"
    DB_PASSWORD="${MARIADB_ROOT_PASSWORD}"
fi
if [ -n "$MARIADB_USER" ]; then
    echo "Found MARIADB_USER: ${MARIADB_USER}"
    DB_ROOT_USER="${MARIADB_USER}"
fi
if [ -n "$MARIADB_PASSWORD" ]; then
    echo "Found MARIADB_PASSWORD: [HIDDEN]"
    DB_PASSWORD="${MARIADB_PASSWORD}"
fi
if [ -n "$MARIADB_DATABASE" ]; then
    echo "Found MARIADB_DATABASE: ${MARIADB_DATABASE}"
    DB_NAME="${MARIADB_DATABASE}"
fi

# Fallback to MYSQL_* variables (Railway often uses these for MariaDB too)
if [ -n "$MYSQL_URL" ]; then
    echo "Found MYSQL_URL: ${MYSQL_URL%%:}://"
fi
if [ -n "$MYSQL_HOST" ] && [ -z "$DB_HOST" ]; then
    echo "Found MYSQL_HOST: ${MYSQL_HOST}"
    DB_HOST="${MYSQL_HOST}"
fi
if [ -n "$MYSQL_PORT" ] && [ -z "$DB_PORT" ]; then
    echo "Found MYSQL_PORT: ${MYSQL_PORT}"
    DB_PORT="${MYSQL_PORT}"
fi
if [ -n "$MYSQL_ROOT_PASSWORD" ] && [ -z "$DB_PASSWORD" ]; then
    echo "Found MYSQL_ROOT_PASSWORD: [HIDDEN]"
    DB_PASSWORD="${MYSQL_ROOT_PASSWORD}"
fi
if [ -n "$MYSQLUSER" ] && [ -z "$DB_ROOT_USER" ]; then
    echo "Found MYSQLUSER: ${MYSQLUSER}"
    DB_ROOT_USER="${MYSQLUSER}"
fi
if [ -n "$MYSQLPASSWORD" ] && [ -z "$DB_PASSWORD" ]; then
    echo "Found MYSQLPASSWORD: [HIDDEN]"
    DB_PASSWORD="${MYSQLPASSWORD}"
fi
if [ -n "$MYSQLDATABASE" ] && [ -z "$DB_NAME" ]; then
    echo "Found MYSQLDATABASE: ${MYSQLDATABASE}"
    DB_NAME="${MYSQLDATABASE}"
fi

# Additional Railway variable formats
if [ -n "$DATABASE_URL" ]; then
    echo "Found DATABASE_URL: ${DATABASE_URL%%:}://"
fi

echo "--- Final Connection Parameters ---"
echo "DB_HOST: ${DB_HOST}"
echo "DB_PORT: ${DB_PORT:-3306}"
echo "DB_USER: ${DB_ROOT_USER:-root}"
echo "DB_NAME: ${DB_NAME}"
echo "=============================================="

# Wait for MariaDB with better connection testing
echo "--- Waiting for MariaDB to be ready ---"
MAX_RETRIES=60
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if mysql -h"${DB_HOST}" -P"${DB_PORT:-3306}" -u"${DB_ROOT_USER:-root}" -p"${DB_PASSWORD}" --connect-timeout=5 -e "SELECT 1" &>/dev/null; then
        echo "✅ MariaDB is ready!"
        break
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "❌ Failed to connect to MariaDB after $MAX_RETRIES attempts"
        echo ""
        echo "=== DEBUGGING INFORMATION ==="
        echo "Last mysql error:"
        mysql -h"${DB_HOST}" -P"${DB_PORT:-3306}" -u"${DB_ROOT_USER:-root}" -p"${DB_PASSWORD}" --connect-timeout=5 -e "SELECT 1" 2>&1 || true
        echo ""
        echo "Network check:"
        nc -zv "${DB_HOST}" "${DB_PORT:-3306}" 2>&1 || echo "Port not reachable via nc"
        echo ""
        echo "Environment variables that might help:"
        env | grep -i mysql || echo "No MYSQL env vars found"
        env | grep -i maria || echo "No MARIA env vars found"
        env | grep -i database || echo "No DATABASE env vars found"
        echo "==========================="
        exit 1
    fi
    
    echo "... MariaDB attempt $RETRY_COUNT/$MAX_RETRIES (sleeping 2s) ..."
    sleep 2
done

# Wait for Redis Cache
echo "--- Waiting for Redis Cache... ---"
RETRY_COUNT=0
while [ $RETRY_COUNT -lt 30 ]; do
    if redis-cli -u "${REDIS_CACHE}" ping 2>/dev/null | grep -q PONG; then
        echo "✅ Redis Cache ready!"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge 30 ]; then
        echo "❌ Redis Cache not responding"
        exit 1
    fi
    echo "... redis-cache attempt $RETRY_COUNT/30 ..."
    sleep 2
done

# Wait for Redis Queue
echo "--- Waiting for Redis Queue... ---"
RETRY_COUNT=0
while [ $RETRY_COUNT -lt 30 ]; do
    if redis-cli -u "${REDIS_QUEUE}" ping 2>/dev/null | grep -q PONG; then
        echo "✅ Redis Queue ready!"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge 30 ]; then
        echo "❌ Redis Queue not responding"
        exit 1
    fi
    echo "... redis-queue attempt $RETRY_COUNT/30 ..."
    sleep 2
done

# Wait for Redis SocketIO
echo "--- Waiting for Redis SocketIO... ---"
RETRY_COUNT=0
while [ $RETRY_COUNT -lt 30 ]; do
    if redis-cli -u "${REDIS_SOCKETIO}" ping 2>/dev/null | grep -q PONG; then
        echo "✅ Redis SocketIO ready!"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge 30 ]; then
        echo "❌ Redis SocketIO not responding"
        exit 1
    fi
    echo "... redis-socketio attempt $RETRY_COUNT/30 ..."
    sleep 2
done

echo "=============================================="
echo "--- All services ready ---"

cd /home/frappe/frappe-bench

echo "--- Recreating apps.txt ---"
rm -f sites/apps.txt
echo "frappe" > sites/apps.txt
echo "erpnext" >> sites/apps.txt

echo "--- Fixing permissions ---"
chown -R frappe:frappe /home/frappe/frappe-bench/sites

echo "--- Creating new site (${SITE_NAME}) ---"
exec su - frappe -c "
cd /home/frappe/frappe-bench && \
bench new-site \"${SITE_NAME}\" \
  --db-type mariadb \
  --db-host \"${DB_HOST}\" \
  --db-port ${DB_PORT:-3306} \
  --db-name \"${DB_NAME}\" \
  --mariadb-root-username \"${DB_ROOT_USER:-root}\" \
  --mariadb-root-password \"${DB_PASSWORD}\" \
  --admin-password \"${ADMIN_PASSWORD}\" \
  --no-mariadb-socket \
  --install-app erpnext \
  --force && \
bench --site \"${SITE_NAME}\" set-config db_host \"${DB_HOST}\" && \
bench --site \"${SITE_NAME}\" set-config db_port ${DB_PORT:-3306} && \
bench start
"
