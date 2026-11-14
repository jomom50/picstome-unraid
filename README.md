# Picstome in Docker and Unraid

A single-container build of [Picstome](https://github.com/picstome/picstome): client galleries, contracts, invoices, a portfolio page and a client CRM for photographers.

Everything runs inside one container:

| Service | Why it is there |
| --- | --- |
| nginx + PHP-FPM 8.4 | The Laravel application |
| Laravel queue worker | Photo processing and gallery ZIP archives |
| Laravel scheduler | Expiring galleries, reminders, cleanup, FTP ingest |
| MinIO (S3) | Picstome hardcodes the `s3` disk for photos, so an object store is mandatory |
| SQLite | Database, stored in appdata |

All persistent state lives under `/data`, which is the only path that has to survive a container replacement. Photos are the bulk of it and can be kept on their own disk with the optional **Photo Storage Path** mapping; the database, keys and logs always stay in appdata.

---

## Before you install

- **Two addresses clients can reach.** `APP_URL` (web UI) and `PICSTOME_PHOTOS_URL` (S3 endpoint) both appear in share links and in the `<img>` URLs of gallery pages, so any browser that opens a gallery must be able to resolve and reach them. A single `localhost` value is only enough for a test on the same machine.
- **Serve it at the root of a hostname.** `/` has to be the app, so use `picstome.example.com`, not `example.com/picstome`. Behind a reverse proxy that means one host per address (section 3).
- **Keep `/data` on local disk.** SQLite runs in WAL mode, which is unreliable on network shares; use a cache-pool or local path on Unraid. Photos are ordinary MinIO objects and can live on any disk you mount at `/data/minio`.
- **Admin Email is required on first start.** It creates the account, the studio and admin access, and its team is kept free of the hosted plan limits (see **Admin Unlimited**).
- **Mail is optional to begin with.** Leave SMTP empty and the admin account is still created, already verified; add SMTP later for gallery, contract and reminder email.
- **The container runs as root** (it binds port 80 and owns `/data`), so do not pass `--user`.
- **Linux containers only**, `amd64` and `arm64`.

---

## Quick start — any Docker host

Nothing here is tied to Unraid or to any particular directory. One named volume is enough:

```bash
docker run -d --name picstome \
  -p 8080:80 -p 9000:9000 \
  -v picstome-data:/data \
  -e APP_URL=http://192.168.1.50:8080 \
  -e PICSTOME_PHOTOS_URL=http://192.168.1.50:9000 \
  -e PICSTOME_ADMIN_EMAIL=you@example.com \
  -e PICSTOME_ADMIN_PASSWORD='change-me-now' \
  -e MAIL_MAILER=log \
  jomom50/picstome:latest
```

The same thing with Compose:

```yaml
services:
  picstome:
    image: jomom50/picstome:latest
    container_name: picstome
    restart: unless-stopped
    ports:
      - "8080:80"      # web UI
      - "9000:9000"    # S3 photo endpoint, fetched by browsers
    volumes:
      - picstome-data:/data
    environment:
      APP_URL: http://192.168.1.50:8080
      PICSTOME_PHOTOS_URL: http://192.168.1.50:9000
      PICSTOME_ADMIN_EMAIL: you@example.com
      PICSTOME_ADMIN_PASSWORD: change-me-now
      MAIL_MAILER: log

volumes:
  picstome-data:
```

Use a bind mount instead of the named volume if you prefer a visible directory: `-v /srv/picstome:/data`. To keep gallery photos on a separate disk, add a second mount at `/data/minio` (optional — without it, photos live inside `/data`).

Both URLs must be reachable **from the browsers that open galleries**, not just from the host: `PICSTOME_PHOTOS_URL` is where photos are served from, so put it on a hostname or address clients can reach. The first start creates the admin account and takes a few seconds — follow it with `docker logs -f picstome`.

---

## 1. Replace the placeholders

Three placeholders appear in the template files. Replace them before building:

```bash
sed -i 's/YOUR_DOCKERHUB_USER/your-dockerhub-name/g; s/YOUR_GITHUB_USER/your-github-name/g' \
    templates/picstome.xml ca_profile.xml
```

| Placeholder | Where it is used |
| --- | --- |
| `YOUR_DOCKERHUB_USER` | Image repository and registry link |
| `YOUR_GITHUB_USER` | Support link, `TemplateURL` and icon URL |

The GitHub URLs must point at the **public** repository that holds these files, because Unraid fetches the template and icon from raw.githubusercontent.com.

---

## 2. Build the image on the server

### Get the files onto the server

Copy this folder to the Unraid server, skipping `.freebuff` (editor metadata):

- Over SMB: `\\TOWER\Main\Apps\Picstome-Unraid`, or `\\<unraid-ip>\Main\Apps\Picstome-Unraid`
- Or push the repository to GitHub and `git clone` it on the server

The build only reads `Dockerfile`, `docker/` and `patches/`; everything else is the template and docs. On the server:

```bash
cd /mnt/user/Main/Apps/Picstome-Unraid && ls
```

You should see `Dockerfile`, `docker`, `patches`, `templates`.

### Build

On the Unraid terminal:

```bash
cd /mnt/user/Main/Apps/Picstome-Unraid

docker build \
  --build-arg PICSTOME_REF=e1baba36883894e2cd65d86a2d69799d3bff8b16 \
  -t your-dockerhub-name/picstome:latest .
```

The first build takes a while: it compiles the PHP extensions and installs ExifTool, ImageMagick and the MinIO binary. Expect a 1–1.5 GB image.

`PICSTOME_REF` pins the upstream commit. The Dockerfile pins the same value by default, so the build is reproducible until you deliberately bump it.

If the build stops with `no space left on device`, enlarge the Docker image under **Settings → Docker** (or switch Docker to directory mode). Builds also need outbound internet access for the base images, apt packages, Composer and npm.

### Check the result without starting it

```bash
docker images | grep picstome

docker run --rm --entrypoint bash your-dockerhub-name/picstome:latest -lc \
  'php -v | head -1; php -m | grep -Ex "gd|imagick|intl|pdo_sqlite|zip"; exiftool -ver; minio --version | head -1; nginx -v'
```

### Push it so Unraid can pull it

```bash
docker login
docker push your-dockerhub-name/picstome:latest
```

The image must be public — Community Applications and other servers pull it anonymously.

### Run it without pushing yet

Unraid only pulls the image when it is absent: `CreateDocker.php` checks for it first and skips the pull if it already exists on the server. A locally built tag is therefore enough to install from the template.

```bash
docker images | grep picstome
```

Put that exact name and tag in the template's `Repository` field — section 4 has the one-line edit for `picstome:latest`. If it was built under a different name, retag it instead of editing further:

```bash
docker tag picstome:latest your-dockerhub-name/picstome:latest
```

Until the image is pushed, **Update** and **Force Update** fail trying to pull it from Docker Hub; use **Apply** to recreate the container. Once it is published, switch `Repository` to `your-dockerhub-name/picstome:latest` and the update check starts working.

### Test it before wiring the reverse proxy

```bash
docker run -d --name picstome-test \
  -p 8282:80 -p 9000:9000 \
  -v /mnt/user/appdata/picstome-test:/data \
  -e APP_URL=http://192.168.1.10:8282 \
  -e PICSTOME_PHOTOS_URL=http://192.168.1.10:9000 \
  -e PICSTOME_ADMIN_EMAIL=you@example.com \
  -e PICSTOME_ADMIN_PASSWORD='change-me-now' \
  -e MAIL_MAILER=log \
  your-dockerhub-name/picstome:latest

docker logs -f picstome-test
```

Use the server's LAN address instead of `192.168.1.10`. When the log reaches `Starting services`, open `http://192.168.1.10:8282` and sign in. `MAIL_MAILER=log` means no SMTP is needed for this test. Remove the throwaway container afterwards with `docker rm -f picstome-test`.

---

## 3. DNS and reverse proxy

Picstome needs **two** publicly reachable addresses: the web UI and the photo/S3 endpoint. Photos are fetched straight from the object store, so the S3 address cannot be hidden behind the app.

### DNS

| Record | Value |
| --- | --- |
| `example.com` | your public IP |
| `photos.example.com` | your public IP |

### Nginx Proxy Manager

**Proxy host 1 — the application**

- Domain: `example.com`
- Scheme: `http`, Forward hostname: your Unraid IP, Forward port: `8282`
- Websockets support: on
- Block common exploits: on
- SSL: request a Let's Encrypt certificate, Force SSL, HTTP/2

**Proxy host 2 — photo storage**

- Domain: `photos.example.com`
- Scheme: `http`, Forward hostname: your Unraid IP, Forward port: `9000`
- Websockets support: not needed
- SSL: request a Let's Encrypt certificate, Force SSL

In the Advanced tab of the application host, confirm this line exists (NPM usually sets it to `0`, which is also fine):

```nginx
client_max_body_size 512m;
```

> **Why a separate hostname?** S3 presigned URLs are signed for the exact host in the URL. Serving the bucket under a path such as `/photos` on the main domain breaks the signature. A subdomain keeps everything working with normal HTTPS.

---

## 4. Install the container on Unraid

Copy these into `/boot/config/plugins/dockerMan/templates-user/my-Picstome.xml`, or install from your template repository once it is published:

```bash
cp templates/picstome.xml /boot/config/plugins/dockerMan/templates-user/my-Picstome.xml
```

The filename must start with `my-` and match the template's `<Name>`, otherwise Unraid ignores it. Over SMB the same folder is `\\TOWER\flash\config\plugins\dockerMan\templates-user`.

The template points at a Docker Hub repository, which stays a placeholder until you publish the image. To run the image you built locally, retarget the copy:

```bash
sed -i 's#<Repository>.*</Repository>#<Repository>picstome:latest</Repository>#' \
  /boot/config/plugins/dockerMan/templates-user/my-Picstome.xml
```

Then open **Docker → Add Container**, pick the Picstome template and set:

| Setting | Value for this server |
| --- | --- |
| WebUI Port | `8282` (8080 is already in use) |
| Photo Storage Port | `9000` |
| Appdata | `/mnt/user/appdata/picstome` |
| Photo Storage Path | optional, e.g. `/mnt/user/PicstomePhotos` (keeps galleries off appdata) |
| Public URL | `https://example.com` |
| Landing Page | leave empty, or `/@yourhandle/portfolio` once your portfolio is enabled |
| Photo Storage URL | `https://photos.example.com` |
| Admin Email | your email |
| Admin Password | a strong password |
| SMTP Host / Port / User / Password | your mail provider (optional at first) |
| From Address | e.g. `hello@example.com` |
| Timezone | e.g. `Europe/Madrid` |

Start the container and watch the log until you see:

```
[picstome] Created admin account you@example.com with studio @yourname.
[picstome] Starting services (web, php-fpm, queue worker, scheduler, object storage).
```

Then open `https://example.com` and sign in with the admin credentials.

---

## 5. Settings worth knowing

**Storage and contract limits.** Picstome's hosted free plan caps accounts at 1 GB and one contract/invoice per month, and shows the subscribe prompts. That plan is what the web registration form applies, so an account created there starts capped even on your own server. The container therefore keeps the **Admin Email** account on unlimited storage, contracts and invoices, and clears the plan flags on every start — which also promotes an admin account that was registered through the UI before. Turn that off with **Admin Unlimited** (`PICSTOME_ADMIN_UNLIMITED=false`). Accounts that register later still start at 1 GB — raise or clear their limit under **Users** in the admin area.

**Photo delivery.** `PICSTOME_PHOTO_CDN_DOMAIN` defaults to `bunny`, which serves images straight from your own storage. Nothing leaves your server, but the lightbox receives the processed 2048 px original. Setting it to `wsrv.nl` sends images through a third-party resizing CDN instead; that service has to reach your Photo Storage URL from the public internet, so with a LAN-only address every lightbox image comes back broken even though the grid works.

**Thumbnail size.** Grid thumbnails are generated as WebP at `PICSTOME_PHOTO_SMALL_THUMB_RESIZE` pixels (default 1000 in this image, 500 upstream). The processed original is `PICSTOME_PHOTO_RESIZE` (2048). Existing photos keep the size they were processed at, so after changing either value rebuild the thumbnails with `docker exec -it -u www-data -e HOME=/tmp Picstome php artisan photos:generate-thumbnails --force`.

**Public homepage.** The app's `/` redirects to the dashboard, so visitors land on the login screen — there is no setting in the UI for that. Picstome's public portfolio lives at `/@handle/portfolio` and is toggled on the **Portfolio** page in the app (it shows *Enable Public Portfolio* while disabled). The **Landing Page** field ships empty; set it to `/@yourhandle/portfolio` after enabling the portfolio. `patches/0002-landing-redirect.patch` makes the home route send guests there, while a signed-in visitor still gets the dashboard. Clear the field to go back to the login screen.

**Email.** Verification, gallery shares, contracts and reminders all send mail. Set `Mail Transport` to `log` while testing if SMTP is not ready yet.

**The bucket is readable by URL.** Picstome renders photos with plain object URLs, so MinIO has to allow anonymous reads. Object keys contain ULIDs and are only discoverable through share links, but treat gallery links as the access control they are.

**Where the photos live.** MinIO writes to whatever is mapped at `/data/minio`, defaulting to `/mnt/user/appdata/picstome/minio`. Point that at a dedicated share to keep galleries off the cache pool and out of appdata backups. The store keeps its own layout — each object is a directory holding `xl.meta` and part files — so the share is not a folder of browsable JPGs. Use Picstome's own download buttons to get images out.

**MinIO is pinned and unmaintained.** The community edition went source-only: `dl.min.io` returns 410 and the Docker Hub images were withdrawn, so the image pulls the last published binaries from GitHub (`MINIO_RELEASE`) and verifies their checksums. They work, but receive no security fixes, and the S3 endpoint is reachable by clients. Keep the photo hostname on HTTPS and update the pin if a maintained fork appears.

---

## 6. Backups and updates

**Backup:** stop the container, then copy `/mnt/user/appdata/picstome` **and** the Photo Storage Path. Appdata holds the SQLite database, the generated `APP_KEY` and the S3 credentials; the photo path holds the galleries themselves. Losing `APP_KEY` invalidates sessions and any encrypted values.

**Update:** bump `PICSTOME_REF` in the Dockerfile to the new upstream commit, rebuild, push, then use **Force Update** in the Unraid Docker tab. Migrations run automatically on start.

If upstream changes `bootstrap/app.php` or `routes/web.php`, the build stops at the patch step. That is intentional: re-read the change, regenerate the affected file in `patches/`, and rebuild.

---

## 7. Troubleshooting

**502 on the first health probe after a start**
nginx answers before php-fpm has created `/run/php-fpm.sock`, so the first `/up` request logs `connect() to unix:/run/php-fpm.sock failed` and returns 502. The next probe succeeds and the health check's 120-second start period ignores it. Only investigate if `/up` keeps returning 502, which means php-fpm died — `docker logs Picstome` shows why.

**Login button does nothing and the credentials appear in the address bar**
The form fell back to a native GET submit because Livewire's JavaScript never loaded. The site loads its JS from routes, not files: `/livewire-*/livewire.min.js` and `/tallstackui/script/*.js`. nginx must let a missing static path fall through to PHP — `try_files $uri /index.php?$query_string;` in the static-asset location — otherwise those routes answer 404 and no `wire:submit` handler is ever attached. Check the browser console to confirm the 404s. Those 404s get cached — by the browser and by any caching proxy in front — so after rebuilding an older image, purge that cache before the fix shows up. A quick test: `curl` the asset URL, then the same URL with `&cb=1` appended. If the first is 404 and the second 200, something in front is holding a negative response; the container itself is fine. Change that password afterwards: a GET submit writes it into the URL, browser history and the proxy's access log.

**502 Bad Gateway from the proxy (the page says openresty)**
The request reached Nginx Proxy Manager, but NPM could not connect to the container — Picstome itself is fine. In the proxy host, Forward Hostname / IP must be the NAS's LAN address. `127.0.0.1` or `localhost` points NPM at itself (unless NPM runs in host network mode), and the public domain name loops back through the proxy. Forward Port must be the published WebUI port, `8282`, not the container port `80`. Check what NPM actually generated:

```bash
docker exec NginxProxyManager cat /data/nginx/proxy_host/*.conf | grep -E "server_name|proxy_pass"
```

Use `docker ps --format '{{.Names}}' | grep -i proxy` to find the container name. Confirm the container answers from the server first: `curl -o /dev/null -w '%{http_code}\n' http://<nas-lan-ip>:8282/`.

**Blank page, redirect loop or http:// links on an https:// site**
`Public URL` must be the exact public URL including `https://`. The entrypoint derives the HTTPS flag from it.

**Gallery images broken, uploads fine**
The browser cannot reach the Photo Storage URL. Check that `photos.example.com` resolves, that NPM forwards to port 9000, and that the certificate is valid. Mixed content (an https page loading `http://…:9000`) is blocked by every browser.

**Uploads or downloads fail from inside the container**
Some routers do not support NAT loopback. Add the proxy's LAN address to the container's hosts file with an extra parameter:

```
--add-host photos.example.com:192.168.1.10
```

**Gallery images are broken or blurry**
A broken icon in the lightbox while the grid still shows pictures means the image URL points at a service that cannot reach your storage, usually `wsrv.nl`. Set **Photo CDN Mode** to `bunny` (the default) so the browser fetches images from your own Photo Storage URL. Soft or blurry grid thumbnails are the generated WebP being displayed larger than its pixel size: raise `PICSTOME_PHOTO_SMALL_THUMB_RESIZE` (default 1000) and run `photos:generate-thumbnails --force`, which also regenerates thumbnails made by an older image at 500 px.

**413 Request Entity Too Large**
Raise `Max Upload Size` in the template, and `client_max_body_size` in NPM.

**RAW files never get a preview**
RAW extraction depends on ExifTool, which is installed in the image. Check `docker exec Picstome which exiftool`.

**Queue or scheduler shows as stopped**
Open `/admin/queue` as an admin. Both processes run under supervisord; if either died, `docker logs Picstome` shows why.

**Uploads fail, or a photo stays pending forever**
Nine times out of ten the container cannot reach its own Photo Storage URL: that address carries the S3 writes as well as the links shown to browsers, so a hostname that does not resolve from inside the container (NAT loopback, split DNS, the proxy not running yet) makes every upload fail. Test it from inside the container:

```bash
docker exec Picstome sh -c 'curl -fsS --max-time 5 "$PICSTOME_PHOTOS_URL/minio/health/live" >/dev/null && echo reachable || echo NOT reachable'
```

The fingerprint of that failure is a photo row whose `path` is empty while its status stays `pending`, because the S3 disk is configured not to throw. The fix is the NAT loopback entry above, or pointing the Photo Storage URL at an address the container itself can resolve.

Also check:

- `docker exec Picstome supervisorctl status` — the queue worker must be RUNNING.
- `docker logs Picstome | grep -i error` and `/data/storage/logs/laravel.log`.
- A 413 means the file is bigger than **Max Upload Size**; raise it and `client_max_body_size` in the proxy.
- Panoramas wider than 16,384 px used to fail with `Unable to create new image`; this image raises the ImageMagick limits, so update the container.

---

## 8. Publishing to Community Applications

1. Push this repository to a **public** GitHub repo. `ca_profile.xml`, `LICENSE` and `templates/picstome.xml` must be at the root or in `templates/`.
2. Make sure the image is public on Docker Hub and pulls on a clean machine: `docker pull your-dockerhub-name/picstome:latest`.
3. Replace every placeholder (step 1) — submissions with placeholder icons or repository names are rejected.
4. Post a support thread in the Unraid forums, then add its URL to `<Support>` in the template and to `<Forum>` in `ca_profile.xml`.
5. Submit at <https://ca.unraid.net/submit/new>, run **Validate** and **Scan**, and fix whatever the scanner reports.
6. Tag a release (`v1.0.0`) so Community Apps can track updates through the versioned tags produced by the GitHub Actions workflow.

The repository is licensed AGPL-3.0, the same license as Picstome itself. The image contains the upstream source; this repository publishes the packaging files and the patch applied to it.

---

## Repository layout

```
Dockerfile                     multi-stage build, pinned upstream commit
patches/                       the two upstream changes (trusted proxies, landing redirect)
docker/entrypoint.sh           first-run setup, APP_KEY, migrations, admin
docker/first-run.php           creates the verified admin and studio
docker/supervisord.conf        nginx, php-fpm, queue, scheduler, MinIO
docker/nginx.conf.template     substituted with upload limit and HTTPS flag
docker/php-fpm-pool.conf       unix socket, env passthrough, long timeouts
docker/minio-init.sh           waits for MinIO, creates and shares the bucket
templates/picstome.xml         Unraid template with every setting exposed
ca_profile.xml                 Community Applications repository profile
.github/workflows/build.yml    multi-arch build and push to Docker Hub
```
