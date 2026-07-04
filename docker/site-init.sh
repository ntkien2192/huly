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
# Two cases:
#  - fresh datadir  -> root@localhost has no password (connect with no -p)
#  - persisted vol  -> root already has the password set on a previous boot
# Detect which, then ensure a TCP-capable root@'%' exists for bench
# (db_host=127.0.0.1). Never let this step abort site-init.
if mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
    echo "[site-init]  fresh datadir: setting root password"
    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';" || true
    ROOT_AUTH="-p${DB_ROOT_PASSWORD}"
elif mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT 1" >/dev/null 2>&1; then
    echo "[site-init]  existing datadir: root password already set"
    ROOT_AUTH="-p${DB_ROOT_PASSWORD}"
else
    echo "[site-init]  WARN: could not authenticate as MariaDB root (password mismatch with the persisted volume?)"
    ROOT_AUTH="-p${DB_ROOT_PASSWORD}"
fi
mysql -u root ${ROOT_AUTH} <<SQL || echo "[site-init] WARN: could not ensure root@'%'"
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
ALTER USER 'root'@'%' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

echo "[site-init] Waiting for Redis..."
until [ "$(redis-cli -h 127.0.0.1 ping 2>/dev/null)" = "PONG" ]; do sleep 2; done

# common_site_config.json is written by the entrypoint before supervisord starts,
# so bench already has the correct db/redis endpoints here.

if [ ! -f "$BENCH/sites/${SITE_NAME}/site_config.json" ]; then
    echo "[site-init] Creating site ${SITE_NAME} (first boot)..."
    su - frappe -c "cd $BENCH && bench new-site '${SITE_NAME}' \
        --db-root-username root \
        --mariadb-root-password '${DB_ROOT_PASSWORD}' \
        --admin-password '${ADMIN_PASSWORD}' \
        --mariadb-user-host-login-scope='%' \
        --set-default"
    echo "[site-init] Site created."
else
    echo "[site-init] Site ${SITE_NAME} already exists; skipping creation."
fi

# Ensure every bundled app is installed on the site. A container restart during
# the first install can leave the site half-installed -> requests 500 with
# "App <x> is not installed". Installing again completes it; an already-installed
# app is a no-op. erpnext goes first (others depend on it); the rest are picked
# up automatically from the apps present in the image.
INSTALLED="$(su - frappe -c "cd $BENCH && bench --site '${SITE_NAME}' list-apps" 2>/dev/null || true)"
APPS="erpnext $(ls -1 "$BENCH/apps" 2>/dev/null | grep -vxE 'frappe|erpnext' | tr '\n' ' ')"
for app in ${APPS}; do
    [ -d "$BENCH/apps/${app}" ] || continue
    if echo "${INSTALLED}" | grep -qw "${app}"; then
        echo "[site-init] ${app} already installed."
    else
        echo "[site-init] Installing ${app} (this can take a few minutes; do NOT redeploy until it finishes)..."
        su - frappe -c "cd $BENCH && bench --site '${SITE_NAME}' install-app ${app}" \
            && echo "[site-init] ${app} installed." \
            || echo "[site-init] WARN: ${app} install did not complete cleanly."
    fi
done
# Make sure the schema is fully migrated (completes any interrupted install).
su - frappe -c "cd $BENCH && bench --site '${SITE_NAME}' migrate" \
    || echo "[site-init] WARN: migrate did not complete cleanly."

# The public website (and even the login page) initialises a "Guest" session on
# every request; if the Guest user is disabled — which a half-finished earlier
# install can leave behind — the whole site 500s with "User Guest is disabled".
# Ensure it is enabled on every boot (idempotent, cheap).
echo "[site-init] Ensuring Guest user is enabled..."
su - frappe -c "cd $BENCH && bench --site '${SITE_NAME}' execute frappe.db.set_value --args \"['User', 'Guest', 'enabled', 1]\"" \
    || echo "[site-init] WARN: could not enable Guest user"

echo "[site-init] Done."
