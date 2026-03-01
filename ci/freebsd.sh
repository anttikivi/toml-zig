#!/bin/sh
# SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
# SPDX-License-Identifier: Apache-2.0

set -eux

sudo -n pkg install -y ca_root_nss minisign

if [ ! -f /etc/ssl/cert.pem ] && [ -f /usr/local/share/certs/ca-root-nss.crt ]; then
    sudo -n mkdir -p /etc/ssl
    sudo -n ln -sf /usr/local/share/certs/ca-root-nss.crt /etc/ssl/cert.pem
fi

./zig build fetch-toml-test
./zig build test -Dtoml-test-timeout=10s --summary all
