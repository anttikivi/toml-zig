#!/bin/sh

set -eux

sudo -n pkgin -y install curl minisign

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

GO_VERSION=1.26.0
GO_ARCHIVE="go${GO_VERSION}.netbsd-arm64.tar.gz"
GO_SHA256="379d6ef6dfa8b67a7776744a536e69a1dc0fe5aeed48eb882ac71f89a98ba8ab"
GO_URL="https://go.dev/dl/${GO_ARCHIVE}"
GO_INSTALL_DIR="tools/.go"

tmp_dir=$(mktemp -d .tmp-go.XXXXXXXX)
trap 'rm -rf "${tmp_dir}"' EXIT INT TERM

curl -fL -o "${tmp_dir}/${GO_ARCHIVE}" "${GO_URL}"

actual_sha256=$(sha256 -q "${tmp_dir}/${GO_ARCHIVE}")
[ "${actual_sha256}" = "${GO_SHA256}" ]

tar -xzf "${tmp_dir}/${GO_ARCHIVE}" -C "${tmp_dir}"
rm -rf "${GO_INSTALL_DIR}"
mv "${tmp_dir}/go" "${GO_INSTALL_DIR}"

export PATH="$(pwd)/${GO_INSTALL_DIR}/bin:${PATH}"

command -v go
go version

./zig build fetch-toml-test
./zig build test -Dtoml-test-timeout=10s --summary all
