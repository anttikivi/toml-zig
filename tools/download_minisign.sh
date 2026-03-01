#!/bin/sh

# SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
#
# SPDX-License-Identifier: Apache-2.0

set -eu

MINISIGN_GITHUB_BASE_URL="https://github.com/jedisct1/minisign/releases/download"

MINISIGN_SHA256="$(
    cat <<EOF
9a599b48ba6eb7b1e80f12f36b94ceca7c00b7a5173c95c3efc88d9822957e73  minisign-0.12-linux.tar.gz
89000b19535765f9cffc65a65d64a820f433ef6db8020667f7570e06bf6aac63  minisign-0.12-macos.zip
37b600344e20c19314b2e82813db2bfdcc408b77b876f7727889dbd46d539479  minisign-0.12-win64.zip
EOF
)"

download_archive() {
    [ -n "$1" ] || {
        echo "no URL passed to 'download_archive'" >&2
        return 1
    }

    [ -n "$2" ] || {
        echo "no output passed to 'download_archive'" >&2
        return 1
    }

    _url="$1"
    _out="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSLo "${_out}" "${_url}"
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -qO "${_out}" "${_url}"
        return $?
    fi

    echo "neither curl nor wget found" >&2
    return 127
}

make_tempdir() {
    [ -n "$1" ] || {
        echo "no parent directory passed to 'make_tempdir'" >&2
        return 1
    }

    [ -d "$1" ] || {
        echo "parent directory in 'make_tempdir' must exist" >&2
        return 1
    }

    _tmpdir="$(mktemp -d "$1/.minisign-tmp.XXXXXXXX" 2>/dev/null || true)"
    if [ -n "${_tmpdir}" ] && [ -d "${_tmpdir}" ]; then
        printf "%s\n" "${_tmpdir}"
        return 0
    fi

    mktemp -d -t "minisign-tmp.XXXXXXXX"
}

verify_sha256() {
    [ -n "$1" ] || {
        echo "no file passed to 'verify_sha256'" >&2
        return 1
    }

    [ -n "$2" ] || {
        echo "no expected hash passed to 'verify_sha256'" >&2
        return 1
    }

    _file="$1"
    _expected="$2"

    if command -v sha256sum >/dev/null 2>&1; then
        _actual="$(sha256sum "${_file}" | awk '{ print $1 }')"
    elif command -v shasum >/dev/null 2>&1; then
        _actual="$(shasum -a 256 "${_file}" | awk '{ print $1 }')"
    else
        echo "neither sha256sum nor shasum found" >&2
        return 1
    fi

    if [ "${_actual}" != "${_expected}" ]; then
        echo "SHA256 mismatch for ${_file}" >&2
        echo "  expected: ${_expected}" >&2
        echo "  actual:   ${_actual}" >&2
        return 1
    fi
}

main() {
    [ $# -ge 2 ] || {
        echo "usage: download_minisign version destdir" >&2
        return 1
    }

    [ -n "$1" ] || {
        echo "no minisign version argument passed to 'download_minisign'" >&2
        return 1
    }

    [ -n "$2" ] || {
        echo "no destination directory argument passed to 'download_minisign'" >&2
        return 1
    }

    _minisign_version="$1"
    _dest_dir="$2"

    if [ "$(uname -m)" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]; then
        _arch="aarch64"
    else
        _arch="x86_64"
    fi

    if [ "$(uname)" = "Darwin" ] && [ "${_arch}" = "x86_64" ]; then
        echo "minisign repository does not provide prebuilt binaries for x86_64 Darwin" >&2
        echo "please install minisign using other methods, like Homebrew" >&2
        return 1
    fi

    case "$(uname)" in
    Darwin)
        _archive="minisign-${_minisign_version}-macos.zip"
        ;;
    Linux)
        _archive="minisign-${_minisign_version}-linux.tar.gz"
        ;;
    *)
        echo "unsupported operating system: $(uname)" >&2
        return 1
        ;;
    esac

    _expected_sha256="$(printf "%s\n" "${MINISIGN_SHA256}" | grep -F "${_archive}" | awk '{ print $1 }')"

    _archive_dir_parent="$(dirname -- "${_dest_dir}")"
    mkdir -p "${_archive_dir_parent}"

    _archive_dir="$(make_tempdir "${_archive_dir_parent}")"
    trap 'rm -rf "${_archive_dir}"' EXIT INT TERM HUP

    _archive_dest="${_archive_dir}/${_archive}"

    _url="${MINISIGN_GITHUB_BASE_URL}/${_minisign_version}/${_archive}"
    echo "downloading minisign from ${_url}..."

    if ! download_archive "${_url}" "${_archive_dest}"; then
        echo "failed to download minisign from ${_url}" >&2
        return 1
    fi

    echo "verifying ${_archive}..."
    if ! verify_sha256 "${_archive_dest}" "${_expected_sha256}"; then
        echo "SHA256 verification failed for ${_archive}" >&2
        return 1
    fi
    echo "SHA256 verification passed"

    echo "extracting ${_archive_dest}..."
    case "$(uname)" in
    Darwin)
        unzip -qo "${_archive_dest}" -d "${_archive_dir}"
        _minisign_bin="${_archive_dir}/minisign"
        ;;
    Linux)
        tar -C "${_archive_dir}" -xzf "${_archive_dest}"
        _minisign_bin="${_archive_dir}/minisign-linux/${_arch}/minisign"
        ;;
    esac
    rm "${_archive_dest}"

    if [ ! -f "${_minisign_bin}" ]; then
        echo "minisign binary not found after extraction" >&2
        return 1
    fi

    chmod +x "${_minisign_bin}"

    rm -rf "${_dest_dir:?}"
    mkdir -p "${_dest_dir:?}"

    mv "${_minisign_bin}" "${_dest_dir}/minisign"

    echo "minisign ${_minisign_version} available at ${_dest_dir}/minisign"
}

main "$@"
