# Deploying `__APP_NAME__` — local dry run (Ubuntu on WSL)

Companion to `deployment_lightsail.md` (the production deployment). This
doc proves the Gunicorn + systemd + Nginx stack actually works, using the
exact same `deploy/` files that will run in production, before anything
touches a real server. Do this one first — once it works end to end,
`deployment_lightsail.md` is mostly "same steps again, real domain, real
cert."

Assumes Ubuntu 22.04 or 24.04 under WSL2 (a real Ubuntu box works too —
skip §1), and uses [`uv`](https://docs.astral.sh/uv/) for the virtualenv
and package installs instead of raw `venv`/`pip`. Everything below runs as
commands you paste into a terminal; adjust paths and usernames to your
own.

---

## Install and start the app

### 1. Enable systemd in WSL

`deploy/gunicorn.service` is a real systemd unit, so WSL needs systemd
turned on to test it as-is (recent WSL2 supports this). Check first:

```bash
systemctl status >/dev/null 2>&1 && echo "systemd is running" || echo "systemd is NOT running"
```

If it's not running, enable it and restart the WSL instance:

```bash
sudo tee -a /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true
EOF
```

Then, from **Windows PowerShell** (not inside WSL): `wsl.exe --shutdown`,
then reopen your Ubuntu terminal.

> If you'd rather not enable systemd, you can still validate the app and
> Gunicorn manually (§4–6) and run Nginx via `sudo service nginx
> start`/`stop` instead of `systemctl` — you just won't be exercising the
> actual `gunicorn.service` unit until the real deployment.

### 2. Install packages + uv

```bash
sudo apt update
sudo apt install -y nginx sqlite3 gpg curl git

curl -LsSf https://astral.sh/uv/install.sh | sh
source "$HOME/.local/bin/env"   # or: exec $SHELL, to pick up PATH
uv --version
```

### 3. Get the code onto the box, at the same path prod will use

`deploy/gunicorn.service` and `deploy/nginx.conf` both hardcode
`/opt/__APP_NAME__` — using it locally too means you're testing the real files,
not a lookalike.

If the repo is private, a plain `git clone https://...` will prompt for
credentials it doesn't have. The cleanest fix is a GitHub
[deploy key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys#deploy-keys)
— a dedicated, read-only, repo-scoped SSH key, rather than your personal
key or a PAT:

```bash
ssh-keygen -t ed25519 -C "__APP_NAME__-deploy@wsl" -f ~/.ssh/__APP_NAME___deploy_key -N ""
cat ~/.ssh/__APP_NAME___deploy_key.pub
```

Add the printed public key at **github.com/&lt;owner&gt;/&lt;repo&gt; →
Settings → Deploy keys → Add deploy key**, leaving "Allow write access"
unchecked (clone/pull only needs read). Then point SSH at it for
`github.com` and clone over SSH instead of HTTPS:

```bash
cat >> ~/.ssh/config <<'EOF'
Host github.com
  IdentityFile ~/.ssh/__APP_NAME___deploy_key
  IdentitiesOnly yes
EOF
ssh-keyscan github.com >> ~/.ssh/known_hosts

sudo mkdir -p /opt/__APP_NAME__
sudo chown "$USER":"$USER" /opt/__APP_NAME__
git clone git@github.com:<owner>/<repo>.git /opt/__APP_NAME__
cd /opt/__APP_NAME__
```

Do this clone as your regular sudo user — the `__APP_NAME__` service account
created in §8 never needs its own GitHub access; it just inherits the
already-cloned files via `chown -R __APP_NAME__:__APP_NAME__ /opt/__APP_NAME__`.

(If you already have your own personal SSH key registered with GitHub on
this machine, that works fine too for a local dry run — a deploy key just
keeps things consistent with how `deployment_lightsail.md` has to do it,
where a personal key isn't appropriate.)

### 4. Virtualenv + dependencies with uv

```bash
uv venv .venv
uv pip install --python .venv/bin/python -r requirements.txt
```

(`uv venv .venv` creates the venv; `uv pip install --python .venv/bin/python`
installs into it without needing `source .venv/bin/activate` first — though
activating is fine too if you prefer running `python manage.py ...` directly.)

### 5. Configure `.env`

```bash
cp .env.example .env
```

Edit `/opt/__APP_NAME__/.env`:
- `SECRET_KEY` — generate one:
  `.venv/bin/python -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())"`
- `DEBUG=False` (the whole point of this dry run is testing the
  production path, not `runserver`)
- `ALLOWED_HOSTS=localhost,127.0.0.1`
- `TIME_ZONE` — your real IANA timezone
- Leave `SECURE_SSL_REDIRECT`, `SESSION_COOKIE_SECURE`, `CSRF_COOKIE_SECURE`
  **uncommented as `False`** for now — there's no real TLS cert on this WSL
  box, so leave them off here and only turn them on for the real
  deployment:
  ```
  SECURE_SSL_REDIRECT=False
  SESSION_COOKIE_SECURE=False
  CSRF_COOKIE_SECURE=False
  ```

### 6. Migrate, create an account, collect static

```bash
.venv/bin/python manage.py migrate
.venv/bin/python manage.py createsuperuser
.venv/bin/python manage.py collectstatic --noinput
```

(Add any app-specific fixture loading/seeding your project needs here.)

### 7. Sanity-check the app before adding Gunicorn/Nginx

```bash
.venv/bin/python manage.py runserver 0.0.0.0:8000
```

Visit `http://localhost:8000/` from Windows (WSL2 forwards `localhost`
automatically) and confirm the app loads and login works. `Ctrl-C` to stop.

### 8. Gunicorn as a systemd service

```bash
sudo adduser --system --group --no-create-home __APP_NAME__
sudo chown -R __APP_NAME__:__APP_NAME__ /opt/__APP_NAME__
sudo cp deploy/gunicorn.service /etc/systemd/system/__APP_NAME__-gunicorn.service
sudo systemctl daemon-reload
sudo systemctl enable --now __APP_NAME__-gunicorn
sudo systemctl status __APP_NAME__-gunicorn
```

`journalctl -u __APP_NAME__-gunicorn -f` shows the access/error log stream.
Confirm the socket exists: `ls -l /run/__APP_NAME__/gunicorn.sock`.

### 9. Nginx in front of it

Nginx's worker processes run as `www-data`, but the socket Gunicorn
listens on (`/run/__APP_NAME__/gunicorn.sock`) is only reachable by the `__APP_NAME__`
user/group (`RuntimeDirectoryMode=0750`, socket created with `--umask 007`
in `deploy/gunicorn.service`). Without this, Nginx gets a permission error
talking to Gunicorn and the site 502s even though both services report
"running":

```bash
sudo usermod -aG __APP_NAME__ www-data
```

(Takes effect the next time Nginx's worker processes are spawned — the
`systemctl restart nginx` below covers that.)

For this local dry run there's no real domain or Let's Encrypt cert
available, and `deploy/nginx.conf` as checked in is plain HTTP on port 80
anyway (see the comment at its top — certbot adds HTTPS later, in
production). Just move it off :80 so it doesn't fight anything already
listening there:

```bash
sed 's/listen 80;/listen 8080;/; s/listen \[::\]:80;/listen [::]:8080;/' \
    deploy/nginx.conf > /tmp/__APP_NAME__-nginx-local.conf
sudo cp /tmp/__APP_NAME__-nginx-local.conf /etc/nginx/sites-available/__APP_NAME__
sudo ln -sf /etc/nginx/sites-available/__APP_NAME__ /etc/nginx/sites-enabled/__APP_NAME__
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl restart nginx
```

Visit `http://localhost:8080/` from Windows. You're now exercising the
exact request path production uses (Nginx → Unix socket → Gunicorn →
Django), including `/static/` being served by Nginx, not Django.

Once this works end to end, the dry run is done — the same `deploy/`
files, unmodified except for the temporary local Nginx port substitution
above, are what `deployment_lightsail.md` installs on the real server.

---

## Troubleshooting

**Nginx and Gunicorn both report "active (running)", but
`http://localhost:8080/` 502s.** Check whether Nginx can actually reach
Gunicorn's socket:
```bash
sudo -u www-data curl --unix-socket /run/__APP_NAME__/gunicorn.sock http://localhost/
sudo tail -n 30 /var/log/nginx/__APP_NAME__-error.log
```
A `Permission denied` connecting to the socket means Nginx's `www-data`
user isn't in the `__APP_NAME__` group — see the note at the top of §9.

**`__APP_NAME__-gunicorn.service` won't stay up / keeps restarting** —
`sudo journalctl -u __APP_NAME__-gunicorn -n 40 --no-pager` shows why. If it's
`Control server error: [Errno 30] Read-only file system: '/nonexistent'`,
your `/etc/systemd/system/__APP_NAME__-gunicorn.service` predates the
`Environment=HOME=/opt/__APP_NAME__` fix in `deploy/gunicorn.service` — copy the
current version over and `daemon-reload` + restart.

---

## Backups dry run

```bash
gpg --batch --passphrase '' --quick-generate-key "__APP_NAME__-backup <you@example.com>" default default never
```

In `.env`, set `BACKUP_GPG_RECIPIENT=you@example.com` (matching the key
above), then:

```bash
sudo cp deploy/backup.sh /opt/__APP_NAME__/backup.sh
sudo chmod 750 /opt/__APP_NAME__/backup.sh
sudo -u __APP_NAME__ /opt/__APP_NAME__/backup.sh
ls -l /opt/__APP_NAME__/backups/
```

Test the restore path now, while it's low-stakes:

```bash
sudo systemctl stop __APP_NAME__-gunicorn
LATEST=$(ls -t /opt/__APP_NAME__/backups/*.gpg | head -1)
gpg --decrypt "$LATEST" | gunzip > /tmp/restored.sqlite3
sqlite3 /tmp/restored.sqlite3 ".tables"   # sanity check
sudo cp /tmp/restored.sqlite3 /opt/__APP_NAME__/db.sqlite3
sudo chown __APP_NAME__:__APP_NAME__ /opt/__APP_NAME__/db.sqlite3
sudo systemctl start __APP_NAME__-gunicorn
```
