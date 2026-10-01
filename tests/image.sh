#!/usr/bin/env bash
# Checks a built image against what the Maho Cloud servers rely on.
#
#   ./tests/image.sh <image> <engine>     engine: mysql | pgsql | sqlite
#
# Each command output is read into a variable before grep reads it. A pipe into
# `grep -q` fails at random under pipefail: grep exits at the first match, the
# writer dies of SIGPIPE, and the pipeline reports 141.
set -euo pipefail

image=${1:?usage: image.sh <image> <engine>}
engine=${2:?usage: image.sh <image> <engine>}

failures=0

pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }

run() { docker run --rm --entrypoint "" "$image" "$@"; }

# pdo_sqlite is compiled into PHP by the base image (--with-pdo-sqlite), so every
# image has it. The engine images differ by the MySQL and PostgreSQL drivers and
# by the command-line client.
case "$engine" in
    mysql) driver=pdo_mysql; others="pdo_pgsql"; client=mysql ;;
    pgsql) driver=pdo_pgsql; others="pdo_mysql"; client=psql ;;
    sqlite) driver=pdo_sqlite; others="pdo_mysql pdo_pgsql"; client=sqlite3 ;;
    *) echo "Unknown engine: $engine" >&2; exit 2 ;;
esac

modules=$(run php -m)
for ext in gd intl zip "Zend OPcache" redis soap mbstring FFI vips "$driver"; do
    if grep -qx "$ext" <<< "$modules"; then pass "PHP extension $ext"; else fail "PHP extension $ext is missing"; fi
done
# One engine per image: the other drivers must be absent, or the image is not
# the one the tag names.
for ext in $others; do
    if grep -qx "$ext" <<< "$modules"; then fail "PHP extension $ext must not be in the $engine image"; else pass "no $ext"; fi
done

checks=$(run bash -c '
    set -u
    command -v '"$client"' >/dev/null && echo "client"
    for tool in git patch unzip nano vim.tiny rsync composer node npm npx sshd; do
        command -v "$tool" >/dev/null && echo "tool $tool"
    done
    [ -x /usr/lib/openssh/sftp-server ] && echo "sftp-server"
    ls /etc/ssh/ssh_host_* >/dev/null 2>&1 || echo "no host keys"
    [ "$(id -u maho):$(id -g maho)" = "1000:1000" ] && echo "maho 1000"
    [ "$(stat -c %u /data/caddy):$(stat -c %u /config/caddy)" = "1000:1000" ] && echo "caddy dirs"
    [ "${EDITOR:-}" = "nano" ] && echo "editor"
    node_major=$(node --version | sed "s/^v\([0-9]*\).*/\1/")
    [ "$node_major" -ge 20 ] && echo "node >= 20"
    dpkg-query -W -f="\${Description}\n" mesa-libgallium 2>/dev/null | grep -q "empty stand-in" && echo "mesa stub"
    for pkg in libgbm1 libnss3 fonts-liberation; do
        dpkg-query -W -f="\${Status}\n" "$pkg" 2>/dev/null | grep -q "install ok installed" && echo "package $pkg"
    done
    [ -z "$(ls /var/lib/apt/lists 2>/dev/null | grep -v -e "^lock$" -e "^partial$" -e "^auxfiles$")" ] && echo "apt lists removed"
    frankenphp version >/dev/null && echo "frankenphp"
')

expect() {
    if grep -qx "$1" <<< "$checks"; then pass "$2"; else fail "$2"; fi
}

expect "client" "database client $client"
for tool in git patch unzip nano vim.tiny rsync composer node npm npx sshd; do
    expect "tool $tool" "tool $tool"
done
expect "sftp-server" "/usr/lib/openssh/sftp-server"
expect "no host keys" "no SSH host keys in the image"
expect "maho 1000" "user maho is 1000:1000"
expect "caddy dirs" "/data/caddy and /config/caddy belong to 1000"
expect "editor" "EDITOR=nano"
expect "node >= 20" "Node 20 or later (the accessibility scanner refuses older)"
expect "mesa stub" "mesa-libgallium is the empty stand-in"
for pkg in libgbm1 libnss3 fonts-liberation; do
    expect "package $pkg" "Chromium package $pkg"
done
expect "apt lists removed" "apt lists removed"
expect "frankenphp" "frankenphp runs"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed for $image ($engine)" >&2
    exit 1
fi
echo "All checks passed for $image ($engine)"
