# NET-Control on Synology (Container Manager)

The Synology edition runs the **control plane** (panel + API + Mongo + Redis) on
your NAS from **pre-built images** — nothing is compiled on the NAS. Agents still
run on your VPN servers and connect back to the panel.

It differs from the VPS install in three ways: one high TLS port instead of
80/443 (DSM owns those), you provide the TLS cert (no certbot, no auto self-signed), and
updates by pulling new images (no privileged auto-updater).

## Requirements

- DSM 7.2+ with **Container Manager** installed.
- A folder for the project, e.g. `/volume1/docker/netcontrol` (File Station).
- For remote agents: the ability to **port-forward** the panel port on your
  router to the NAS, and ideally a DDNS hostname (Synology offers free `*.synology.me`).

## 1. Put the files on the NAS

Into `/volume1/docker/netcontrol/` copy from the release bundle (or repo):

```
docker-compose.synology.yml
.env.synology.example        ->  rename to  .env
ops/                         (mongo/init.js, nginx/conf.d/synology.conf,
                               and synology/certs/ — put your cert here)
```

## 2. Fill in `.env`

Generate the secrets. Easiest over SSH on the NAS, from the project folder:

```bash
./scripts/generate-secrets.sh        # if you copied scripts/ too
# or set each by hand:  openssl rand -base64 32
```

Then edit `.env` and set at least:

- `PUBLIC_DOMAIN`, `PUBLIC_API_URL`, `ALLOWED_ORIGINS` — your DDNS host and the
  panel port, e.g. `https://nas.example.synology.me:8443`.
- `BOOTSTRAP_ADMIN_PASSWORD` — first-login password.
- `MASTER_KEY`, `JWT_*`, `COOKIE_SECRET`, `ENROLLMENT_SECRET`, `MONGO_PASS`,
  `REDIS_PASS` — strong random values (and rebuild `MONGO_URI` / `REDIS_URL` to
  match the passwords; `generate-secrets.sh` does this for you).
- `VPNCP_VERSION` — `stable`, or pin a tag like `v0.1.0`.

> **Back up `MASTER_KEY` offline.** If you lose it, stored VPN credentials cannot
> be decrypted.

## 2b. Provide the TLS certificate (required — no auto self-signed)

