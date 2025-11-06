#!/bin/bash
# Entrypoint for Railway Production with MySQL
set -e

echo "🚀 Starting Frappe/ERPNext on Railway..."
echo "=============================================="

# Environment Variables from Railway
DB_HOST="${MYSQLHOST}"
DB_PORT="${MYSQLPORT:-3306}"
DB_NAME="${MYSQLDATABASE}"
DB_USER="${MYSQLUSER}"
DB_PASSWORD="${MYSQLPASSWORD}"
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
echo "REDIS_CACHE: ${REDIS_CACHE_URL:+***SET***}"
echo "REDIS_QUEUE: ${REDIS_QUEUE_URL:+***SET***}"
echo "REDIS_SOCKETIO: ${REDIS_SOCKETIO_URL:+***SET***}"
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
MAX_RETRIES=60
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

# Test MySQL connection
echo "--- Testing MySQL connection ---"
if ! mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" --connect-timeout=10 -e "SELECT 1;" 2>/dev/null; then
    echo "❌ MySQL connection failed!"
    echo "Connection details:"
    echo "  Host: ${DB_HOST}"
    echo "  Port: ${DB_PORT}"
    echo "  User: ${DB_USER}"
    echo "  Database: ${DB_NAME}"
    exit 1
fi
echo "✅ MySQL connection verified!"

# Ensure database exists
echo "--- Ensuring database exists ---"
mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" \
    -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>&1
echo "✅ Database ${DB_NAME} ready!"

# Grant permissions if needed
echo "--- Setting database permissions ---"
mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" \
    -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';" 2>/dev/null || true
mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" \
    -e "FLUSH PRIVILEGES;" 2>/dev/null || true

# Wait for Redis services
for redis_var in REDIS_CACHE_URL REDIS_QUEUE_URL REDIS_SOCKETIO_URL; do
    redis_url="${!redis_var}"
    redis_name="${redis_var%_URL}"
    echo "--- Waiting for ${redis_name} ---"
    MAX_REDIS_RETRIES=60
    REDIS_RETRY=0
    until redis-cli -u "${redis_url}" ping 2>/dev/null | grep -q PONG; do
        REDIS_RETRY=$((REDIS_RETRY + 1))
        if [ $REDIS_RETRY -ge $MAX_REDIS_RETRIES ]; then
            echo "❌ ${redis_name} not reachable after $MAX_REDIS_RETRIES attempts"
            exit 1
        fi
        echo "... waiting for ${redis_name} (attempt $REDIS_RETRY/$MAX_REDIS_RETRIES) ..."
        sleep 2
    done
    echo "✅ ${redis_name} ready!"
done

echo "=============================================="
echo "✅ All services ready!"
echo "=============================================="

cd /home/frappe/frappe-bench

# Configure apps
echo "--- Configuring apps ---"
rm -f sites/apps.txt
echo "frappe" > sites/apps.txt
echo "erpnext" >> sites/apps.txt

# Fix permissions
echo "--- Setting permissions ---"
chown -R frappe:frappe /home/frappe/frappe-bench/sites

# Check if site exists
SITE_DIR="sites/${SITE_NAME}"
if [ -d "${SITE_DIR}" ] && [ -f "${SITE_DIR}/site_config.json" ]; then
    echo "--- Site ${SITE_NAME} exists, configuring ---"
    
    # Update site configuration
    su - frappe -c "
cd /home/frappe/frappe-bench && \
bench --site \"${SITE_NAME}\" set-config db_host \"${DB_HOST}\" && \
bench --site \"${SITE_NAME}\" set-config db_port ${DB_PORT} && \
bench --site \"${SITE_NAME}\" set-config redis_cache \"${REDIS_CACHE_URL}\" && \
bench --site \"${SITE_NAME}\" set-config redis_queue \"${REDIS_QUEUE_URL}\" && \
bench --site \"${SITE_NAME}\" set-config redis_socketio \"${REDIS_SOCKETIO_URL}\"
"
    
    echo "--- Starting bench ---"
    exec su - frappe -c "cd /home/frappe/frappe-bench && bench start"
else
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
"
    
    if [ $? -ne 0 ]; then
        echo "❌ Site creation failed!"
        exit 1
    fi
    
    echo "✅ Site created successfully!"
    
    # Configure Redis
    echo "--- Configuring Redis ---"
    su - frappe -c "
cd /home/frappe/frappe-bench && \
bench --site \"${SITE_NAME}\" set-config redis_cache \"${REDIS_CACHE_URL}\" && \
bench --site \"${SITE_NAME}\" set-config redis_queue \"${REDIS_QUEUE_URL}\" && \
bench --site \"${SITE_NAME}\" set-config redis_socketio \"${REDIS_SOCKETIO_URL}\"
"
    
    # Install ERPNext
    echo "--- Installing ERPNext app ---"
    su - frappe -c "
cd /home/frappe/frappe-bench && \
bench --site \"${SITE_NAME}\" install-app erpnext
"
    
    if [ $? -ne 0 ]; then
        echo "❌ ERPNext installation failed!"
        exit 1
    fi
    
    echo "✅ ERPNext installed successfully!"
    
    # Start bench
    echo "--- Starting bench ---"
    exec su - frappe -c "cd /home/frappe/frappe-bench && bench start"
fi
