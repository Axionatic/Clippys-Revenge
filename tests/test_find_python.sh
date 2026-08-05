#!/bin/bash
# test_find_python.sh — verify probe order in tools/find_python.sh.
#
# Each test runs in a subshell with HOME and PATH controlled so the probe
# only sees stubs we created. The host coreutils are invoked via absolute
# paths so PATH manipulation can't break setup.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIND_PY="$REPO_ROOT/tools/find_python.sh"

# Cache absolute paths to coreutils — we'll be wiping PATH inside each test.
MKDIR="$(command -v mkdir)"
CHMOD="$(command -v chmod)"
MKTEMP="$(command -v mktemp)"
RM="$(command -v rm)"
CAT="$(command -v cat)"
DIRNAME="$(command -v dirname)"
LN="$(command -v ln)"

# Build a "clean" PATH directory: coreutils symlinks but nothing python.
# find_python.sh itself needs dirname/basename/sort/ls/command -v.
CLEAN_BIN="$("$MKTEMP" -d)"
for util in mkdir chmod mktemp rm cat dirname basename sort ls cp mv test grep awk sed bash sh; do
    src="$(command -v "$util" 2>/dev/null || true)"
    [ -n "$src" ] && "$LN" -s "$src" "$CLEAN_BIN/$util"
done
trap '"$RM" -rf "$CLEAN_BIN"' EXIT

PASS=0
FAIL=0

red()   { printf '\033[1;31m%s\033[0m' "$*"; }
green() { printf '\033[1;32m%s\033[0m' "$*"; }

# make_fake_python <dest> <major> <minor>
# Writes a stub interpreter that satisfies find_python.sh's version probe.
make_fake_python() {
    local dest="$1" major="$2" minor="$3"
    "$MKDIR" -p "$("$DIRNAME" "$dest")"
    "$CAT" > "$dest" <<EOF
#!/bin/bash
case "\$2" in
    'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)')
        if [ "$major" -gt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -ge 10 ]; }; then
            exit 0
        else
            exit 1
        fi
        ;;
esac
exit 0
EOF
    "$CHMOD" +x "$dest"
}

# run_test <name> <expected_substring|FAIL> <setup_func>
run_test() {
    local name="$1" expected="$2" setup="$3"
    local tmp result rc=0
    tmp="$("$MKTEMP" -d)"
    (
        export HOME="$tmp/home"
        "$MKDIR" -p "$HOME"
        unset CLIPPY_PYTHON
        # PATH = symlinked-coreutils-only dir. Setup may prepend its own
        # bin to expose python stubs; nothing else is reachable.
        export PATH="$CLEAN_BIN"
        TMP="$tmp" "$setup"
        # shellcheck disable=SC1090
        . "$FIND_PY"
        if find_python; then
            printf '%s\n' "$PYTHON_BIN" > "$tmp/result"
            exit 0
        fi
        exit 1
    )
    rc=$?
    if [ -f "$tmp/result" ]; then
        result="$("$CAT" "$tmp/result")"
    else
        result="(none)"
    fi
    if [ "$expected" = "FAIL" ]; then
        if [ $rc -ne 0 ]; then
            green "PASS"; echo " — $name (got fail as expected)"
            PASS=$((PASS+1))
        else
            red "FAIL"; echo " — $name (expected failure, got $result)"
            FAIL=$((FAIL+1))
        fi
    else
        if [ $rc -eq 0 ] && [[ "$result" == *"$expected"* ]]; then
            green "PASS"; echo " — $name -> $result"
            PASS=$((PASS+1))
        else
            red "FAIL"; echo " — $name (expected substring '$expected', got '$result')"
            FAIL=$((FAIL+1))
        fi
    fi
    "$RM" -rf "$tmp"
}

# --- setup blocks ----------------------------------------------------------

setup_clippy_python_override() {
    make_fake_python "$TMP/override/python_override" 3 13
    export CLIPPY_PYTHON="$TMP/override/python_override"
}

setup_version_pinned_picks_newest() {
    make_fake_python "$TMP/bin/python3.10" 3 10
    make_fake_python "$TMP/bin/python3.12" 3 12
    make_fake_python "$TMP/bin/python3.13" 3 13
    export PATH="$TMP/bin:$PATH"
}

setup_only_3_14() {
    make_fake_python "$TMP/bin/python3.14" 3 14
    export PATH="$TMP/bin:$PATH"
}

setup_falls_back_to_3_10() {
    make_fake_python "$TMP/bin/python3.10" 3 10
    export PATH="$TMP/bin:$PATH"
}

setup_uv_managed() {
    local uv_root="$HOME/.local/share/uv/python"
    make_fake_python "$uv_root/cpython-3.13.0-linux/bin/python3" 3 13
}

setup_no_python_anywhere() {
    :
}

setup_too_old_rejected() {
    make_fake_python "$TMP/bin/python3.10" 3 9
    export PATH="$TMP/bin:$PATH"
}

# --- run -------------------------------------------------------------------

run_test "CLIPPY_PYTHON override wins"   "python_override"        setup_clippy_python_override
run_test "version-pinned picks newest"   "python3.13"             setup_version_pinned_picks_newest
run_test "version-pinned finds 3.14"     "python3.14"             setup_only_3_14
run_test "version-pinned 3.10 fallback"  "python3.10"             setup_falls_back_to_3_10
run_test "uv-managed CPython discovered" "uv/python/cpython-3.13" setup_uv_managed
run_test "rejects <3.10"                 "FAIL"                   setup_too_old_rejected
run_test "no python anywhere"            "FAIL"                   setup_no_python_anywhere

echo ""
echo "Total: $((PASS+FAIL))  Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
