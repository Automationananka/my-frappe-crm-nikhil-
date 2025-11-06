#!/bin/bash
# Entrypoint v2 - Railway Production with MySQL (Optimized)
set -e

# Trap errors and show where script failed
trap 'echo "❌ Script failed at line $LINENO with exit code $?"; exit 1' ERR

echo "🚀 Starting Frappe/ERPNext on Railway..."
echo "=============================================="

# Environment Variables from Railway
# Support Railway's DATABASE_URL format: mysql://user:pass@host:port/dbname
if [ -n "${DATABASE_URL}" ]; then
    echo "📦 Using DATABASE_URL from Railway..."
    # Parse DATABASE_URL
    DB_HOST=$(echo "${DATABASE_URL}" | sed -n 's/.*@\([^:]*\):.*/\1/p')
    DB_PORT=$(echo "${DATABASE_URL}" | sed -n 's/.*:\([0-9]*\)\/.*/\1/p')
    DB_USER=$(echo "${DATABASE_URL}" | sed -n 's/.*:\/\/\([^:]*\):.*/\1/p')
    DB_PASSWORD=$(echo "${DATABASE_URL}" | sed -n 's/.*:\/\/[^:]*:\([^@]*\)@.*/\1/p')
    DB_NAME=$(echo "${DATABASE_URL}" | sed -n 's/.*\/\([^?]*\).*/\1/p')
else
    # Support both Railway MySQL service and custom MariaDB
    DB_HOST="${MYSQLHOST:-${DB_HOST}}"
    DB_PORT="${MYSQLPORT:-${DB_PORT:-3306}}"
    DB_NAME="${MYSQLDATABASE:-${DB_NAME}}"
    DB_USER="${MYSQLUSER:-${DB_USER:-root}}"
    DB_PASSWORD="${MYSQLPASSWORD:-${DB_PASSWORD}}"
fi
SITE_NAME="${SITE_NAME:-erpnext.localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

# Redis URLs
REDIS_CACHE_URL="${REDIS_CACHE}"
REDIS_QUEUE_URL="${REDIS_QUEUE}"
REDIS_SOCKETIO_URL="${REDIS_SOCKETIO:-$REDIS_CACHE}"

echo "🔍 Configuration:"
echo "SITE_NAME: ${SITE_NAME}"
echo "DB_HOST: ${DB_HOST}"
echo "DB_PORT: ${DB_PORT}"
echo "DB_NAME: ${DB_NAME}"
echo "DB_USER: ${DB_USER}"
echo "DB_PASSWORD: ${DB_PASSWORD:+***SET***}"
echo "DB_PASSWORD length: ${#DB_PASSWORD} characters"
echo "REDIS_CACHE: ${REDIS_CACHE_URL:+***SET***}"
echo "REDIS_QUEUE: ${REDIS_QUEUE_URL:+***SET***}"
echo "REDIS_SOCKETIO: ${REDIS_SOCKETIO_URL:+***SET***}"
echo ""
echo "🔍 DNS Resolution Check:"
if command -v nslookup >/dev/null 2>&1; then
    echo "Resolving ${DB_HOST}..."
    nslookup "${DB_HOST}" 2>&1 | head -n 10 || echo "DNS lookup failed"
elif command -v host >/dev/null 2>&1; then
    echo "Resolving ${DB_HOST}..."
    host "${DB_HOST}" 2>&1 || echo "DNS lookup failed"
else
    echo "DNS tools not available"
fi
echo "=============================================="

# Validate required variables
if [ -z "${DB_HOST}" ] || [ -z "${DB_USER}" ] || [ -z "${DB_PASSWORD}" ] || [ -z "${DB_NAME}" ]; then
    echo "❌ ERROR: Missing required MySQL environment variables!"
    echo "Required: MYSQLHOST, MYSQLUSER, MYSQLPASSWORD, MYSQLDATABASE"
    exit 1
fi

if [ -z "${REDIS_CACHE_URL}" ] || [ -z "${REDIS_QUEUE_URL}" ]; then
    echo "❌ ERROR: Missing required Redis environment variables!"
    echo "Required: REDIS_CACHE, REDIS_QUEUE"
    exit 1
fi

# Wait for MySQL
echo "--- Waiting for MySQL at ${DB_HOST}:${DB_PORT} ---"
MAX_RETRIES=30
RETRY_COUNT=0
MYSQL_REACHABLE=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if nc -z "${DB_HOST}" "${DB_PORT}" 2>/dev/null; then
        MYSQL_REACHABLE=true
        echo "✅ MySQL is reachable!"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "... waiting for MySQL (attempt $RETRY_COUNT/$MAX_RETRIES) ..."
    sleep 2
done

if [ "$MYSQL_REACHABLE" = false ]; then
    echo "⚠️  WARNING: MySQL not reachable after $MAX_RETRIES attempts"
    echo "⚠️  Will try to proceed anyway for debugging..."
fi

