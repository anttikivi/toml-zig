#!/bin/sh

# SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
#
# SPDX-License-Identifier: Apache-2.0

set -eu

SCRIPT_DIR="$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd)"
REPOSITORY_ROOT="$(CDPATH="" cd -- "${SCRIPT_DIR}/.." && pwd)"
BUILD_ZIG_ZON="${REPOSITORY_ROOT}/build.zig.zon"
TOOLS_DIR="${REPOSITORY_ROOT}/tools"
LOCAL_ZIG_DIR="${TOOLS_DIR}/.zig"
LOCAL_ZIG_BIN="${LOCAL_ZIG_DIR}/zig"

read_zig_version() {
    zon_file=$1

    [ -r "${zon_file}" ] || {
        echo "missing build metadata file: ${zon_file}" >&2
        return 1
    }

    while IFS= read -r line || [ -n "${line}" ]; do
        case "${line}" in
        *".minimum_zig_version"*)
            rest=${line#*\"}
            [ "${rest}" != "${line}" ] || break

            version=${rest%%\"*}
            [ -n "${version}" ] || break

            printf "%s\n" "${version}"
            return 0
            ;;
        esac
    done <"${zon_file}"

    echo "failed to read .minimum_zig_version from ${zon_file}" >&2
    return 1
}

ZIG_VERSION="$(read_zig_version "${BUILD_ZIG_ZON}")"

is_right_version() {
    [ -n "$1" ] || return 1

    case "$1" in
    */*)
        [ -x "$1" ] || return 1
        ;;
    *)
        command -v "$1" >/dev/null 2>&1 || return 1
        ;;
    esac

    found_version="$("$1" version 2>/dev/null)" || return 1
    [ "${found_version}" = "${ZIG_VERSION}" ]
}

find_zig() {
    if is_right_version "${LOCAL_ZIG_BIN}"; then
        printf "%s\n" "${LOCAL_ZIG_BIN}"
        return 0
    fi

    if is_right_version zig; then
        printf "%s\n" "zig"
        return 0
    fi

    return 1
}

main() {
    zig_bin=""
    if zig_bin="$(find_zig 2>/dev/null)"; then
        :
    else
        "${SCRIPT_DIR}/download_zig.sh" "${ZIG_VERSION}" "${LOCAL_ZIG_DIR}" 1>&2

        zig_bin="${LOCAL_ZIG_BIN}"

        if ! is_right_version "${zig_bin}"; then
            echo "downloaded Zig is missing or has wrong version: ${zig_bin}" >&2
            return 1
        fi
    fi

    exec "$zig_bin" "$@"
}

main "$@"
