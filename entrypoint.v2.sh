#!/bin/bash
# Entrypoint v3 - Final working version with logs

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
echo "DB_USER (ignored)= ${DB_USER}"
echo "DB_PASSWORD      = ${DB_PASSWORD}"
echo "REDIS_CACHE      = ${REDIS_CACHE}"
echo "REDIS_QUEUE      = ${REDIS_QUEUE}"
echo "REDIS_SOCKETIO   = ${REDIS_SOCKETIO}"
echo "----------------------------------------------"

echo "--- Entrypoint v3: Installing dependencies ---"
apt-get update && apt-get install -y mariadb-client redis-tools

# Wait for MariaDB
echo "=============================================="
echo "--- Entrypoint v3: Waiting for MariaDB to be ready ---"
until mysqladmin ping -h"${DB_HOST}" -uroot -p"${DB_PASSWORD}" --silent; do
  echo "... MariaDB sleeping 5s ..."
  sleep 5
done
echo "✅ MariaDB is ready!"

# Wait for Redis
echo "--- Entrypoint v3: Waiting for Redis Cache... ---"
until redis-cli -u "${REDIS_CACHE}" ping | grep -q PONG; do
  echo "... redis-cache sleeping 5s ..."
  sleep 5
done
echo "✅ Redis Cache ready!"

echo "--- Entrypoint v3: Waiting for Redis Queue... ---"
until redis-cli -u "${REDIS_QUEUE}" ping | grep -q PONG; do
  echo "... redis-queue sleeping 5s ..."
  sleep 5
done
echo "✅ Redis Queue ready!"

echo "--- Entrypoint v3: Waiting for Redis SocketIO... ---"
until redis-cli -u "${REDIS_SOCKETIO}" ping | grep -q PONG; do
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

echo "--- Entrypoint v3: Creating new site (${SITE_NAME}) ---"
exec su - frappe -c "
cd /home/frappe/frappe-bench && \
bench new-site \"${SITE_NAME}\" \
  --db-type mariadb \
  --db-name \"${DB_NAME}\" \
  --db-root-username root \
  --db-root-password \"${DB_PASSWORD}\" \
  --mariadb-user-host-login-scope='%' \
  --admin-password \"${ADMIN_PASSWORD}\" \
  --install-app erpnext \
  --force && \
bench start
"
