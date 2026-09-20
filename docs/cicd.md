# CI/CD: auto-deploy `__APP_NAME__` to Lightsail on merge to `main`

Companion to `deployment_lightsail.md` (manual production setup, assumed
already done once) and its "Updating to a newer version" section, which
this automates.

## Goal

When a PR merges into `main`:
1. Run the test suite (`python manage.py test`) as a gate.
2. If it passes, pull the new code onto the Lightsail instance, apply
   migrations/static/deps, and restart Gunicorn — the same steps a human
   used to run by hand.
3. Accept brief downtime during the restart (single Gunicorn process
   group restarting, a few seconds) — fine for a low-traffic app on a
   single instance; if your app can't tolerate that, this pipeline isn't
   the right starting point without adding blue-green/zero-downtime
   machinery.

## How CI reaches the server

A small self-hosted GitHub Actions runner runs on the Lightsail box
itself, as a systemd service. It polls GitHub over outbound HTTPS for
jobs — nothing connects in, so the inbound firewall stays exactly as
`deployment_lightsail.md` §2 left it (443 + 22 from a known IP only), and
no SSH key or other new credential has to be stored in GitHub. The
tradeoff is one extra systemd service on the instance to keep updated,
which is small and one-time.

## Design

```
PR merged to main
        │
        ▼
GitHub Actions workflow: .github/workflows/deploy.yml
        │
        ├─ job: test   (GitHub-hosted runner, ubuntu-latest)
        │     checkout → pip install -r requirements.txt
        │     → python manage.py test   (dummy SECRET_KEY, sqlite, no real .env)
        │
        └─ job: deploy (needs: test)   (self-hosted runner, ON the Lightsail box)
              runs /opt/__APP_NAME__/deploy/deploy.sh
                     │
                     ├─ reclaim ownership (ubuntu:ubuntu)
                     ├─ git fetch/pull origin main (fast-forward only)
                     ├─ warn if deploy/nginx.conf or deploy/gunicorn.service
                     │   changed (these are never auto-applied — see below)
                     ├─ uv pip install -r requirements.txt
                     ├─ manage.py migrate
                     ├─ manage.py collectstatic --noinput
                     ├─ hand ownership back (__APP_NAME__:__APP_NAME__)
                     ├─ sudo systemctl restart __APP_NAME__-gunicorn
                     └─ health check: curl the unix socket, confirm it's up
```

Two things this pipeline **deliberately does not touch**, matching the
existing warning in `deployment_lightsail.md` §"Updating to a newer
version":

- **`.env`** — stays server-only, never written by CI. A new required
  setting (e.g. a future `.env.example` addition) still needs a human to
  notice and add it.
- **`deploy/nginx.conf` / `deploy/gunicorn.service`** — the live copies
  under `/etc/nginx/...` and `/etc/systemd/system/...` were installed by
  `cp`, not symlinked, and the live nginx config has since been rewritten
  by certbot. Auto-overwriting either on every deploy would silently
  break HTTPS or the socket permissions fix documented in §9. Instead,
  `deploy.sh` diffs the repo's copy against what's installed and **fails
  the deploy with a loud warning** if they differ, so a human applies the
  change deliberately (same manual step as today) instead of it drifting
  unnoticed or breaking silently.

## Deploy instructions

`deploy/deploy.sh` and `.github/workflows/deploy.yml` are already in this
repo. What's left is one-time setup on the Lightsail box itself.

### 1. Register a self-hosted runner on the Lightsail instance

