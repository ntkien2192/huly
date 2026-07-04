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

# --- expose node on the global PATH ----------------------------------------
# The official image installs node via nvm under the frappe user's HOME, so it
# is not on the default PATH used by supervisord's children (breaks socketio).
# Symlink it into /usr/local/bin so every process can find it.
if ! command -v node >/dev/null 2>&1; then
    NODE_BIN="$(su - frappe -c 'command -v node' 2>/dev/null || true)"
    if [ -n "${NODE_BIN}" ] && [ -x "${NODE_BIN}" ]; then
        ln -sf "${NODE_BIN}" /usr/local/bin/node
        echo "[entrypoint] Linked node: ${NODE_BIN} -> /usr/local/bin/node"
    else
        echo "[entrypoint] WARNING: node binary not found; realtime (socketio) may fail."
    fi
fi

# --- sites directory (lives on a volume) -----------------------------------
BENCH=/home/frappe/frappe-bench
mkdir -p "$BENCH/sites"

# A volume mounted at sites/ hides the web assets that bench builds, which
# breaks every rendered page with "'NoneType' object has no attribute 'get'".
# Make sure the bench knows its apps, then (re)build assets into the volume
# when the manifest is missing. Kept non-fatal so a build hiccup never turns
# into a container crash-loop.
if [ ! -f "$BENCH/sites/apps.txt" ]; then
    printf 'frappe\nerpnext\n' > "$BENCH/sites/apps.txt"
fi
chown -R frappe:frappe "$BENCH/sites"
if [ ! -f "$BENCH/sites/assets/assets.json" ]; then
    echo "[entrypoint] Building web assets (first boot, this takes 1-2 min)..."
    su - frappe -c "cd $BENCH && bench build" \
        || echo "[entrypoint] WARNING: bench build failed; UI assets may be missing."
fi

# Write the bench config BEFORE supervisord starts so workers never fall back
# to Frappe's default redis ports (11311/13311) and crash-loop on boot.
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

chown -R frappe:frappe "$BENCH/sites"

# --- render the Nginx config for this site ---------------------------------
export SITE_NAME
envsubst '${SITE_NAME}' \
    < /etc/nginx/frappe.conf.template \
    > /etc/nginx/conf.d/frappe.conf

echo "[entrypoint] Starting supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/erpnext.conf
