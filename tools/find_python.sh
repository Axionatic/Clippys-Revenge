#!/bin/bash
# find_python.sh — locate a Python interpreter >= 3.10.
#
# Sourced by install.sh; also runnable standalone.
# On success: sets PYTHON_BIN to absolute path and (if invoked) prints it; exit 0.
# On failure: exit 1 with no output.
#
# Probe order:
#   1. $CLIPPY_PYTHON env override
#   2. python3.13, python3.12, python3.11, python3.10 on PATH
#   3. /opt/homebrew/bin/python3 (Apple Silicon brew)
#   4. /usr/local/bin/python3 (Intel brew / generic)
#   5. ~/.local/share/uv/python/cpython-*/bin/python3 (newest first)
#   6. python3 (only on macOS if xcode-select -p succeeds; avoids GUI installer)

# Verify a candidate path is an executable Python >= 3.10.
# Echoes resolved absolute path on success; returns 0/1.
_clippy_check_python() {
    local cand="$1"
    [ -n "$cand" ] || return 1
    [ -x "$cand" ] || return 1
    "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' \
        >/dev/null 2>&1 || return 1
    # Resolve to absolute path (readlink -f not portable on macOS)
    local resolved
    resolved="$(cd "$(dirname "$cand")" 2>/dev/null && pwd)/$(basename "$cand")"
    printf '%s\n' "$resolved"
    return 0
}

find_python() {
    local cand resolved

    # 1. Explicit override
    if [ -n "${CLIPPY_PYTHON:-}" ]; then
        if resolved="$(_clippy_check_python "$CLIPPY_PYTHON")"; then
            PYTHON_BIN="$resolved"
            return 0
        fi
        return 1
    fi

    # 2. Version-pinned interpreters on PATH (newest first)
    local v
    for v in 3.13 3.12 3.11 3.10; do
        cand="$(command -v "python$v" 2>/dev/null || true)"
        if [ -n "$cand" ] && resolved="$(_clippy_check_python "$cand")"; then
            PYTHON_BIN="$resolved"
            return 0
        fi
    done

    # 3-4. Fixed brew paths
    for cand in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        if [ -x "$cand" ] && resolved="$(_clippy_check_python "$cand")"; then
            PYTHON_BIN="$resolved"
            return 0
        fi
    done

    # 5. uv-managed CPython installs (newest first via reverse sort)
    local uv_root="$HOME/.local/share/uv/python"
    if [ -d "$uv_root" ]; then
        local match
        # shellcheck disable=SC2012
        for match in $(ls -1d "$uv_root"/cpython-* 2>/dev/null | sort -r); do
            cand="$match/bin/python3"
            if resolved="$(_clippy_check_python "$cand")"; then
                PYTHON_BIN="$resolved"
                return 0
            fi
        done
    fi

    # 6. Bare `python3` — only safe on macOS if xcode-select tools present,
    # otherwise /usr/bin/python3 is a stub that pops a GUI installer.
    cand="$(command -v python3 2>/dev/null || true)"
    if [ -n "$cand" ]; then
        local safe=1
        if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
            xcode-select -p >/dev/null 2>&1 || safe=0
        fi
        if [ "$safe" = "1" ] && resolved="$(_clippy_check_python "$cand")"; then
            PYTHON_BIN="$resolved"
            return 0
        fi
    fi

    return 1
}

# Standalone invocation: print result to stdout
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    if find_python; then
        printf '%s\n' "$PYTHON_BIN"
        exit 0
    fi
    exit 1
fi