GitHub repo → **Settings → Actions → Runners → New self-hosted runner**
→ Linux, x64. Follow the generated `./config.sh` command on the box (it
includes a short-lived registration token — don't reuse across runs).

```bash
sudo mkdir -p /opt/gh-runner && cd /opt/gh-runner
sudo chown ubuntu:ubuntu /opt/gh-runner
# paste the download + tar -xzf steps GitHub's UI gives you, then:
./config.sh --url https://github.com/<owner>/<repo> \
            --token <token-from-github-ui> \
            --labels __APP_NAME__-lightsail \
            --name __APP_NAME__-lightsail-runner \
            --unattended
sudo ./svc.sh install ubuntu
sudo ./svc.sh start
sudo ./svc.sh status
```

Runs as the `ubuntu` account (same sudo-capable user that already does
manual deploys per `deployment_lightsail.md` §"Updating to a newer
version") — no new system user needed. It needs no inbound port; confirm
with `sudo ufw status` that nothing changed.

**Repo-scoping matters**: because this runner executes on real
production infrastructure, only ever register it against *this* repo
(not org-wide), and never let it pick up workflows triggered by
`pull_request` from forks — a malicious PR could otherwise run arbitrary
code on the box. The workflow only triggers on `push` to `main`,
which requires write access to the repo already, so this is naturally
satisfied — just don't widen the trigger later without re-checking this.

**Group membership for the socket health check**: `deploy.sh`'s last step
connects to `/run/__APP_NAME__/gunicorn.sock` to confirm the app actually
answers after a restart. That socket is only reachable by members of the
`__APP_NAME__` group — the same reason `deployment_lightsail.md` §9
already adds `www-data` to it for nginx. Give the runner's user the same
access:

```bash
sudo usermod -aG __APP_NAME__ ubuntu
sudo ./svc.sh stop && sudo ./svc.sh start   # re-exec so the new group takes effect
```

A running process's group membership is fixed at start, so the runner
service has to be restarted (not just the group changed) before its own
`deploy.sh` invocation can see it — a plain `usermod` alone silently
doesn't take effect until then.

### 2. Scope exactly the sudo access the deploy needs

The manual update flow already requires `sudo` for two things: flipping
`/opt/__APP_NAME__` ownership between `ubuntu` and `__APP_NAME__`, and
restarting the service. Grant the runner's user (`ubuntu`) passwordless
sudo for *exactly* those commands — nothing broader:

```bash
sudo visudo -f /etc/sudoers.d/__APP_NAME__-deploy
```
```
ubuntu ALL=(root) NOPASSWD: /bin/chown -R ubuntu\:ubuntu /opt/__APP_NAME__
ubuntu ALL=(root) NOPASSWD: /bin/chown -R __APP_NAME__\:__APP_NAME__ /opt/__APP_NAME__
ubuntu ALL=(root) NOPASSWD: /bin/systemctl restart __APP_NAME__-gunicorn
ubuntu ALL=(root) NOPASSWD: /bin/systemctl is-active __APP_NAME__-gunicorn
```

No wildcard commands, no shell access as root — if the runner or a
workflow file were ever compromised, this is the ceiling of what it could
do as root.

### 3. `deploy/deploy.sh` (already in this repo)

Codifies the manual update steps from `deployment_lightsail.md`. Runs on
the Lightsail box, invoked by the self-hosted runner. Confirm it's on the
box once the deploy key clone (`deployment_lightsail.md` §4) is in
place — it ships as part of `/opt/__APP_NAME__`, executable:

```bash
ls -l /opt/__APP_NAME__/deploy/deploy.sh   # -rwxr-xr-x
```

### 4. `.github/workflows/deploy.yml` (already in this repo)

- `test` runs on every push to `main` and every PR, on a GitHub-hosted
  runner — it doesn't need production access and shouldn't consume the
  box's CPU.
- `deploy` only runs after `test` passes on a direct push to `main`; the
  `if:` guard keeps it from ever triggering on a PR (including from a
  fork), so the self-hosted runner never executes untrusted code.
- The `deploy` job deliberately does **not** `actions/checkout` — the
  Lightsail box already has its own clone (via the read-only deploy key
  from `deployment_lightsail.md` §4); `deploy.sh` does its own `git pull`
  from that existing checkout. This avoids putting a second copy of the
  repo, or any new credential, on the runner.
- The dummy `SECRET_KEY`/`DEBUG`/`ALLOWED_HOSTS` in the `test` job are
  test-only values with no bearing on production secrets; nothing
  sensitive is in the workflow file.

Turn on branch protection once, in **Settings → Branches → Branch
protection rule** for `main`: require the `test` status check to pass
before merging.

### 5. Verify end to end

1. Push a trivial change on a branch, open a PR, confirm the `test` job
   runs and passes on the GitHub-hosted runner, and the `deploy` job
   does **not** run.
2. Merge to `main`, watch the `deploy` job in the Actions tab — it
   should show up running on the self-hosted runner and stream
   `deploy.sh`'s output live.
3. Confirm on the box:
   ```bash
   sudo systemctl status __APP_NAME__-gunicorn      # recent restart
   git -C /opt/__APP_NAME__ log -1                  # shows the new commit
   ls -l /opt/__APP_NAME__                          # __APP_NAME__:__APP_NAME__ ownership restored
   ```
4. Hit the live site, confirm it still loads and works (same checks as
   `deployment_lightsail.md` §10).
5. Deliberately break a test on a branch, merge is blocked by branch
   protection, and confirm the `deploy` job never runs.

## Rollback

No automatic rollback — not worth the complexity at this scale (a small
number of known users, tolerant of brief downtime, and `deploy.sh`'s
health check already fails the run loudly instead of leaving a
half-updated app silently broken). If a bad deploy does land:

```bash
# on the box
sudo chown -R ubuntu:ubuntu /opt/__APP_NAME__
cd /opt/__APP_NAME__
git log --oneline -5          # find the last-good commit
git checkout <good-sha>       # or: git revert <bad-sha> on main and re-push, letting CI redeploy
sudo chown -R __APP_NAME__:__APP_NAME__ /opt/__APP_NAME__
sudo systemctl restart __APP_NAME__-gunicorn
```

Reverting on `main` and letting the pipeline redeploy is preferable to
hand-editing the box when possible, so `git log` on the server and
GitHub agree.

## What this does *not* change

- `deployment_lightsail.md` remains the source of truth for first-time
  provisioning (firewall, TLS, backups, the initial manual deploy) — this
  only automates its "Updating to a newer version" section.
- No new inbound firewall rule, no widened `ALLOWED_HOSTS`/CSRF origins,
  no new long-lived credential in GitHub.
- `.env`, backups (`deploy/backup.sh` + cron), and the nginx/systemd unit
  files stay exactly as manually managed today.

## Setup checklist

- [ ] Self-hosted runner registered, shows **Idle** in Settings → Actions
      → Runners, and survives a reboot (`sudo ./svc.sh status`).
- [ ] Runner's user (`ubuntu`) added to the `__APP_NAME__` group and the
      runner service restarted afterward, so `deploy.sh`'s socket health
      check can actually connect.
- [ ] `/etc/sudoers.d/__APP_NAME__-deploy` contains only the four scoped
      lines above (`sudo visudo -c` to validate syntax).
- [ ] Branch protection on `main` requires the `test` check.
- [ ] One real merge to `main` observed end-to-end: workflow green,
      `__APP_NAME__-gunicorn` restarted, site verified live.
- [ ] One deliberate failure (broken test) observed to confirm `deploy`
      is correctly gated and never runs.
- [ ] `ufw status` / Lightsail firewall confirmed unchanged (no new open
      ports) after all of the above.
