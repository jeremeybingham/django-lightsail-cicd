# Deploying `__APP_NAME__` on Lightsail/EC2 (production)

Companion to `deployment_dry_run.md` (the local WSL dry run — do that one
first to prove the `deploy/` files work before touching a real server).
This doc repeats the same install steps on a real Ubuntu host, plus the
parts that only make sense with a public IP and a real domain: the
firewall, Let's Encrypt, and backups.

Assumes Ubuntu 24.04 LTS, and uses [`uv`](https://docs.astral.sh/uv/) for
the virtualenv and package installs instead of raw `venv`/`pip`.
Everything below runs as commands you paste into a terminal; adjust paths,
usernames and the domain name (`__APP_NAME__.example.com`) to your own.

---

## Install and start the app

### 1. Provision the instance

- Ubuntu 24.04 LTS, smallest size that fits your expected load — this
  scaffolding assumes a low-traffic app on a single small instance, not a
  horizontally-scaled service (Lightsail's cheapest tier is plenty for a
  handful of known users).
- Attach a static IP.
- Create a DNS `A` record for your domain (e.g. `__APP_NAME__.example.com`)
  pointing at that IP. Let's Encrypt needs this to resolve before issuing
  a cert.

### 2. Firewall — before anything else is reachable

**This step has no terminal commands — it's done in the Lightsail (or EC2)
web console, and it's easy to skip past since there's nothing here to
copy-paste.** Skipping it doesn't produce an error anywhere: Nginx,
Gunicorn and Django all start up and report healthy, TLS still issues
fine, and the only symptom is that `https://your.real.domain/` hangs or
times out from outside the box (it'll still work if you curl it *from
inside* the instance, which is a red herring — see "Troubleshooting"
below). Do this now, before it's a mystery to debug later:

In the Lightsail console → your instance → **Networking** tab (EC2:
the instance's security group) → inbound rules:
- `443/tcp` from anywhere (or narrower — see §12)
- `22/tcp` from your known IP only, not `0.0.0.0/0`
- everything else closed, including `80/tcp` (`certbot --nginx` opens it
  temporarily for the ACME HTTP-01 challenge, then it's nginx's own
  redirect-to-443 the rest of the time — you don't need it open at the
  cloud-firewall layer if you'd rather run certbot's DNS-01 challenge
  instead)

This is a separate mechanism from `ufw` below — both need to allow a port
for traffic to reach it; either one alone is enough to block it. Also
enable `ufw` on the instance itself as defense-in-depth, independent
of the cloud firewall:

```bash
sudo ufw default deny incoming
sudo ufw allow 22/tcp
sudo ufw allow 443/tcp
sudo ufw allow 80/tcp    # temporarily, for certbot; see §11
sudo ufw enable
```

### 3. Install packages + uv

```bash
sudo apt update
sudo apt install -y nginx sqlite3 gpg curl git

curl -LsSf https://astral.sh/uv/install.sh | sh
source "$HOME/.local/bin/env"   # or: exec $SHELL, to pick up PATH
uv --version
```

### 4. Get the code onto the box

`deploy/gunicorn.service` and `deploy/nginx.conf` both hardcode
`/opt/__APP_NAME__`.

If the repo is private, a plain `git clone https://...` will prompt for
credentials it doesn't have. The cleanest fix is a GitHub
[deploy key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys#deploy-keys)
— a dedicated, read-only, repo-scoped SSH key, rather than your personal
key or a PAT (a server shouldn't hold a key with access to your whole
GitHub account):

```bash
ssh-keygen -t ed25519 -C "__APP_NAME__-deploy@lightsail" -f ~/.ssh/__APP_NAME___deploy_key -N ""
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

Do this clone as your regular sudo user — the `__APP_NAME__` service
account created in §8 never needs its own GitHub access; it just inherits
the already-cloned files via `chown -R __APP_NAME__:__APP_NAME__ /opt/__APP_NAME__`.

### 5. Virtualenv + dependencies with uv

```bash
uv venv .venv
uv pip install --python .venv/bin/python -r requirements.txt
```

### 6. Configure `.env`

```bash
cp .env.example .env
```

Edit `/opt/__APP_NAME__/.env` — these values differ from the dry run:

```
SECRET_KEY=<freshly generated, never reused from the dry run>
DEBUG=False
ALLOWED_HOSTS=<your.real.domain>
CSRF_TRUSTED_ORIGINS=https://<your.real.domain>
TIME_ZONE=<real timezone>
```

**`<your.real.domain>` is a placeholder, like the other angle-bracket
values above — replace it with your actual domain (e.g.
`__APP_NAME__.example.com`), don't paste it literally.** Getting this
wrong is easy to miss and surprisingly hard to diagnose: Nginx/Gunicorn
will still start and report healthy, TLS still works, and the failure
only shows up as a `400 Bad Request` from Django itself once you hit the
site (`DisallowedHost` — the incoming `Host` header doesn't match
`ALLOWED_HOSTS`). If you ever see that specific symptom — cert fine,
redirect fine, plain `400` on every URL — `grep ALLOWED_HOSTS
/opt/__APP_NAME__/.env` first. See "Troubleshooting" below for the other
failure modes this deployment can hit and how to tell them apart.

Generate `SECRET_KEY` with:
```bash
.venv/bin/python -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())"
```

Leave `SECURE_SSL_REDIRECT` / `SESSION_COOKIE_SECURE` / `CSRF_COOKIE_SECURE`
**out of `.env` entirely** (don't carry over the `False` overrides from
the dry run) — with `DEBUG=False` they default to `True`, which is what
you want once a real cert is in place.

`gunicorn.service` loads `.env` once, at process start
(`EnvironmentFile=/opt/__APP_NAME__/.env`) — any later edit to `.env`
needs `sudo systemctl restart __APP_NAME__-gunicorn` before it takes
effect. This applies throughout the rest of this doc too, not just here.

### 7. Migrate, create accounts, collect static

```bash
.venv/bin/python manage.py migrate
.venv/bin/python manage.py createsuperuser
.venv/bin/python manage.py collectstatic --noinput
```

(Add any app-specific fixture loading/seeding your project needs here.)

### 8. Gunicorn as a systemd service

```bash
sudo adduser --system --group --no-create-home __APP_NAME__
sudo chown -R __APP_NAME__:__APP_NAME__ /opt/__APP_NAME__
sudo cp deploy/gunicorn.service /etc/systemd/system/__APP_NAME__-gunicorn.service
sudo systemctl daemon-reload
sudo systemctl enable --now __APP_NAME__-gunicorn
sudo systemctl status __APP_NAME__-gunicorn
```

`journalctl -u __APP_NAME__-gunicorn -f` shows the access/error log
stream. Confirm the socket exists: `ls -l /run/__APP_NAME__/gunicorn.sock`.

### 9. Nginx + Let's Encrypt

Nginx's worker processes run as `www-data`, but the socket Gunicorn
listens on (`/run/__APP_NAME__/gunicorn.sock`) is only reachable by the
`__APP_NAME__` user/group (`RuntimeDirectoryMode=0750`, socket created
with `--umask 007` in `deploy/gunicorn.service`). Without this, Nginx
gets a permission error talking to Gunicorn and the site 502s even
though both services report "running":

```bash
sudo usermod -aG __APP_NAME__ www-data
```

(Takes effect the next time Nginx's worker processes are spawned — the
`systemctl restart nginx` below covers that.)

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo cp deploy/nginx.conf /etc/nginx/sites-available/__APP_NAME__
sudo sed -i 's/__APP_NAME__.example.com/your.real.domain/' /etc/nginx/sites-available/__APP_NAME__
sudo ln -sf /etc/nginx/sites-available/__APP_NAME__ /etc/nginx/sites-enabled/__APP_NAME__
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx

sudo certbot --nginx -d your.real.domain --redirect
```

At this point `sites-available/__APP_NAME__` is plain HTTP on port 80
only — `nginx -t` succeeds because nothing references a certificate yet.
`certbot --nginx` then obtains the certificate and rewrites the file in
place: it duplicates the port-80 block into a new 443 server block with
the real `ssl_certificate`/`ssl_certificate_key` paths, and (thanks to
`--redirect`) turns the original port-80 block into a `return 301
https://...` redirect. It also sets up auto-renewal via its own systemd
timer — check it with `systemctl list-timers | grep certbot`.

Don't hand-write the 443 block or cert paths into `deploy/nginx.conf`
yourself — they don't exist until certbot creates them, and a config that
references them prematurely fails `nginx -t` before certbot ever runs.

### 10. Verify

- `curl -I http://your.real.domain/` → `301` to `https://`.
- `curl -I https://your.real.domain/` → `200` (or `302` to login), valid
  cert (no `-k` needed).
- Log in and confirm the app's core flow works end to end.
- `curl -I http://your.real.domain:8080/` (or any other port) → connection
  refused; only 443 (and 22 for SSH) should be reachable at all from the
  security group / Lightsail firewall.

### 11. Close port 80 again (optional)

If you opened `80/tcp` in `ufw`/the security group only for the ACME
challenge and don't want it open long-term, close it now — certbot's HTTP-01
renewal will fail silently until the next manual run unless you either
leave 80 open or switch to a DNS-01 challenge plugin for renewals.

### 12. Restrict exposure further (optional)

If the app shouldn't be fully publicly reachable, cheapest options, in
increasing effort:
- **IP allowlist in Nginx**: add `allow <your IP>; deny all;` inside the
  `location /` block in `deploy/nginx.conf`, and keep it in sync with your
  IP(s) — simplest, but brittle against IP changes.
- **IP allowlist at the firewall**: same idea, enforced in the Lightsail
  firewall / security group / `ufw` instead of Nginx — one fewer moving
  part inside the app stack.
- **WireGuard VPN**: put the instance's 443 listener behind a VPN-only
  security group rule, install WireGuard, and only reach the app over the
  tunnel. More setup, strongest isolation — worth it if the domain would
  otherwise be guessable/public.

---

## Troubleshooting

Symptoms and their actual causes, in the order it's usually worth checking
them:

**Browser/curl to `https://your.real.domain/` hangs or times out**, but
everything on the instance looks fine (`systemctl status` green for both
services, `curl -Ik https://localhost/` works locally). This means the
request never reached the box at all — check the **Lightsail
console → Networking tab** (or EC2 security group), not `ufw`. A firewall
rule silently dropping packets (rather than the OS rejecting them) is
exactly what produces a hang instead of "connection refused". See §2.
`sudo ufw status verbose` showing `inactive` doesn't mean anything is
wrong — it just means that layer isn't the blocker either way.

**Nginx and Gunicorn both report "active (running)", but the site 502s or
just doesn't load.** Check whether Nginx can actually reach Gunicorn's
socket:
```bash
sudo -u www-data curl --unix-socket /run/__APP_NAME__/gunicorn.sock http://localhost/
sudo tail -n 30 /var/log/nginx/__APP_NAME__-error.log
```
A `Permission denied` connecting to the socket (in the error log) or a
generic connection failure from the `www-data` curl above means Nginx's
`www-data` user isn't in the `__APP_NAME__` group — see the note at the
top of §9.

**Every URL returns a plain `400 Bad Request`** (no Nginx error, valid
TLS, Gunicorn clearly serving something) — this is Django's own
`DisallowedHost` rejection, not an infrastructure problem:
```bash
sudo grep ALLOWED_HOSTS /opt/__APP_NAME__/.env
```
If it still reads a placeholder (`__APP_NAME__.example.com`) or the dry
run's `localhost,127.0.0.1` instead of your real domain, fix it and
`sudo systemctl restart __APP_NAME__-gunicorn` — see §6.

**`__APP_NAME__-gunicorn.service` won't stay up / keeps restarting** —
`sudo journalctl -u __APP_NAME__-gunicorn -n 40 --no-pager` shows the
actual exception. Two specific ones seen in the wild:
- `Error: No application module specified` — the
  `__APP_NAME__.wsgi:application` argument got dropped off the end of
  `ExecStart` (usually a line-wrap or quoting mistake editing the unit
  file by hand). Compare against §8's version and re-`daemon-reload`
  after fixing it.
- `Control server error: [Errno 30] Read-only file system: '/nonexistent'`
  — already fixed by `Environment=HOME=/opt/__APP_NAME__` in
  `deploy/gunicorn.service` (the `__APP_NAME__` system user's real home is
  `/nonexistent` since it's created with `--no-create-home`); if you see
  this, your unit file predates that fix — copy the current
  `deploy/gunicorn.service` over again.

---

## Updating to a newer version

`/opt/__APP_NAME__` is a normal git clone (over the deploy key from §4),
but it's owned by `__APP_NAME__:__APP_NAME__` in day-to-day operation
(`chown -R __APP_NAME__:__APP_NAME__` in §8), not `ubuntu`. Reclaim
ownership to pull, then hand it back:

```bash
sudo chown -R ubuntu:ubuntu /opt/__APP_NAME__
cd /opt/__APP_NAME__
git pull

# Re-apply whichever of these the new commits actually need:
uv pip install --python .venv/bin/python -r requirements.txt
.venv/bin/python manage.py migrate
.venv/bin/python manage.py collectstatic --noinput

sudo chown -R __APP_NAME__:__APP_NAME__ /opt/__APP_NAME__
sudo systemctl restart __APP_NAME__-gunicorn
```

This is exactly what `.github/workflows/deploy.yml` + `deploy/deploy.sh`
automate — see `cicd.md` — once you've set up the self-hosted runner.

Two things `git pull` does **not** touch, because they were installed
*from* the repo rather than *as* the repo:

- **`.env`** — untracked, lives only on the server. Safe from `git pull`,
  but a future `.env.example` change (a new required setting) won't
  appear on its own — diff the two after pulling.
- **`/etc/nginx/sites-available/__APP_NAME__` and
  `/etc/systemd/system/__APP_NAME__-gunicorn.service`** — installed by
  `sudo cp`/`sudo tee` in §8–§9, not symlinked, so they're frozen at
  whatever was copied in at the time. A future change to
  `deploy/gunicorn.service` or `deploy/nginx.conf` doesn't take effect
  until you notice the diff and manually re-apply it (`daemon-reload` +
  restart, or `nginx -t` + reload).

**Never blindly re-`cp` `deploy/nginx.conf` over the live
`sites-available/__APP_NAME__` once certbot has run.** The repo's copy is
deliberately HTTP-only (§9) — your actual live file has since been
rewritten by certbot to add the HTTPS server block and the redirect.
Overwriting it with the repo's version silently removes HTTPS. If a
future update changes the app-serving parts of `nginx.conf` (the
`proxy_pass` block, the `/static/` alias, `client_max_body_size`), port
just that change into the live file by hand instead of replacing the
whole thing.

---

## Backups and data

### 13. Backups in production

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

Then set up the recurring cron job:

```bash
sudo -u __APP_NAME__ crontab -e
```

```
0 3 * * * /opt/__APP_NAME__/backup.sh >> /opt/__APP_NAME__/backup.log 2>&1
```

If pushing to S3, set `BACKUP_S3_BUCKET` in `.env` and attach an instance
role scoped to `s3:PutObject` only on that bucket/prefix (see the IAM
policy documented at the top of `deploy/backup.sh`) — never a long-lived
access key on the box. **Actually run the restore steps above against
this production instance at least once** (ideally into a scratch copy, not
over the live `db.sqlite3`, unless you're intentionally testing disaster
recovery) — an untested backup is not a backup.

---

### 14. Exit checklist

- [ ] App reachable only over HTTPS at `https://your.real.domain/`.
- [ ] Firewall/security group open only on 443 (and 22 from a known IP).
- [ ] `__APP_NAME__-gunicorn.service` enabled
      (`systemctl is-enabled __APP_NAME__-gunicorn`) and comes back after
      `sudo systemctl restart __APP_NAME__-gunicorn` / a reboot.
- [ ] `DEBUG=False`, real `SECRET_KEY`, real `ALLOWED_HOSTS` in the
      server's `.env` (never committed).
- [ ] `SECURE_SSL_REDIRECT` / `SESSION_COOKIE_SECURE` / `CSRF_COOKIE_SECURE`
      all `True` in practice (the DEBUG=False default — confirmed via
      §10, not just read from `.env`).
- [ ] Cron backup runs and produces a new encrypted file in
      `/opt/__APP_NAME__/backups/` (or uploads to S3).
- [ ] Restore tested at least once end-to-end (§13).
- [ ] No analytics/error-tracking script anywhere in the templates, if
      that matters for your app.
