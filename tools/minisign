#!/bin/sh

set -eu

MINISIGN_VERSION="0.12"

SCRIPT_DIR="$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd)"
REPOSITORY_ROOT="$(CDPATH="" cd -- "${SCRIPT_DIR}/.." && pwd)"
TOOLS_DIR="${REPOSITORY_ROOT}/tools"
LOCAL_MINISIGN_DIR="${TOOLS_DIR}/.minisign"
LOCAL_MINISIGN_BIN="${LOCAL_MINISIGN_DIR}/minisign"

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

    found_version="$("$1" -v 2>/dev/null)" || return 1
    case "${found_version}" in
    *"${MINISIGN_VERSION}"*)
        return 0
        ;;
    esac
    return 1
}

find_minisign() {
    if is_right_version "${LOCAL_MINISIGN_BIN}"; then
        printf "%s\n" "${LOCAL_MINISIGN_BIN}"
        return 0
    fi

    if is_right_version minisign; then
        printf "%s\n" "minisign"
        return 0
    fi

    return 1
}

main() {
    minisign_bin=""
    if minisign_bin="$(find_minisign 2>/dev/null)"; then
        :
    else
        "${SCRIPT_DIR}/download_minisign.sh" "${MINISIGN_VERSION}" "${LOCAL_MINISIGN_DIR}" 1>&2

        minisign_bin="${LOCAL_MINISIGN_BIN}"

        if ! is_right_version "${minisign_bin}"; then
            echo "downloaded minisign is missing or has wrong version: ${minisign_bin}" >&2
            return 1
        fi
    fi

    exec "$minisign_bin" "$@"
}

main "$@"
