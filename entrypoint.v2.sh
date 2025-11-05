#!/bin/bash
# This is the final, corrected entrypoint script (v2)

# Exit immediately if any command fails
set -e

echo "--- Entrypoint v2: Installing dependencies ---"
apt-get update && apt-get install -y mariadb-client redis-tools

echo "--- Entrypoint v2: Waiting for MariaDB (as root)... ---"
until mysqladmin ping -h${DB_HOST} -uroot -p${MARIADB_MYSQLROOTPASSWORD} --silent; do
    echo "...maria sleeping 5s..."
    sleep 5
done

echo "--- Entrypoint v2: Waiting for Redis Cache... ---"
until redis-cli -u ${REDIS_CACHE} ping; do
    echo "...redis-cache sleeping 5s..."
    sleep 5
done

echo "--- Entrypoint v2: Waiting for Redis Queue... ---"
until redis-cli -u ${REDIS_QUEUE} ping; do
    echo "...redis-queue sleeping 5s..."
    sleep 5
done

echo "--- Entrypoint v2: ALL SERVICES READY! Recreating apps.txt... ---"
cd /home/frappe/frappe-bench
rm -f sites/apps.txt
(echo 'frappe' > sites/apps.txt && echo 'erpnext' >> sites/apps.txt)

echo "--- Entrypoint v2: Changing permissions... ---"
chown -R frappe:frappe /home/frappe/frappe-bench/sites

echo "--- Entrypoint v2: Switching to frappe user to run installation... ---"
# Use 'exec' to hand over control to the final command
exec su - frappe -c "cd /home/frappe/frappe-bench && \
    bench new-site ${SITE_NAME} \
    --no-mariadb-socket \
    --db-type mariadb \
    --db-name ${DB_NAME} \
    --db-root-username ${DB_USER} \
    --db-root-password ${DB_PASSWORD} \
    --db-host ${DB_HOST} \
    --admin-password ${ADMIN_PASSWORD} \
    --install-app erpnext \
    --force && \
    bench start"
