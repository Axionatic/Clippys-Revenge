#!/bin/bash
# Clippy's Revenge — uninstaller
#
# HARD RULE: never touch user-owned tooling — no cargo, no Homebrew,
# no Xcode CLT, no system Python. Markers under $INSTALL_DIR record what
# *we* installed; only those things are offered for cleanup.

set -uo pipefail

INSTALL_DIR="$HOME/.local/share/clippys-revenge"
BIN_LINK="$HOME/.local/bin/clippy"
BIN_LINK_UNINSTALL="$HOME/.local/bin/clippy-uninstall"
TMP_DIR="${TMPDIR:-/tmp}/clippys-revenge"
CACHE_DIR="$HOME/.cache/clippys-revenge"

# -- TTY-aware color helpers ------------------------------------------------

if [ -t 1 ]; then
    C_INFO=$'\033[1;34m'
    C_OK=$'\033[1;32m'
    C_WARN=$'\033[1;33m'
    C_ERR=$'\033[1;31m'
    C_RST=$'\033[0m'
else
    C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_RST=""
fi

info() { printf '%s::%s %s\n' "$C_INFO" "$C_RST" "$*"; }
ok()   { printf '%s::%s %s\n' "$C_OK"   "$C_RST" "$*"; }
warn() { printf '%s::%s %s\n' "$C_WARN" "$C_RST" "$*"; }
err()  { printf '%s::%s %s\n' "$C_ERR"  "$C_RST" "$*" >&2; }

failed=0

info "Uninstalling Clippy's Revenge..."

# -- Read markers BEFORE removing INSTALL_DIR -------------------------------

MARK_TATTOY=false
MARK_TATTOY_BREW=false
MARK_TATTOY_BINARY=false
MARK_UV=false
MARK_UV_PY=false
MARK_CARGO=false
MARK_HOMEBREW=false
MARK_BREW_PY=false
[ -f "$INSTALL_DIR/.tattoy-installed-by-us" ]      && MARK_TATTOY=true
[ -f "$INSTALL_DIR/.tattoy-installed-via-brew" ]   && MARK_TATTOY_BREW=true
[ -f "$INSTALL_DIR/.tattoy-installed-via-binary" ] && MARK_TATTOY_BINARY=true
[ -f "$INSTALL_DIR/.uv-installed-by-us" ]          && MARK_UV=true
[ -f "$INSTALL_DIR/.uv-python-installed-by-us" ]   && MARK_UV_PY=true
[ -f "$INSTALL_DIR/.cargo-installed-by-us" ]       && MARK_CARGO=true
[ -f "$INSTALL_DIR/.homebrew-installed-by-us" ]    && MARK_HOMEBREW=true
[ -f "$INSTALL_DIR/.brew-python-installed-by-us" ] && MARK_BREW_PY=true

prompt_yn() {
    # prompt_yn "<message>" <default y|n>  -> 0 if yes, 1 if no
    local msg="$1" default="$2" answer=""
    local hint
    if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    if [ -t 0 ] || [ -r /dev/tty ]; then
        printf '    %s %s ' "$msg" "$hint"
        { read -r answer </dev/tty; } 2>/dev/null || answer=""
    else
        answer=""
    fi
    answer="${answer:-$default}"
    case "$answer" in
        [Yy]*) return 0 ;;
        *)     return 1 ;;
    esac
}

# -- Remove symlinks --------------------------------------------------------

for link in "$BIN_LINK" "$BIN_LINK_UNINSTALL"; do
    if [ -L "$link" ] || [ -f "$link" ]; then
        if rm -f "$link"; then
            ok "Removed $link"
        else
            err "Cannot remove $link (permission denied)."
            failed=1
        fi
    fi
done

# -- Remove install directory -----------------------------------------------

if [ -d "$INSTALL_DIR" ]; then
    if rm -rf "$INSTALL_DIR"; then
        ok "Removed $INSTALL_DIR"
    else
        err "Cannot remove $INSTALL_DIR (permission denied)."
        failed=1
    fi
fi

# -- Remove temp directory --------------------------------------------------

if [ -d "$TMP_DIR" ]; then
    if rm -rf "$TMP_DIR"; then
        ok "Removed $TMP_DIR"
    else
        err "Cannot remove $TMP_DIR (permission denied)."
        failed=1
    fi
fi

# -- Remove cache directory -------------------------------------------------

if [ -d "$CACHE_DIR" ]; then
    if rm -rf "$CACHE_DIR"; then
        ok "Removed $CACHE_DIR"
    else
        err "Cannot remove $CACHE_DIR (permission denied)."
        failed=1
    fi
fi

# -- Optional cleanup of things WE installed --------------------------------

if $MARK_TATTOY; then
    if prompt_yn "Remove tattoy (cargo uninstall tattoy)?" "n"; then
        if command -v cargo >/dev/null 2>&1; then
            if cargo uninstall tattoy; then
                ok "tattoy uninstalled"
            else
                warn "cargo uninstall tattoy failed; remove manually if desired."
            fi
        else
            warn "cargo not on PATH; skipping tattoy uninstall."
        fi
    fi
fi

if $MARK_TATTOY_BREW; then
    if prompt_yn "Remove tattoy (brew uninstall tattoy-org/tap/tattoy)?" "n"; then
        if command -v brew >/dev/null 2>&1; then
            if brew uninstall tattoy-org/tap/tattoy; then
                ok "tattoy uninstalled"
            else
                warn "brew uninstall failed; remove manually if desired."
            fi
        else
            warn "brew not on PATH; skipping tattoy uninstall."
        fi
    fi
fi

