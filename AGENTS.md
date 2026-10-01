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
- **The build cache is what keeps deploys from downloading the image again.** See **Build cache**.
  Do not remove `--cache-from`/`--cache-to` or the `REFRESH` argument.
- **A tag moves only after both platforms built and passed the test.** The merge job refuses a set
  with fewer than two digests for an engine, so a failure leaves the tag on the last good image.
- **The base is pinned by digest at build time.** The plan job resolves
  `dunglas/frankenphp:1-php<v>-trixie` to a digest and passes `BASE_IMAGE=<tag>@<digest>`. The merge
  job writes the digest onto the index as the annotation `org.opencontainers.image.base.digest`,
  for inspection. Nothing reads it back.
- The Node, Chromium and Mesa stub recipe is the same as in `MahoCommerce/docker-images`
  (`Dockerfile`, section "Node and Chromium" of its AGENTS.md). When that recipe changes its
  packages, change this one the same way.

## Workflow

- **Schedule.** `17 */4 * * *` builds every version that is not past its `eol`. Without a new input,
  every build is a cache hit with the same digest, so the tags do not move (see **Build cache**).
  There used to be a second, daily schedule and a base-digest check for the 4-hourly one. Both
  existed only because a build without a cache was expensive and changed every layer
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

## Build cache

A rebuild without a cache writes different layers for the same content: file times, apt logs and
dates inside files change with every build. A test showed it: a fresh build of the same recipe from
the same base had four different layer digests out of four. Every server would then download about
175 MB again on its next deploy, every day, for nothing.

So every build reads its cache from the published tag (`--cache-from type=registry`) and writes its
cache into the image (`--cache-to type=inline`). A cache hit reuses the published layer byte for
byte. Two more settings make the whole image digest the same, so a run with no new input moves no
tag and adds no package version:

- `SOURCE_DATE_EPOCH` is the time of the commit (computed in the plan job). BuildKit writes it as the
  creation time of the image, which would otherwise be the build time. A test with two fresh
  builders and the same cache gave the same image digest twice
- `--provenance=false`. The provenance attestation holds the build times and an invocation id, so
  it would change the digest of every build. It also put an `unknown/unknown` manifest into each
  index

- `ARG REFRESH` is at the top of the `common` stage. A declared ARG is part of the cache key of
  every `RUN` after it, so a new value builds the extensions and the tools layer again. The workflow
  passes the ISO week (`2026-W40`), computed once in the plan job. **Debian updates of the packages
  that this image adds therefore arrive within a week.** The base image's own updates arrive within
  4 hours, through the base digest. A faster `REFRESH` (the date) makes every server download the
  image again every day
- Inputs that invalidate layers, as they must: the base digest, the digest of `node:24-trixie-slim`
  (it changes with Node releases and with Debian updates of that image), the `composer:latest`
  digest, the Dockerfile, and `REFRESH`
- The inline cache carries only the layers of the final image (mode `min`). That is enough here: the
  `node` stage is a pulled image, not a built one, and `common` is part of every final image
- The three engine builds of one job share the job's builder, which is how they share `common`
  within one run. The cache from the registry is what carries it from one run to the next

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