nginx serves a cert you supply. Put these two files into
`<project>/ops/synology/certs/` **before** starting (else nginx won't boot):

```
ops/synology/certs/fullchain.pem    # server cert + intermediate chain
ops/synology/certs/privkey.pem      # private key  (chmod 600)
```

Easiest source on Synology is DSM's Let's Encrypt — see "Provisioning the
certificate from DSM" below; it can also place these files for you. If your CA
hands you `cert.pem` + `chain.pem` separately: `cat cert.pem chain.pem > fullchain.pem`.

## 3. Create the project in Container Manager

Container Manager → **Project** → **Create** → point it at the project folder and
`docker-compose.synology.yml`. Build/Start. Place your cert first (next step); first start then just pulls the images and runs.

## 4. Open the panel

`https://<nas-host-or-ip>:8443`. With a real cert there is no warning; with a
self-signed one, accept it (or open by IP — see Troubleshooting). Log in with `BOOTSTRAP_ADMIN_USERNAME` and the
password you set, then change the password.

## 5. Make agents reach the panel

Agents on your VPN servers connect to `PUBLIC_API_URL` on the panel port.

- Forward `PANEL_PORT` (default **8443**) on your router → the NAS.
- If you kept the **self-signed** cert, enroll agents with `INSECURE_TLS=true`
  (the install command on the Servers page accepts it). For a trusted setup,
  drop a **real certificate** into the `nginx_certs` volume (see below) and
  enroll normally.

### Provisioning the certificate from DSM

A trusted cert removes the browser HSTS warning AND lets agents enroll without
`INSECURE_TLS=true`. On Synology the simplest source is DSM's own Let's Encrypt.

**1. Issue it in DSM.** Control Panel → Security → Certificate → Add → "Get a
certificate from Let's Encrypt" → domain = your panel host (e.g. `vpnc.example.com`),
+ email. DSM uses an HTTP-01 challenge, so the domain must resolve to the NAS and
**port 80 must be forwarded** to the NAS during issuance and renewals. (No public
port 80? Issue via DNS-01 elsewhere and drop `fullchain.pem`/`privkey.pem` into
the volume directly — same end result.)

**2. Copy it into the cert folder + reload nginx.** Use `ops/synology/sync-cert.sh`
(over SSH, as root). It finds the DSM cert for the domain, copies fullchain.pem +
privkey.pem into `ops/synology/certs/`, and restarts nginx:

```bash
sudo sh ops/synology/sync-cert.sh vpnc.example.com /volume2/web/vpnc
```

**3. Keep it fresh after renewals.** DSM auto-renews ~every 90 days into its own
archive — but that does NOT reach the container volume. Add a DSM **Task Scheduler**
job (Control Panel → Task Scheduler → Create → Scheduled Task, user **root**,
weekly) running the same command. It is idempotent; it only matters right after a
renewal.

After step 2, `https://<host>:8443` is trusted (no warning), and agents install
with the normal command from the Servers page (no `-k`, no `INSECURE_TLS`).

## Troubleshooting (gotchas seen on real installs)

- **`MongoServerError: Authentication failed` after changing `.env` / reinstalling.**
  Mongo fixes its password on the *first* start of an empty volume and never
  re-reads it. **Deleting a Container Manager project does NOT delete its named
  volumes.** On a clean reinstall, remove them explicitly:
  ```bash
  docker compose down -v        # from the project folder, OR:
  docker volume ls -q | grep -i <project> | xargs -r docker volume rm
  ```
  (Never use `-v` on a panel with real data.)

- **Browser: `NET::ERR_CERT_AUTHORITY_INVALID` + "HSTS, can't open".**
  Self-signed cert vs a host that previously sent HSTS. To get in before you
  install a real cert: open by **IP** (`https://<nas-ip>:8443`, HSTS is per-host),
  or clear HSTS at `chrome://net-internals/#hsts` (Delete domain security policies),
  or type `thisisunsafe` on the warning page. The real fix is the trusted cert above.

- **Agent install fails with curl `error 60` (SSL certificate problem).**
  The agent won't trust the panel's self-signed cert. Until you install a real
  cert, edit the install command: `curl -fsSL` → `curl -fsSLk`, and add
  `INSECURE_TLS=true` after `sudo`. Note this disables the agent's verification of
  the panel — fine on a LAN, weak for remote agents over the internet (use a real
  cert there).

## Updating

The Synology edition updates by pulling newer images — no rebuild on the NAS.

**Container Manager:** open the Project → **Action** → **Pull** the images, then
**Build/Recreate**. Bump `VPNCP_VERSION` in `.env` first if you pin versions.

**SSH (equivalent):**

```bash
cd /volume1/docker/netcontrol
docker compose -f docker-compose.synology.yml pull
docker compose -f docker-compose.synology.yml up -d
```

Your data (Mongo, Redis, CA, cert) lives in named volumes and survives updates.
The panel's **Обновления** page shows the current version and the exact pull
command for your install.

## Backups

Back up, at minimum: your `.env` (especially `MASTER_KEY`) and the `mongo_data`
volume. The repo's `scripts/backup.sh` works over SSH if you copied `scripts/`.

## Notes / limits

- One CDN decoy deployment per server still applies (unchanged from the VPS edition).
- The privileged in-panel auto-updater is intentionally omitted on Synology;
  updates are the pull + recreate above.
- If you change `PANEL_PORT`, also update `AGENT_PUBLIC_PORT` and `PUBLIC_API_URL`
  to the same port so agent enrollment URLs stay correct.