if $MARK_TATTOY_BINARY; then
    if prompt_yn "Remove tattoy binary at $HOME/.local/bin/tattoy?" "n"; then
        if rm -f "$HOME/.local/bin/tattoy"; then
            ok "Removed $HOME/.local/bin/tattoy"
        else
            warn "Could not remove $HOME/.local/bin/tattoy."
        fi
    fi
fi

if $MARK_UV_PY; then
    if prompt_yn "Remove uv-managed Python 3.13 used by Clippy?" "n"; then
        if command -v uv >/dev/null 2>&1; then
            if uv python uninstall 3.13; then
                ok "uv-managed Python 3.13 removed"
            else
                warn "uv python uninstall 3.13 failed."
            fi
        else
            warn "uv not on PATH; skipping Python uninstall."
        fi
    fi
fi

if $MARK_UV; then
    if prompt_yn "Remove uv itself?" "n"; then
        if command -v uv >/dev/null 2>&1 && uv self uninstall >/dev/null 2>&1; then
            ok "uv removed via 'uv self uninstall'"
        else
            warn "uv self uninstall unavailable; falling back to manual cleanup."
            rm -rf "$HOME/.local/share/uv" "$HOME/.local/bin/uv" 2>/dev/null || true
            ok "Removed ~/.local/share/uv and ~/.local/bin/uv"
        fi
    fi
fi

if $MARK_CARGO; then
    warn "We installed rustup/cargo for you during install."
    warn "Other Rust tools may depend on this. Remove only if Clippy was your sole reason for installing it."
    if prompt_yn "Remove rustup + cargo (rustup self uninstall -y)?" "n"; then
        if command -v rustup >/dev/null 2>&1; then
            if rustup self uninstall -y; then
                ok "rustup + cargo removed"
            else
                warn "rustup self uninstall failed; remove manually if desired."
            fi
        else
            warn "rustup not on PATH; skipping cargo uninstall."
        fi
    fi
fi

if $MARK_BREW_PY; then
    warn "We installed python@3.13 via Homebrew for you during install."
    warn "Other tools may depend on this. Remove only if Clippy was your sole reason for installing it."
    if prompt_yn "Remove python@3.13 (brew uninstall python@3.13)?" "n"; then
        if command -v brew >/dev/null 2>&1; then
            if brew uninstall python@3.13; then
                ok "python@3.13 uninstalled"
            else
                warn "brew uninstall python@3.13 failed; remove manually if desired."
            fi
        else
            warn "brew not on PATH; skipping python@3.13 uninstall."
        fi
    fi
fi

if $MARK_HOMEBREW; then
    warn "We installed Homebrew for you during install."
    warn "Other tools almost certainly depend on this. Remove only if Clippy was your sole reason for installing it."
    if prompt_yn "Remove Homebrew (runs the official Homebrew uninstaller)?" "n"; then
        # Download to a file first: a failed `$(curl ...)` would expand to an
        # empty script that `bash -c` runs successfully, falsely reporting removal.
        brew_uninstaller="$(mktemp)"
        if ! curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh \
                -o "$brew_uninstaller" || [ ! -s "$brew_uninstaller" ]; then
            warn "Could not download the Homebrew uninstaller; remove manually if desired."
        elif ! /bin/bash "$brew_uninstaller" --force; then
            warn "Homebrew uninstaller failed; remove manually if desired."
        else
            ok "Homebrew removed"
        fi
        rm -f "$brew_uninstaller"
    fi
fi

# -- rc-file PATH line removal (only the exact block we wrote) --------------

# Marker block written by install.sh:
#   <blank line>
#   # Added by Clippy's Revenge installer
#   export PATH="$HOME/.local/bin:$PATH"
MARKER_COMMENT="# Added by Clippy's Revenge installer"
MARKER_EXPORT='export PATH="$HOME/.local/bin:$PATH"'
MARKER_FISH='set -gx PATH "$HOME/.local/bin" $PATH'

for rc_file in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.config/fish/config.fish"; do
    [ -f "$rc_file" ] || continue
    if grep -Fq "$MARKER_COMMENT" "$rc_file" && \
       { grep -Fq "$MARKER_EXPORT" "$rc_file" || grep -Fq "$MARKER_FISH" "$rc_file"; }; then
        if prompt_yn "Remove the PATH line we added to $rc_file? It puts ~/.local/bin on PATH; safe to remove if you don't use anything else there." "y"; then
            cp "$rc_file" "$rc_file.bak"
            # Remove the exact two-line marker block plus the blank line
            # install.sh emitted immediately before it. awk is portable
            # across macOS BSD and GNU.
            awk -v c="$MARKER_COMMENT" -v e="$MARKER_EXPORT" -v f="$MARKER_FISH" '
                { a[NR] = $0; n = NR }
                END {
                    for (i = 1; i <= n; i++) {
                        if (a[i] == c && i+1 <= n && (a[i+1] == e || a[i+1] == f)) {
                            skip[i] = 1; skip[i+1] = 1
                            if (i > 1 && a[i-1] == "") skip[i-1] = 1
                        }
                    }
                    for (i = 1; i <= n; i++) if (!(i in skip)) print a[i]
                }
            ' "$rc_file.bak" > "$rc_file"
            ok "Cleaned $rc_file (backup at $rc_file.bak)"
        fi
    fi
done

# -- Result -----------------------------------------------------------------

echo ""
if [ "$failed" -ne 0 ]; then
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        err "Some files could not be removed due to permissions."
        err "Re-run with sudo:  sudo bash uninstall.sh"
    else
        err "Some files could not be removed even as root."
        err "Check the paths above and remove them manually."
    fi
    exit 1
fi

ok "Clippy's Revenge uninstalled."
