# PRSM osTicket production runbook

Coordination: [Slack workspace channel](https://app.slack.com/client/T0C63084TQE/C0C64Q3JKAN) (workspace access required). Outbound Slack notifications are disabled.

Canonical helpdesk: **https://prsmusa.com/ticket/**; staff: **https://prsmusa.com/ticket/scp/**. Web tickets only: SMTP, email fetching, autoresponders, and email alerts remain disabled.

## Hosts and persistent state

| Component | Location |
|---|---|
| Application checkout | `baser4wm@10.0.0.68:/home/baser4wm/github/osTicket` |
| Private deployment state | `/home/baser4wm/osticket` (`0700`) |
| Deployment environment | `/home/baser4wm/osticket/.env` (`0600`, outside Git/build context) |
| Installed configuration | `/home/baser4wm/osticket/ost-config.php`, root:root `0644`, read-only container bind |
| Production database | Compose project `osticket`, volume `osticket_osticket_db` |
| HTTP backend | `127.0.0.1:8081`, application under `/var/www/html/ticket` |
| VPS ingress | `r4wm@172.236.115.113`, existing TLS server, loopback tunnel `18003` |
| Restore ingress | Backend loopback `8082`, separate project and database volume |
| NAS export | `10.0.0.240:/mnt/storage/production-backups/baser4wm` |
| NAS client mount | `/mnt/production-backups`, exact filesystem type `nfs` (NFSv3) |
| Encrypted repository | `/mnt/production-backups/osticket/restic-repo` |
| Encryption password | `/home/baser4wm/osticket/restic-password` (`0600`) |
| Laptop recovery copy | `/home/rmintz/.local/share/prsm-osticket-recovery` (`0700`, credentials `0600`) |

Administrator: Raymond Mintz, username `raymondmintz`, email `raymondmintz11@gmail.com`. Helpdesk title: PRSM Support. Support address: `raymondmintz11+prsm-support@gmail.com`. Initial credentials are stored in the private `initial-credentials.json` file on baser4wm and in the laptop recovery directory; never paste credentials into logs, shell arguments, Git, or this document.

## Production artifacts and commands

Use [`Dockerfile.production`](../Dockerfile.production) and [`docker-compose.production.yml`](../docker-compose.production.yml), preserving the development files. The image excludes deployment files from its application tree. Apache denies dotfiles and operator paths even if a future image accidentally includes them. Apache `php_admin_flag` suppresses browser errors despite the application's `ini_set` calls; verify this through HTTP.

All operations resolve the same environment: explicit `OSTICKET_ENV_FILE`, then `~/osticket/.env`, then `/var/lib/osticket/.env`. These are trusted shell assignments as well as Compose dotenv settings: single-quote literal passwords and keep the file private. Locks and metrics default beside the selected environment file; explicit paths in that file take precedence.

```bash
cd /home/baser4wm/github/osTicket
scripts/compose-production.sh up -d
scripts/compose-production.sh ps
scripts/run-cron.sh
scripts/backup-osticket.sh
scripts/backup-osticket.sh check
```

Do not print expanded `docker compose config` or container environments into shared logs; they contain database credentials. Pin `OSTICKET_IMAGE_TAG` for rollback. Build and run the deployment tests before pushing a new image:

```bash
php setup/test/run-tests.php
scripts/tests/test-production.sh
docker build -f Dockerfile.production -t osticket-web:deployment-tests .
python3 -m unittest discover -s tests -p 'test_*deployment*.py'
```

The legacy project harness currently exits successfully but reports the missing optional `jsl` executable and existing PHP warnings. Record these limits; do not describe JavaScript lint as verified.

## Protected installation and launch

Install only after the dedicated tunnel and nginx route are healthy. Include **one** nginx variant in the existing HTTPS server:

1. [`nginx-prsmusa-osticket-install.conf.example`](../docker/nginx-prsmusa-osticket-install.conf.example): the whole application, including setup, requires temporary Basic authentication.
2. [`nginx-prsmusa-osticket-protected.conf.example`](../docker/nginx-prsmusa-osticket-protected.conf.example): after installation, setup returns `404`; the rest remains protected during acceptance.
3. [`nginx-prsmusa-osticket.conf.example`](../docker/nginx-prsmusa-osticket.conf.example): public launch, permanent setup `404`.

The live snippet is `/etc/nginx/snippets/prsmusa-osticket.conf`; the temporary password file is `/etc/nginx/secrets/osticket-install.htpasswd`, root:www-data `0640`. Run `nginx -t` before every reload and check sibling routes afterward. Preserve the existing TLS certificates and server block.

Install at `https://prsmusa.com/ticket/setup/` with the existing database credentials, host `db`, prefix `ost_`, and the administrator details above. The installer derives its URL from the request. Proxy the full URI with `Host`, `X-Forwarded-Proto`, `X-Real-IP`, and `X-Forwarded-For`; `proxy_pass` has no trailing slash.

After installation:

```bash
scripts/compose-production.sh exec -T -u root web chown root:root /var/www/html/ticket/include/ost-config.php
scripts/compose-production.sh exec -T -u root web chmod 0644 /var/www/html/ticket/include/ost-config.php
# Set OSTICKET_MODE=production and OSTICKET_CONFIG_READONLY=true in the private .env.
scripts/compose-production.sh up -d --no-deps --force-recreate web
```

A restart alone does not apply changed mounts. Production startup rejects an uninstalled, non-root-owned, or writable configuration. Keep the host state directory private. Both the PHP upload limit and osTicket attachment limit are 20 MiB; PHP POST and nginx request limits are 32 MiB.

Remove temporary authentication only after the acceptance and restore gates pass. Setup remains blocked. Preserve a tested protected nginx variant for maintenance.

## Tunnel and maintenance

Dedicated key: `~/.ssh/prsmusa_osticket_tunnel` on baser4wm. The VPS authorized key restricts `permitlisten="127.0.0.1:18003"`, forces `/bin/false` for command requests, and disables PTY, agent/X11 forwarding, and user rc. `permitopen="127.0.0.1:1"` limits local forwards to an unused loopback service; `permitopen="none"` is invalid in authorized_keys syntax and prevents authentication.

[`prsmusa-osticket-tunnel.example`](../docker/bin/prsmusa-osticket-tunnel.example) is installed as `~/bin/prsmusa-osticket-tunnel`, with reconnect loop, BatchMode, strict host-key checks, keepalives, and `ExitOnForwardFailure`. A dedicated `flock` wraps it at reboot and prevents duplicate loops. Do not replace sibling tunnel keys or cron entries.

The existing five-minute cron invokes `scripts/run-cron.sh`, with its own lock and an installed-config check. It runs as `www-data` in the web container. Staff autocron remains disabled for the web-only launch, but its endpoint can still run ticket maintenance and must be blocked during an upgrade freeze.

## NAS access and backup schedule

The RAID mount `/mnt/storage` must remain mounted before exporting. NFS service retains `RequiresMountsFor=/mnt/storage`; both exports use `mountpoint=/mnt/storage` to prevent writes into the NAS root filesystem when the array is absent.

- General LAN NFS: `all_squash,anonuid=1001,anongid=1001`, matching the existing r4wm SMB owner.
- Array top: root:root `1777`; existing r4wm-owned directories retain normal access, while the root-owned backup parent cannot be renamed by share users.
- `/mnt/storage/production-backups`: root:root `0755`.
- Dedicated subtree `baser4wm`: account `osticket-backup`, UID/GID **2201**, mode `0700`.
- Dedicated export: only `10.0.0.68`, `fsid=2201,all_squash,anonuid=2201,anongid=2201,subtree_check,mountpoint=/mnt/storage`.
- Existing guest SMB remains forced to r4wm and cannot traverse the protected subtree.

The client uses NFSv3 because this NAS applies the parent export's mapping to the nested export under NFSv4. Do not relax directory permissions to work around that mapping. The versioned system mount unit `docker/mnt-production\x2dbackups.mount` uses `vers=3,rw,nosuid,nodev,noexec,_netdev` and the exact dedicated source.

Existing nonsticky r4wm folders support other client UIDs through the general export mapping. Linux's `fs.protected_regular=2` and sticky-directory ownership checks require client UID1001 for top-level creation/truncation/rename of r4wm-owned objects; guest SMB already forces this owner. Keep this protection enabled. Verified general NFS writes inside existing folders, top-level writes as UID1001, and denial of protected backup access even using client UID2201.

Before any Restic operation, the backup script requires exact source, filesystem type, and mount target, and verifies the actual repository path belongs to that mount. A wrong mount, nested local mount, escaped symlink, or missing repository fails closed. One lock covers backup, retention, and integrity checks.

Every snapshot contains one stable `osticket-backup.tar`: an InnoDB-consistent SQL dump, installed config (including `SECRET_SALT`), image/git metadata, and checksums. Attachments use osTicket's database storage backend `D`, so the dump contains their data. Preparation happens privately; only a complete archive atomically replaces the previous archive. Failed preparation preserves the previous complete archive. There is no accumulating dated staging history.

Daily backup: **03:15 America/Indiana/Indianapolis**, with `restic forget --keep-within 7d --prune` after successful backup. Weekly full-data integrity check: Sunday **03:45**, `restic check --read-data`. The four [`osticket-backup*.service/timer`](../docker/osticket-backup.timer) files are linked into systemd on baser4wm; timers are persistent. Seven days is relative to the newest snapshot; the 26-hour alert catches a stopped schedule rather than silently trusting retention.

Backup metrics are atomically published to `/home/baser4wm/osticket/metrics/backup.prom` (`0644`, directory `0755`) and directly bound into the existing unprivileged node exporter. Dashboard panels show result, age, repository free bytes, and active alerts. Alerts fire on failed backup, missing/stale success over 26 hours, and failed integrity/retention maintenance. Delivery remains dashboard/logs; Alertmanager's discard receiver is unchanged. Rules include simulated failure, fresh/missing/stale, and exact 26-hour boundary tests.

## Verified isolated restore

Never reuse production paths or volumes. Start the restored database and import SQL **before** enabling the restored application. The restore Compose profile enforces database-only default startup; web/database stay on an internal network, and only the ingress has a second network to publish loopback `8082`.

On baser4wm, using a new private directory and a new project name:

```bash
set -a; . /home/baser4wm/osticket/.env; set +a
cd /home/baser4wm/github/osTicket
drill=$(mktemp -d /home/baser4wm/osticket/restore.XXXXXX)
restic restore latest --tag osticket --verify --target "$drill/snapshot"
archive="$drill/snapshot/home/baser4wm/osticket/backups/staging/osticket-backup.tar"
mkdir "$drill/payload"
tar -xf "$archive" -C "$drill/payload"
(cd "$drill/payload" && sha256sum -c SHA256SUMS)
cp /home/baser4wm/osticket/.env "$drill/restore.env"
chmod 600 "$drill/restore.env"
export OSTICKET_RESTORE_CONFIG_PATH="$drill/payload/ost-config.php"
export OSTICKET_IMAGE_TAG=$(sed -n 's/^image_tag=//p' "$drill/payload/metadata.txt")
project="osticket-restore-$(date +%s)"
restore_compose() {
  docker compose --env-file "$drill/restore.env" -p "$project" -f docker-compose.restore-test.yml "$@"
}
# Use the recorded, already tested application image; do not rebuild silently.
docker image inspect "osticket-web:$OSTICKET_IMAGE_TAG" >/dev/null
docker run --rm --network none --entrypoint sh -v "$drill:/recovery" \
  "osticket-web:$OSTICKET_IMAGE_TAG" -c \
  'chown root:root /recovery/payload/ost-config.php && chmod 0644 /recovery/payload/ost-config.php'
restore_compose up -d --wait db
restore_compose exec -T db sh -c \
  'export MYSQL_PWD="$MYSQL_PASSWORD"; exec mariadb --user="$MYSQL_USER" "$MYSQL_DATABASE"' \
  < "$drill/payload/osticket.sql"
restore_compose --profile restore up -d --no-build web ingress
```

Forward backend port8082 to the laptop if needed. Verify staff login and download the test attachment through `http://127.0.0.1:8082/ticket/`; compare its SHA256 with the original. Confirm internal-only web/DB networks and distinct config/database locations. When finished, remove only this test project and its named volume with `restore_compose --profile restore down -v`; retain the private verification record. Never run production `down -v`.

## Upgrade and rollback

1. Freeze **new writes first**: protect the edge route from public clients, suspend CLI cron scheduling, block `/ticket/scp/autocron.php` and `/ticket/api/tasks/cron`, and disable mail fetching. Keep a protected operator path for staff upgrade access.
2. Drain existing HTTP/cron work and wait for the cron lock. Stop the old web container after draining to prevent new background work.
3. Take and verify the checkpoint, recording snapshot ID, image tag, and config checksums. No new writes may enter during the rollback window.
4. Deploy the new pinned image and run the upgrader through protected operator access. Keep cron/autocron blocked until application and attachment checks pass.
5. On failure, stop the new application, import checkpoint SQL into the intended database, restore config, redeploy the old image, and verify before reopening. Database restoration loses post-checkpoint writes; the freeze prevents that loss.
6. On success, restore cron and public access. Email stays disabled unless separately configured and tested.

## Launch verification record

Completed **2026-10-02**. Public helpdesk returns `200`; staff redirects to login; setup returns `404`; config, dotfiles, and operator files return `403/404`. The running production image is `osticket-web:b6e9b96e`. Verified snapshot **`0a705310`** restored into a new database volume with SQL imported before starting web/ingress. Fresh staff login and the restored 20 MiB attachment SHA256 matched the original. The restore project and only its test database volume were removed; production data was preserved.

The following gates passed on the live hosts:

- HTTPS helpdesk/staff URLs and client ticket submission with a genuine 20 MiB upload/download.
- Setup, dotfiles, config, Compose/Dockerfiles, and operator directories denied.
- HTTP warning probe: error absent from response and present in container logs; remove probe afterward.
- Config root:root `0644`, read-only bind, denied writes, container restart.
- Dedicated tunnel drop/recovery, loopback-only listener, restricted alternate forwards.
- Five-minute maintenance cron executes without an interactive staff session.
- Backup, full integrity check, timers, metrics scrape, stale/failure rules, and clean isolated restore with attachment checksum.
- Existing nginx sibling routes and NAS SMB shares still work.

Failure and stale alerts reached **firing**, then returned to healthy state after restoring real metrics and taking a successful backup. Actual Restic retention was exercised over ten simulated days, including the inclusive seven-day boundary, and full-data integrity checks passed. Stopping the client NFS mount caused backup failure without replacing the complete archive or writing a fallback repository. The existing Haul tunnel was found stopped and its configured wrapper restarted; `/`, Bible, Auto Specs, PrivateBin, Metrics, and Haul routes responded normally after launch.

Infrastructure inventory and the versioned edge route live in [R4wm/infra-docs](https://github.com/R4wm/infra-docs). Keep that nginx configuration synchronized so future infrastructure bootstrap does not erase the route.