# Test MySQL connection with verbose error output
if [ "$MYSQL_REACHABLE" = true ]; then
    echo "--- Testing MySQL connection ---"
    echo "Testing with command: mysql -h${DB_HOST} -P${DB_PORT} -u${DB_USER} -p[HIDDEN]"
    echo ""

    # First attempt - capture error
    MYSQL_ERROR=$(mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" --connect-timeout=10 -e "SELECT 1;" 2>&1) || MYSQL_EXIT_CODE=$?

    if [ -n "$MYSQL_EXIT_CODE" ] && [ "$MYSQL_EXIT_CODE" -ne 0 ]; then
        echo "⚠️  MySQL connection failed with exit code: $MYSQL_EXIT_CODE"
        echo ""
        echo "MySQL Error Output:"
        echo "-------------------"
        echo "$MYSQL_ERROR"
        echo "-------------------"
        echo ""
        echo "⚠️  Continuing anyway to start bench for debugging..."
        MYSQL_CONNECTED=false
    else
        echo "✅ MySQL connection verified!"
        MYSQL_CONNECTED=true
    fi
else
    echo "⚠️  Skipping MySQL connection test"
    MYSQL_CONNECTED=false
fi

# Ensure database exists
if [ "$MYSQL_CONNECTED" = true ]; then
    echo "--- Ensuring database exists ---"
    mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" \
        -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>&1 || echo "⚠️  Could not create database"
    echo "✅ Database ${DB_NAME} ready!"

    # Grant permissions if needed
    echo "--- Setting database permissions ---"
    mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" \
        -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';" 2>/dev/null || true
    mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" \
        -e "FLUSH PRIVILEGES;" 2>/dev/null || true
else
    echo "⚠️  Skipping database creation"
fi

# Wait for Redis services
for redis_var in REDIS_CACHE_URL REDIS_QUEUE_URL REDIS_SOCKETIO_URL; do
    redis_url="${!redis_var}"
    redis_name="${redis_var%_URL}"
    echo "--- Checking ${redis_name} ---"
    MAX_REDIS_RETRIES=30
    REDIS_RETRY=0
    REDIS_OK=false
    
    while [ $REDIS_RETRY -lt $MAX_REDIS_RETRIES ]; do
        if redis-cli -u "${redis_url}" ping 2>/dev/null | grep -q PONG; then
            echo "✅ ${redis_name} ready!"
            REDIS_OK=true
            break
        fi
        REDIS_RETRY=$((REDIS_RETRY + 1))
        echo "... waiting for ${redis_name} (attempt $REDIS_RETRY/$MAX_REDIS_RETRIES) ..."
        sleep 2
    done
    
    if [ "$REDIS_OK" = false ]; then
        echo "⚠️  WARNING: ${redis_name} not reachable after $MAX_REDIS_RETRIES attempts"
        echo "⚠️  Continuing anyway..."
    fi
done

echo "=============================================="
echo "🎯 Starting Frappe Bench (attempting even with errors)..."
echo "=============================================="

cd /home/frappe/frappe-bench

# Configure apps
echo "--- Configuring apps ---"
rm -f sites/apps.txt
echo "frappe" > sites/apps.txt
echo "erpnext" >> sites/apps.txt

# Fix permissions
echo "--- Setting permissions ---"
chown -R frappe:frappe /home/frappe/frappe-bench/sites || echo "⚠️  Permission changes may have failed"

# Check if site exists
SITE_DIR="sites/${SITE_NAME}"
if [ -d "${SITE_DIR}" ] && [ -f "${SITE_DIR}/site_config.json" ]; then
    echo "--- Site ${SITE_NAME} exists ---"
    
    # Only update config if MySQL is connected
    if [ "$MYSQL_CONNECTED" = true ]; then
        echo "--- Updating site configuration ---"
        su - frappe -c "
cd /home/frappe/frappe-bench && \
bench --site \"${SITE_NAME}\" set-config db_host \"${DB_HOST}\" && \
bench --site \"${SITE_NAME}\" set-config db_port ${DB_PORT} && \
bench --site \"${SITE_NAME}\" set-config redis_cache \"${REDIS_CACHE_URL}\" && \
bench --site \"${SITE_NAME}\" set-config redis_queue \"${REDIS_QUEUE_URL}\" && \
bench --site \"${SITE_NAME}\" set-config redis_socketio \"${REDIS_SOCKETIO_URL}\"
" || echo "⚠️  Config update failed, continuing..."
    fi
    
    echo "--- Starting bench ---"
    echo "🚀 Bench should be available on port 8000"
    exec su - frappe -c "cd /home/frappe/frappe-bench && bench start"
    
elif [ "$MYSQL_CONNECTED" = true ]; then
    echo "--- Creating new site: ${SITE_NAME} ---"
    
    # Create new site
    su - frappe -c "
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
  --force
" || {
        echo "❌ Site creation failed!"
        echo "⚠️  Starting bench anyway for debugging..."
        exec su - frappe -c "cd /home/frappe/frappe-bench && bench start"
    }
    
    echo "✅ Site created successfully!"
    
    # Configure Redis
    echo "--- Configuring Redis ---"
    su - frappe -c "
cd /home/frappe/frappe-bench && \
bench --site \"${SITE_NAME}\" set-config redis_cache \"${REDIS_CACHE_URL}\" && \
bench --site \"${SITE_NAME}\" set-config redis_queue \"${REDIS_QUEUE_URL}\" && \
bench --site \"${SITE_NAME}\" set-config redis_socketio \"${REDIS_SOCKETIO_URL}\"
" || echo "⚠️  Redis config failed"
    
    # Install ERPNext
    echo "--- Installing ERPNext app ---"
    su - frappe -c "
cd /home/frappe/frappe-bench && \
bench --site \"${SITE_NAME}\" install-app erpnext
" || echo "⚠️  ERPNext installation failed"
    
    echo "--- Starting bench ---"
    echo "🚀 Bench should be available on port 8000"
    exec su - frappe -c "cd /home/frappe/frappe-bench && bench start"
else
    echo "⚠️  Cannot create site without MySQL connection"
    echo "🚀 Starting bench anyway for debugging (no site will be available)"
    exec su - frappe -c "cd /home/frappe/frappe-bench && bench start"
fi
