#!/bin/sh

# SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
#
# SPDX-License-Identifier: Apache-2.0

set -eux

sudo -n pkgin -y install minisign

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
