#!/bin/bash
# One-shot bootstrap run by supervisord (autorestart=false).
# Waits for MariaDB + Redis, writes the bench config and creates the ERPNext
# site on first boot. On subsequent boots (site already exists) it just exits.
set -euo pipefail

: "${SITE_NAME:=erp.localhost}"
: "${DB_ROOT_PASSWORD:=admin}"
: "${ADMIN_PASSWORD:=admin}"

BENCH=/home/frappe/frappe-bench
cd "$BENCH"

echo "[site-init] Waiting for MariaDB..."
until mysqladmin ping -h 127.0.0.1 --silent 2>/dev/null; do sleep 2; done

echo "[site-init] Ensuring database root credentials..."
# Fresh datadir: root@localhost has no password and connects via socket only.
# Set the password and add a TCP-capable root@'%' for bench (db_host=127.0.0.1).
mysql -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

echo "[site-init] Waiting for Redis..."
until [ "$(redis-cli -h 127.0.0.1 ping 2>/dev/null)" = "PONG" ]; do sleep 2; done

echo "[site-init] Writing common_site_config.json..."
cat > "$BENCH/sites/common_site_config.json" <<CFG
{
 "db_host": "127.0.0.1",
 "db_port": 3306,
 "redis_cache": "redis://127.0.0.1:6379",
 "redis_queue": "redis://127.0.0.1:6379",
 "redis_socketio": "redis://127.0.0.1:6379",
 "socketio_port": 9000
}
CFG
chown frappe:frappe "$BENCH/sites/common_site_config.json"

if [ ! -f "$BENCH/sites/${SITE_NAME}/site_config.json" ]; then
    echo "[site-init] Creating site ${SITE_NAME} and installing ERPNext (first boot)..."
    su - frappe -c "cd $BENCH && bench new-site '${SITE_NAME}' \
        --db-root-username root \
        --mariadb-root-password '${DB_ROOT_PASSWORD}' \
        --admin-password '${ADMIN_PASSWORD}' \
        --mariadb-user-host-login-scope='%' \
        --install-app erpnext \
        --set-default"
    echo "[site-init] Site created."
else
    echo "[site-init] Site ${SITE_NAME} already exists; skipping creation."
fi

echo "[site-init] Done."
