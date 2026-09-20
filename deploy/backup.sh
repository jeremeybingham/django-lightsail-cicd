#!/usr/bin/env bash
# Cron-driven SQLite backup for __APP_NAME__.
#
# Takes a consistent online backup of the live db.sqlite3 (via sqlite3's
# .backup, which is safe to run against a database Gunicorn is actively
# writing to), gzips and GPG-encrypts it, keeps a short local retention
# window, and — if configured — pushes the encrypted file to S3.
#
# Install: sudo cp deploy/backup.sh /opt/__APP_NAME__/backup.sh && sudo chmod 750 /opt/__APP_NAME__/backup.sh
# Cron (as the `__APP_NAME__` user — sudo crontab -u __APP_NAME__ -e):
#   0 3 * * * /opt/__APP_NAME__/backup.sh >> /opt/__APP_NAME__/backup.log 2>&1
#
# Required environment (set in /opt/__APP_NAME__/.env, which this script
# sources — EnvironmentFile-style KEY=VALUE, no `export`, no quotes needed):
#   BACKUP_GPG_RECIPIENT   GPG key ID/email to encrypt backups to. Generate
#                          and safely store the matching private key OFF
#                          this server — it's the only way to decrypt.
# Optional:
#   BACKUP_S3_BUCKET       If set, encrypted backups are pushed here via
#                          `aws s3 cp` after being written locally.
#   BACKUP_LOCAL_DIR       Default: /opt/__APP_NAME__/backups
#   BACKUP_RETENTION_DAYS  Local copies older than this are deleted after
#                          a successful upload (or always, if no bucket is
#                          configured). Default: 7.
#
# IAM policy scope (attach to the instance role, not a long-lived access
# key) — write-only from the instance, no read/list/delete, so a
# compromised instance can't enumerate or exfiltrate prior backups:
#   {
#     "Version": "2012-10-17",
#     "Statement": [{
#       "Effect": "Allow",
#       "Action": "s3:PutObject",
#       "Resource": "arn:aws:s3:::YOUR-BACKUP-BUCKET/__APP_NAME__/*"
#     }]
#   }
# On the bucket itself: enable default (SSE-S3 or SSE-KMS) encryption,
# versioning, and a bucket policy that denies non-instance-role principals
# read/list; block all public access. Restoring/pruning old objects should
# be done from a separate, more privileged principal — never from this
# instance's role.
set -euo pipefail

APP_DIR="/opt/__APP_NAME__"
DB_PATH="$APP_DIR/db.sqlite3"
BACKUP_LOCAL_DIR="${BACKUP_LOCAL_DIR:-$APP_DIR/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"

if [[ -z "${BACKUP_GPG_RECIPIENT:-}" ]]; then
    echo "backup.sh: BACKUP_GPG_RECIPIENT is not set, refusing to write an unencrypted backup" >&2
    exit 1
fi

mkdir -p "$BACKUP_LOCAL_DIR"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
raw_copy="$(mktemp)"
gz_path="$BACKUP_LOCAL_DIR/__APP_NAME__-${timestamp}.sqlite3.gz"
enc_path="${gz_path}.gpg"

cleanup() { rm -f "$raw_copy"; }
trap cleanup EXIT

# Online, consistent backup — safe to run while Gunicorn holds the DB open.
sqlite3 "$DB_PATH" ".backup '$raw_copy'"
gzip -c "$raw_copy" > "$gz_path"

gpg --batch --yes --trust-model always \
    --recipient "$BACKUP_GPG_RECIPIENT" \
    --output "$enc_path" \
    --encrypt "$gz_path"
rm -f "$gz_path"
chmod 600 "$enc_path"

echo "backup.sh: wrote $enc_path"

if [[ -n "${BACKUP_S3_BUCKET:-}" ]]; then
    aws s3 cp "$enc_path" "s3://${BACKUP_S3_BUCKET}/__APP_NAME__/$(basename "$enc_path")" \
        --sse aws:kms
    echo "backup.sh: uploaded to s3://${BACKUP_S3_BUCKET}/__APP_NAME__/"
fi

find "$BACKUP_LOCAL_DIR" -name '__APP_NAME__-*.sqlite3.gz.gpg' -mtime "+${BACKUP_RETENTION_DAYS}" -delete

echo "backup.sh: done"
