# All-in-one ERPNext image for EasyPanel (single service)
#
# Bundles ERPNext + Frappe (official v15 image) together with MariaDB, Redis
# and Nginx, orchestrated by supervisord, so the whole stack runs from ONE
# container / ONE EasyPanel service.
#
# For production at scale, prefer the multi-service docker-compose approach
# (see DEPLOY-EASYPANEL.md). This all-in-one image is optimised for a simple,
# self-contained deployment.

FROM frappe/erpnext:v15

# --- extra Frappe apps -----------------------------------------------------
# HR & Payroll ("hrms") was split out of erpnext core in v14, so pull it in as
# a separate app. --skip-assets: assets are (re)built at container start.
USER frappe
RUN cd /home/frappe/frappe-bench \
    && bench get-app --branch version-15 --skip-assets hrms

# --- system services on top of the official image -------------------------
USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        mariadb-server \
        mariadb-client \
        redis-server \
        redis-tools \
        nginx \
        supervisor \
        gettext-base \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null || true

# MariaDB tuning required by Frappe (utf8mb4)
COPY docker/mariadb-frappe.cnf /etc/mysql/mariadb.conf.d/99-frappe.cnf

# Process orchestration + startup scripts
COPY docker/supervisord.conf     /etc/supervisor/conf.d/erpnext.conf
COPY docker/nginx.conf.template  /etc/nginx/frappe.conf.template
COPY docker/entrypoint.sh        /usr/local/bin/erpnext-entrypoint.sh
COPY docker/site-init.sh         /usr/local/bin/site-init.sh

RUN chmod +x /usr/local/bin/erpnext-entrypoint.sh /usr/local/bin/site-init.sh \
    && mkdir -p /var/lib/mysql /run/mysqld /var/log/supervisor \
    && chown -R mysql:mysql /var/lib/mysql /run/mysqld

# Runtime configuration (override these in EasyPanel > Environment)
ENV SITE_NAME=erp.localhost \
    ADMIN_PASSWORD=admin \
    DB_ROOT_PASSWORD=admin \
    GUNICORN_WORKERS=2

# Nginx listens here; point the EasyPanel domain/proxy at container port 8080
EXPOSE 8080

# Persist these two paths with EasyPanel volumes:
#   /var/lib/mysql                    -> database
#   /home/frappe/frappe-bench/sites   -> site files, config, uploads
VOLUME ["/var/lib/mysql", "/home/frappe/frappe-bench/sites"]

ENTRYPOINT ["/usr/local/bin/erpnext-entrypoint.sh"]
