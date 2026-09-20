# django-lightsail-cicd

A reusable scaffolding for deploying a small, low-traffic Django app to a
single AWS Lightsail (or EC2) instance, with GitHub Actions CI/CD that
auto-deploys on merge to `main`. Extracted from a working production setup
(Gunicorn + systemd + Nginx + SQLite + a self-hosted Actions runner, no
inbound credentials, no Docker/Kubernetes) — see `docs/cicd.md` for the
full design rationale.

## Who this is for

This is *not* a general-purpose, horizontally-scaled deployment template.
It's built for the "one small Django app, one small VPS, a handful of
known users, brief restart downtime is fine" case — a personal project,
an internal tool, a small business app. If you need zero-downtime
deploys, multiple app servers, or a managed database, use this as a
reference for the CI/CD wiring, but expect to swap the Gunicorn/Nginx/
SQLite pieces underneath it (see `docs/settings.md` → "Why SQLite").

## What's included

```
init.sh                      one-time setup script (see Quickstart)
.env.example                 env vars this scaffolding expects
.github/workflows/deploy.yml test-then-deploy GitHub Actions workflow
deploy/
  gunicorn.service           systemd unit for Gunicorn
  nginx.conf                 Nginx site config (HTTP only; certbot adds HTTPS)
  deploy.sh                  runs on the server on every deploy
  backup.sh                  GPG-encrypted SQLite backups, optional S3 upload
docs/
  settings.md                settings.py wiring this scaffolding expects
  deployment_dry_run.md      local (WSL) dry run before touching a real server
  deployment_lightsail.md    first-time production setup on Lightsail/EC2
  cicd.md                    self-hosted runner + CI/CD setup and design
```

There is deliberately no Django project skeleton here (no `manage.py`,
no app code) — this scaffolding is meant to sit alongside an existing (or
freshly `django-admin startproject`'d) Django project, not replace it.

## Quickstart

1. Use this repo as a template (GitHub's "Use this template" button), or
   copy its files into an existing Django project's repo root.
2. Run the init script once, with your app's name — this must match your
   Django project's package name (the directory holding `settings.py`/
   `wsgi.py`), since `deploy/gunicorn.service` points Gunicorn at
   `<app-name>.wsgi:application`:
   ```bash
   ./init.sh myapp
   ```
   This substitutes every `__APP_NAME__` placeholder across `deploy/`,
   `.github/`, `docs/`, and `.env.example`, then deletes itself.
3. Wire your `settings.py` per `docs/settings.md`, and add `gunicorn` +
   `python-decouple` to `requirements.txt`.
4. Follow `docs/deployment_dry_run.md`, then `docs/deployment_lightsail.md`,
   to get a real server running.
5. Follow `docs/cicd.md` to set up the self-hosted runner and enable
   auto-deploy on merge to `main`.

## What's left as manual placeholders after `init.sh`

`init.sh` only touches the app-name token — a few things are still
project-specific enough to fill in by hand (all called out in the docs
as you reach them):

- `<owner>/<repo>` — your actual GitHub path, in `docs/deployment_lightsail.md`,
  `docs/deployment_dry_run.md`, and `docs/cicd.md`.
- `__APP_NAME__.example.com` → your real domain, in `deploy/nginx.conf`
  and `.env`'s `CSRF_TRUSTED_ORIGINS`.
- The self-hosted runner label (`__APP_NAME__-lightsail` by default, in
  `.github/workflows/deploy.yml` and `docs/cicd.md`) — fine to leave as
  the app name, but change it in both places together if you want
  something else.

## Design principles this scaffolding follows

- **No inbound credentials.** The self-hosted Actions runner lives on the
  server and polls GitHub over outbound HTTPS — no SSH key or deploy
  token stored in GitHub, no new inbound port.
- **Scoped sudo, not root.** The runner's deploy user gets passwordless
  sudo for exactly four commands (two `chown`s, a restart, a status
  check) — see `docs/cicd.md` §2.
- **Nothing security-sensitive auto-applies.** `.env`, the live Nginx
  config (which certbot rewrites after initial setup), and the systemd
  unit file are never overwritten by CI — `deploy.sh` warns loudly
  instead if the repo's copy has drifted from what's installed.
- **A failed deploy fails loudly.** `deploy.sh`'s last step is a socket
  health check; if Gunicorn doesn't come back up cleanly, the workflow
  run shows red rather than leaving a half-updated app silently broken.
- **Test gate on every push and PR, deploy only on `main`.** `deploy.yml`'s
  `test` job runs everywhere; `deploy` is gated on `needs: test` plus a
  `push`-to-`main`-only `if:`, so a PR (including from a fork) never
  triggers code execution on the production box.
