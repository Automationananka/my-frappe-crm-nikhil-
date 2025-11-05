#!/bin/bash
# Final, Corrected Entrypoint Script (v3 - with logs & connection checks)
set -e

echo "=============================================="
echo "🚀 Starting Frappe/ERPNext setup on Railway..."
echo "=============================================="

echo "🔍 Environment Variables:"
echo "----------------------------------------------"
echo "SITE_NAME        = ${SITE_NAME}"
echo "DB_HOST          = ${DB_HOST}"
echo "DB_PORT          = ${DB_PORT}"
echo "DB_NAME          = ${DB_NAME}"
echo "DB_USER          = ${DB_USER}"
echo "DB_PASSWORD      = ${DB_PASSWORD}"
echo "ADMIN_PASSWORD   = ${ADMIN_PASSWORD}"
echo "REDIS_CACHE      = ${REDIS_CACHE}"
echo "REDIS_QUEUE      = ${REDIS_QUEUE}"
echo "REDIS_SOCKETIO   = ${REDIS_SOCKETIO}"
echo "NO_CACHE         = ${NO_CACHE}"
echo "----------------------------------------------"

echo "--- Entrypoint v3: Installing dependencies ---"
apt-get update -qq && apt-get install -y -qq mariadb-client redis-tools

echo "--- Entrypoint v3: Waiting for MariaDB to be ready ---"
until mysqladmin ping -h"${DB_HOST}" -u"${DB_USER}" -p"${DB_PASSWORD}" --silent; do
    echo "...MariaDB sleeping 5s..."
    sleep 5
done
echo "✅ MariaDB is ready!"

echo "--- Entrypoint v3: Waiting for Redis Cache... ---"
until redis-cli -u "${REDIS_CACHE}" ping | grep -q "PONG"; do
    echo "...Redis Cache sleeping 5s..."
    sleep 5
done
echo "✅ Redis Cache ready!"

echo "--- Entrypoint v3: Waiting for Redis Queue... ---"
until redis-cli -u "${REDIS_QUEUE}" ping | grep -q "PONG"; do
    echo "...Redis Queue sleeping 5s..."
    sleep 5
done
echo "✅ Redis Queue ready!"

if [ -n "${REDIS_SOCKETIO}" ]; then
    echo "--- Entrypoint v3: Waiting for Redis SocketIO... ---"
    until redis-cli -u "${REDIS_SOCKETIO}" ping | grep -q "PONG"; do
        echo "...Redis SocketIO sleeping 5s..."
        sleep 5
    done
    echo "✅ Redis SocketIO ready!"
fi

echo "--- Entrypoint v3: All services ready ---"
cd /home/frappe/frappe-bench

# Recreate apps.txt to include frappe and erpnext
echo "--- Entrypoint v3: Recreating apps.txt ---"
echo "frappe" > sites/apps.txt
echo "erpnext" >> sites/apps.txt

# Fix permissions
echo "--- Entrypoint v3: Fixing permissions ---"
chown -R frappe:frappe /home/frappe/frappe-bench/sites

# Run as frappe user
echo "--- Entrypoint v3: Creating new site (${SITE_NAME}) ---"
exec su - frappe -c "
cd /home/frappe/frappe-bench && \
bench new-site '${SITE_NAME}' \
  --db-type mariadb \
  --db-host '${DB_HOST}' \
  --db-name '${DB_NAME}' \
  --db-user '${DB_USER}' \
  --db-password '${DB_PASSWORD}' \
  --mariadb-user-host-login-scope='%' \
  --admin-password '${ADMIN_PASSWORD}' \
  --install-app erpnext \
  --force && \
bench use '${SITE_NAME}' && \
bench start
"
