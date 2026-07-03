#!/bin/bash
# PID 1 for the all-in-one container.
# Prepares the MariaDB data directory and the Nginx config, then hands off to
# supervisord which runs MariaDB, Redis, the Frappe processes and Nginx.
set -euo pipefail

: "${SITE_NAME:=erp.localhost}"
: "${DB_ROOT_PASSWORD:=admin}"
: "${ADMIN_PASSWORD:=admin}"
: "${GUNICORN_WORKERS:=2}"
export SITE_NAME DB_ROOT_PASSWORD ADMIN_PASSWORD GUNICORN_WORKERS

echo "[entrypoint] SITE_NAME=${SITE_NAME}"

# --- MariaDB data directory (lives on a volume) ----------------------------
mkdir -p /var/lib/mysql /run/mysqld
chown -R mysql:mysql /var/lib/mysql /run/mysqld
if [ ! -d /var/lib/mysql/mysql ]; then
    echo "[entrypoint] Initialising fresh MariaDB data directory..."
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql \
        --auth-root-authentication-method=normal >/dev/null
fi

# --- sites directory (lives on a volume) -----------------------------------
mkdir -p /home/frappe/frappe-bench/sites
chown -R frappe:frappe /home/frappe/frappe-bench/sites

# --- render the Nginx config for this site ---------------------------------
export SITE_NAME
envsubst '${SITE_NAME}' \
    < /etc/nginx/frappe.conf.template \
    > /etc/nginx/conf.d/frappe.conf

echo "[entrypoint] Starting supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/erpnext.conf
