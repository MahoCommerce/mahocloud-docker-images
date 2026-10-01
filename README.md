# Maho Cloud PHP images

The PHP images of the Maho Cloud servers, published at
`ghcr.io/mahocommerce/mahocloud-php`.

Each image contains:

- FrankenPHP 1 on Debian 13 (trixie).
- The PHP extensions that Maho needs, including `redis`, `ffi` and `vips`.
- One database driver and its command-line client.
- Node and the Chromium libraries for the accessibility scanner of Maho 26.9+.
- Composer, git, nano, vim-tiny, rsync and openssh-server.
- The user `maho` (uid and gid 1000).

An image holds no application code. Maho Cloud mounts the checkout at `/app`.

## Tags

One tag for each PHP version and database engine:

| PHP | MySQL and MariaDB | PostgreSQL  | SQLite       |
|-----|-------------------|-------------|--------------|
| 8.2 | `8.2-mysql`       | `8.2-pgsql` | `8.2-sqlite` |
| 8.3 | `8.3-mysql`       | `8.3-pgsql` | `8.3-sqlite` |
| 8.4 | `8.4-mysql`       | `8.4-pgsql` | `8.4-sqlite` |
| 8.5 | `8.5-mysql`       | `8.5-pgsql` | `8.5-sqlite` |

Every tag is available for `linux/amd64` and `linux/arm64`.

## Rebuilds

- Every 4 hours, the workflow builds all PHP versions. A new FrankenPHP base, Node or Composer release gives a new image.
- Once a week, the build runs `apt-get upgrade` and gets the PHP extensions from PECL again.
- When no input changed, the build gives the same image digest, so the tag does not move and a server downloads nothing.
- A PHP version stops being rebuilt after its end of life (`eol` in `versions.json`). Its tags stay available.

Each image passes `tests/image.sh` before its tag moves. If a build or a test fails, the tag stays on the last good image.

## Use

```dockerfile
FROM ghcr.io/mahocommerce/mahocloud-php:8.4-mysql
```

The image contains an empty `mesa-libgallium` package, which keeps LLVM out of the image. Remove that package before you install anything that renders with Mesa.

## Build locally

```bash
docker build --build-arg PHP_VERSION=8.4 --target mysql -t mahocloud-php:8.4-mysql .
./tests/image.sh mahocloud-php:8.4-mysql mysql
```
