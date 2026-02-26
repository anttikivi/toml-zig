#!/bin/sh

set -eux

sudo -n pkgin -y install go minisign

export PATH="/usr/pkg/bin:/usr/pkg/go/bin:${PATH}"

command -v go
go version

if ! sudo -n pkgin -y install mozilla-rootcerts; then
    sudo -n pkgin -y install ca-certificates
fi

if command -v certctl >/dev/null 2>&1; then
    sudo -n certctl rehash
fi

if [ ! -f /etc/openssl/certs/ca-certificates.crt ] && [ -f /usr/pkg/etc/openssl/certs/ca-certificates.crt ]; then
    sudo -n mkdir -p /etc/openssl/certs
    sudo -n ln -sf /usr/pkg/etc/openssl/certs/ca-certificates.crt /etc/openssl/certs/ca-certificates.crt
fi

./zig build fetch-toml-test
./zig build test -Dtoml-test-timeout=10s --summary all
