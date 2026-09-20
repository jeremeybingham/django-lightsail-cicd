# Wiring `settings.py` for this deployment setup

The deploy scaffolding in this repo assumes your Django `settings.py` reads
its production-sensitive values from environment variables via
[`python-decouple`](https://pypi.org/project/python-decouple/), matching
`.env.example`. Add `python-decouple` and `gunicorn` to `requirements.txt`,
then wire these settings in (adjust names/defaults to taste — the
`.env.example` keys just need to line up with whatever you read here):

```python
from decouple import Csv, config

# SECURITY WARNING: keep the secret key used in production secret!
SECRET_KEY = config("SECRET_KEY")

# SECURITY WARNING: don't run with debug turned on in production!
DEBUG = config("DEBUG", default=False, cast=bool)

ALLOWED_HOSTS = config("ALLOWED_HOSTS", default="", cast=Csv())

CSRF_TRUSTED_ORIGINS = config("CSRF_TRUSTED_ORIGINS", default="", cast=Csv())

TIME_ZONE = config("TIME_ZONE", default="UTC")

# Where `collectstatic` writes to; Nginx serves this directory directly in
# production (see deploy/nginx.conf's `/static/` location).
STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"

SESSION_COOKIE_AGE = config("SESSION_COOKIE_AGE", default=1209600, cast=int)

# Production hardening — on by default once DEBUG=False, overridable via
# .env for a dry run without a real TLS cert yet (see docs/deployment_dry_run.md).
SECURE_SSL_REDIRECT = config("SECURE_SSL_REDIRECT", default=not DEBUG, cast=bool)
SESSION_COOKIE_SECURE = config("SESSION_COOKIE_SECURE", default=not DEBUG, cast=bool)
CSRF_COOKIE_SECURE = config("CSRF_COOKIE_SECURE", default=not DEBUG, cast=bool)
```

And confirm:

```python
WSGI_APPLICATION = "<app-name>.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": BASE_DIR / "db.sqlite3",
    }
}
```

`<app-name>` here must be the same name you passed to `init.sh` —
`deploy/gunicorn.service` hardcodes `<app-name>.wsgi:application` as its
Gunicorn entry point.

## Why SQLite

This scaffolding is built for the same scale leaf runs at: a small number
of known users on one small VPS instance, not a horizontally-scaled
service. SQLite is deliberately fine here — no separate DB server to run,
patch, or back up, and `deploy/backup.sh` already gives you consistent
online backups via `sqlite3 .backup`.

If your app needs Postgres (concurrent writers, larger scale, multiple app
servers), swap `DATABASES` for `dj-database-url`/`psycopg` and point at
RDS or a Postgres instance — the rest of this scaffolding (Gunicorn,
Nginx, the CI/CD pipeline, the self-hosted runner) is database-agnostic
and doesn't need to change. `deploy/backup.sh` would need a Postgres
equivalent (e.g. `pg_dump`) instead.
