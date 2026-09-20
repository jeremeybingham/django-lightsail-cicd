#!/usr/bin/env bash
# Runs ON the Lightsail instance, invoked by the self-hosted Actions
# runner after `main` gets new commits. Mirrors the manual steps in
# docs/deployment_lightsail.md "Updating to a newer version" — keep the two
# in sync if either changes.
set -euo pipefail

APP_DIR="/opt/__APP_NAME__"
cd "$APP_DIR"

echo "deploy.sh: reclaiming ownership for the update"
sudo chown -R ubuntu:ubuntu "$APP_DIR"

echo "deploy.sh: pulling main (fast-forward only)"
git fetch origin main
git merge --ff-only origin/main
# Capture this now, while ubuntu still owns the checkout — git refuses to
# run against a repo owned by another user ("dubious ownership"), and by
# the final log line below ownership has already moved to __APP_NAME__.
deployed_sha="$(git rev-parse --short HEAD)"

# Fail loudly rather than silently drift or break nginx/gunicorn — these
# files are installed by `cp`, not symlinked; see docs/deployment_lightsail.md.
for f in deploy/nginx.conf deploy/gunicorn.service; do
    installed="/etc/$( [[ "$f" == *nginx* ]] && echo "nginx/sites-available/__APP_NAME__" || echo "systemd/system/__APP_NAME__-gunicorn.service" )"
    if ! diff -q "$f" "$installed" >/dev/null 2>&1; then
        echo "deploy.sh: WARNING - $f differs from the installed $installed."
        echo "deploy.sh: this needs a deliberate manual apply (see docs/deployment_lightsail.md), not an auto-copy. Continuing app deploy, but go fix this by hand."
    fi
done

echo "deploy.sh: installing dependencies"
uv pip install --python .venv/bin/python -r requirements.txt

echo "deploy.sh: migrating"
.venv/bin/python manage.py migrate --noinput

echo "deploy.sh: collecting static"
.venv/bin/python manage.py collectstatic --noinput

echo "deploy.sh: handing ownership back to the __APP_NAME__ service account"
sudo chown -R __APP_NAME__:__APP_NAME__ "$APP_DIR"

echo "deploy.sh: restarting gunicorn"
sudo systemctl restart __APP_NAME__-gunicorn

sleep 2
if ! sudo systemctl is-active --quiet __APP_NAME__-gunicorn; then
    echo "deploy.sh: __APP_NAME__-gunicorn did not come back up after restart" >&2
    sudo journalctl -u __APP_NAME__-gunicorn -n 40 --no-pager >&2
    exit 1
fi

echo "deploy.sh: checking the socket actually answers"
# Django's ALLOWED_HOSTS rejects an unrecognized Host header with 400, so the
# health check has to present a host it actually accepts (the bare "localhost"
# curl sends by default isn't in production's ALLOWED_HOSTS). Read the first
# entry from .env rather than hardcoding the real domain into this repo file.
health_host="$(grep -m1 '^ALLOWED_HOSTS=' .env | cut -d= -f2- | cut -d, -f1)"
if ! curl -s --unix-socket /run/__APP_NAME__/gunicorn.sock -H "Host: ${health_host}" -o /dev/null -w '%{http_code}' http://localhost/ | grep -qE '^(2|3)'; then
    echo "deploy.sh: socket health check failed" >&2
    exit 1
fi

echo "deploy.sh: done, deployed $deployed_sha"
