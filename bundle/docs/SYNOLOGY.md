# NET-Control on Synology (Container Manager)

The Synology edition runs the **control plane** (panel + API + Mongo + Redis) on
your NAS from **pre-built images** — nothing is compiled on the NAS. Agents still
run on your VPN servers and connect back to the panel.

It differs from the VPS install in three ways: one high TLS port instead of
80/443 (DSM owns those), a self-signed cert on first boot (no certbot), and
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
ops/                         (mongo/init.js and nginx/conf.d/synology.conf)
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

## 3. Create the project in Container Manager

Container Manager → **Project** → **Create** → point it at the project folder and
`docker-compose.synology.yml`. Build/Start. First start pulls the images and
generates a self-signed cert.

## 4. Open the panel

`https://<nas-host-or-ip>:8443` — the browser will warn about the self-signed
cert the first time; accept it. Log in with `BOOTSTRAP_ADMIN_USERNAME` and the
password you set, then change the password.

## 5. Make agents reach the panel

Agents on your VPN servers connect to `PUBLIC_API_URL` on the panel port.

- Forward `PANEL_PORT` (default **8443**) on your router → the NAS.
- If you kept the **self-signed** cert, enroll agents with `INSECURE_TLS=true`
  (the install command on the Servers page accepts it). For a trusted setup,
  drop a **real certificate** into the `nginx_certs` volume (see below) and
  enroll normally.

### Using a real certificate (recommended for production)

Replace the self-signed pair with your own (e.g. a cert issued for your DDNS
host, exportable from DSM's Security → Certificate):

```bash
# from the project folder, over SSH:
docker run --rm -v netcontrol_nginx_certs:/c -v "$PWD/mycert":/in alpine \
  sh -c "cp /in/fullchain.pem /c/fullchain.pem && cp /in/privkey.pem /c/privkey.pem"
docker compose -f docker-compose.synology.yml restart nginx
```

(The volume name is `<project>_nginx_certs`; check `docker volume ls`.)

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
