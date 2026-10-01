# AGENTS.md

Guidance for coding agents in this repository.

## Purpose

This repository builds the PHP images of the Maho Cloud servers and publishes them to
`ghcr.io/mahocommerce/mahocloud-php`. The control plane (`MahoCommerce/cloud.mahocommerce.com`)
writes `FROM ghcr.io/mahocommerce/mahocloud-php:<php>-<engine>` into the default Dockerfile of
each website (`MahoDefaultConfig::dockerfile()`). A website's deploy runs
`docker compose build --pull`, so every deploy gets the newest build of its tag. The build used to
compile the PHP extensions on the customer's server, which is a 2-vCPU machine that also serves
the shop. That compile now runs here, once.

The image holds no application code and no secret. The checkout is bind-mounted at `/app` on the
server, and the secrets reach the container at run time. The image is public.

## Files

- `Dockerfile`: one stage `common` and three final stages `mysql`, `pgsql`, `sqlite`
- `versions.json`: the PHP versions and the last day each is rebuilt (`eol`)
- `tests/image.sh <image> <engine>`: the checks that every image must pass before its tag moves
- `.github/workflows/build.yml`: the only build workflow

## Tags and stages

- One tag per PHP version and engine: `8.4-mysql`, `8.4-pgsql`, `8.4-sqlite`. MariaDB websites
  use the `mysql` tag (the same PHP driver and the same Debian client package).
- The engine part (driver and client) is the last layer. The three images share every other layer,
  so CI compiles the shared extensions once per PHP version and architecture, and the registry
  stores them once. Do not move an engine-specific package into `common`, and do not move a shared
  package into an engine stage.
- One engine per image is a product decision: it keeps each image smaller. `tests/image.sh` fails
  when an image carries a driver of another engine.
- The control plane maps an engine to a tag in `MahoDefaultConfig::phpImage()`. A new PHP version
  needs its tags here before the control plane offers it (`Website::PHP_VERSIONS`).

## Rules that must not be broken

- **The SSH host keys are deleted.** The postinst of `openssh-server` writes private host keys into
  `/etc/ssh`. This image is public and runs on every server, so the keys would be the same
  everywhere and known to everybody. The sftp service generates its own keys on a volume when it
  starts. `tests/image.sh` fails when a key is present.
- **`redis` is installed in every image**, whatever the Redis toggle of a website says. A deploy
  that turns Redis off must not build an image without the extension while `local.xml` still names
  Redis. The control plane also treats a custom Dockerfile `FROM` this image as one with the
  extension (`MahoDefaultConfig::usesPhpImage()`).
- **The base stays Debian 13 (trixie).** The Chromium package names are Debian 13's (`t64`).
- **No layer cache in the workflow.** `apt-get upgrade` exists to bring Debian security updates,
  and a cache would keep the old layer. The builder is new in every job and exports no cache. The
  three engine builds of one job share that builder, which is how they share the `common` stage.
- **A tag moves only after both platforms built and passed the test.** The merge job refuses a set
  with fewer than two digests for an engine, so a failure leaves the tag on the last good image.
- **The base is pinned by digest at build time.** The plan job resolves
  `dunglas/frankenphp:1-php<v>-trixie` to a digest and passes `BASE_IMAGE=<tag>@<digest>`. The merge
  job writes the digest onto the index as the annotation `org.opencontainers.image.base.digest`.
  The 4-hourly run reads it back to decide whether the base changed. Keep the two in step.
- The Node, Chromium and Mesa stub recipe is the same as in `MahoCommerce/docker-images`
  (`Dockerfile`, section "Node and Chromium" of its AGENTS.md). When that recipe changes its
  packages, change this one the same way.

## Workflow

- **Schedules.** `17 */4 * * *` builds a PHP version only when its base digest differs from the
  annotation on any of its three tags (or a tag does not exist). `45 2 * * *` builds every version,
  for the Debian updates, Node and Composer. The plan job tells the two apart by
  `github.event.schedule`, compared with `FULL_CRON`. Change both strings together.
- **Push to `main`** that touches the Dockerfile, `versions.json`, the tests or the workflow builds
  everything. **Manual run**: everything, or one PHP version (`php` input), which also bypasses the
  EOL filter for a critical fix.
- **EOL.** A version past its `eol` date is not rebuilt. Its tags stay. `eol` is the end of PHP
  security support (Debian 13 LTS runs until 2030-06-30, later than every PHP version here).
- **Native runners.** amd64 on `ubuntu-latest`, arm64 on `ubuntu-24.04-arm`. Hetzner CAX servers are
  arm64; Contabo, Proxmox and external servers are mostly amd64. QEMU would compile the extensions
  under emulation and take many times longer.
- **Login.** The `GITHUB_TOKEN` with `packages: write`, through an inline `docker login` loop with
  three tries. `docker/login-action` cannot retry, and one failed login fails a platform, which
  fails the merge of that version.
- **Actions are pinned by commit SHA**, with the version in a comment. Dependabot updates them.

## Keepalive

GitHub disables the schedules of a public repository after 60 days without activity, and it does
not say so. The images would then stop getting security updates while every deploy still works,
so nobody would notice. The `keepalive` job runs on every scheduled run and calls the
`enable` endpoint of the workflow, which resets the 60-day counter. It needs `actions: write`.
Do not remove it, and do not make it conditional.

## Local work

```bash
docker build --build-arg PHP_VERSION=8.4 --target mysql -t mahocloud-php:8.4-mysql .
./tests/image.sh mahocloud-php:8.4-mysql mysql
actionlint .github/workflows/build.yml
shellcheck tests/image.sh
```

In `tests/image.sh`, read a command's output into a variable before grep reads it. A pipe into
`grep -q` fails at random under `pipefail`: grep exits at the first match, the writer dies of
SIGPIPE, and the pipeline reports 141.
