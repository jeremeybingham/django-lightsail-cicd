#!/usr/bin/env bash
# One-time setup: renames every __APP_NAME__ placeholder in this template to
# your actual Django project name, then removes itself.
#
# <app-name> must match your Django project's package name — the directory
# containing settings.py/wsgi.py, i.e. what `django-admin startproject
# <app-name>` would create — because deploy/gunicorn.service points
# Gunicorn at `<app-name>.wsgi:application`.
#
# Usage: ./init.sh <app-name>
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <app-name>" >&2
    echo "  <app-name> should be lowercase, no spaces, and match your" >&2
    echo "  Django project's package name (e.g. 'myapp')." >&2
    exit 1
fi

app_name="$1"

if [[ ! "$app_name" =~ ^[a-z][a-z0-9_]*$ ]]; then
    echo "init.sh: app name must be lowercase, start with a letter, and contain only letters/digits/underscores (got: $app_name)" >&2
    exit 1
fi

echo "init.sh: setting app name to '$app_name'"

files=$(grep -rl '__APP_NAME__' . \
    --exclude-dir=.git \
    --exclude=init.sh)

for f in $files; do
    sed -i "s/__APP_NAME__/${app_name}/g" "$f"
    echo "init.sh: updated $f"
done

cat <<EOF
init.sh: done.

Remaining manual steps (see README.md and docs/):
  - Replace <owner>/<repo> placeholders in docs/ with your real GitHub
    repo path.
  - Replace ${app_name}.example.com in deploy/nginx.conf and
    CSRF_TRUSTED_ORIGINS in .env.example with your real domain.
  - Merge these files into your Django project if this template wasn't
    started as the project root (requirements.txt needs gunicorn +
    python-decouple; settings.py needs the wiring in docs/settings.md).

init.sh: removing myself now.
EOF
rm -- "$0"
