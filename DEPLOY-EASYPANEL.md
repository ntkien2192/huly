# Deploy ERPNext on EasyPanel

This repo ships an **all-in-one Dockerfile** that bundles everything ERPNext
needs into a single container/service:

| Component | Role |
|-----------|------|
| Frappe + ERPNext (`frappe/erpnext:v15`) | the application |
| MariaDB | database |
| Redis | cache + job queue + realtime |
| Nginx | web frontend on port **8080** |
| supervisord | keeps all of the above running |

It is the simplest way to get ERPNext live on EasyPanel: **one service, one
Dockerfile, one exposed port**. First boot automatically creates the site and
installs ERPNext.

---

## 1. Create the service

1. In EasyPanel, open (or create) a **Project** → **Add Service** → **App**.
2. **Source** → **GitHub** → pick this repo and branch
   `claude/erpnext-repo-setup-xzu4tl`.
3. **Build** → **Dockerfile** (path: `Dockerfile`, the repo root).

## 2. Environment variables

Set these under the service's **Environment** tab:

| Variable | Example | Notes |
|----------|---------|-------|
| `SITE_NAME` | `erp.example.com` | **Use the exact domain** you will attach in step 4. |
| `ADMIN_PASSWORD` | `a-strong-secret` | password for the `Administrator` user. |
| `DB_ROOT_PASSWORD` | `another-secret` | MariaDB root password. |
| `GUNICORN_WORKERS` | `2` | web workers; raise on bigger servers. |

> `SITE_NAME` should match the domain so generated links resolve correctly.

## 3. Volumes (required for persistence)

Under **Mounts / Volumes**, add two volumes — **without these your data is
wiped on every redeploy**:

| Mount path | Purpose |
|------------|---------|
| `/var/lib/mysql` | database files |
| `/home/frappe/frappe-bench/sites` | site config, uploads, files |

## 4. Domain & port

- Under **Domains**, add your domain and enable **HTTPS** (EasyPanel handles
  the TLS certificate and proxies to the container).
- Set the proxy **target port** to **`8080`**.

## 5. Resources

Give the service at least **2 GB RAM** (MariaDB + gunicorn + node + workers all
live in one container). 1 vCPU is enough for a small instance.

## 6. Deploy

Click **Deploy**. Watch the **Logs**:

- On the **first** boot you will see
  `[site-init] Creating site ... installing ERPNext (first boot)` — this takes
  **~3–5 minutes** while the database is built.
- When you see `[site-init] Done.`, open your domain.

**Login:** `Administrator` / the `ADMIN_PASSWORD` you set. You will be greeted
by the ERPNext setup wizard (language / timezone / currency).

---

## Updating / redeploying

Redeploys reuse the mounted volumes, so the site is **not** recreated — the
`site-init` step detects the existing site and skips it. To upgrade ERPNext
itself, bump the base image tag in the `Dockerfile` (e.g. a newer `v15.x`) and
redeploy; run `bench --site $SITE_NAME migrate` from the service's terminal if a
schema migration is needed.

## Notes & limitations

- **All-in-one trade-off:** simplest to run, but database and app share one
  container and scale together. For production at scale, split them out.
- No SMTP is configured — set up an outgoing email account inside ERPNext
  (*Settings → Email Account*) to send mail.

## Alternative: multi-service (production)

For a horizontally-scalable setup, use Frappe's official multi-container stack
instead of this image: <https://github.com/frappe/frappe_docker> (`pwd.yml` is
a good starting point). EasyPanel can run it via a **Compose** service. That
separates MariaDB, Redis, gunicorn, websocket, workers, scheduler and the Nginx
frontend into independent, individually-scalable services.
