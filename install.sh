#!/bin/bash
# Clippy's Revenge — installer
#
# Usage:
#   bash install.sh           # install latest from GitHub
#   bash install.sh --from-local   # install from this working directory (for development)
#   curl -fsSL https://raw.githubusercontent.com/Axionatic/Clippys-Revenge/main/install.sh | bash

set -euo pipefail

INSTALL_DIR="$HOME/.local/share/clippys-revenge"
BIN_DIR="$HOME/.local/bin"
REPO_URL="https://github.com/Axionatic/Clippys-Revenge.git"
TARBALL_URL="https://github.com/Axionatic/Clippys-Revenge/archive/refs/heads/main.tar.gz"
SCRIPT_DIR=""

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

info()  { printf '%s::%s %s\n' "$C_INFO" "$C_RST" "$*"; }
ok()    { printf '%s::%s %s\n' "$C_OK"   "$C_RST" "$*"; }
warn()  { printf '%s::%s %s\n' "$C_WARN" "$C_RST" "$*"; }
err()   { printf '%s::%s %s\n' "$C_ERR"  "$C_RST" "$*" >&2; }

is_macos() { [[ "${OSTYPE:-}" == darwin* ]]; }

# -- Argument parsing --------------------------------------------------------

LOCAL=false
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --from-local) LOCAL=true ;;
        --dry-run)    DRY_RUN=true ;;
        *) err "Unknown argument: $arg"; exit 1 ;;
    esac
done

if [ "$LOCAL" = true ]; then
    if [ -z "${BASH_SOURCE[0]:-}" ]; then
        err "--from-local requires the script to be run from a file, not piped."
        exit 1
    fi
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# run_or_dry — execute command, or print "WOULD: ..." in dry-run mode.
run_or_dry() {
    if $DRY_RUN; then
        info "WOULD: $*"
        return 0
    fi
    "$@"
}

# write_marker — touch a marker file (or print intent in dry-run).
write_marker() {
    local path="$1"
    if $DRY_RUN; then
        info "WOULD: write marker $path"
    else
        : > "$path"
    fi
}

# write_file — write content to a file (or print intent).
write_file() {
    local path="$1" content="$2"
    if $DRY_RUN; then
        info "WOULD: write $path = $content"
    else
        printf '%s\n' "$content" > "$path"
    fi
}

# write_marker_now — write a marker immediately, during bootstrap, rather
# than waiting for the batched write after project installation. Only takes
# effect when $INSTALL_DIR already exists (an update run, with a working
# uninstall.sh already in place) — on a fresh install there is nothing yet
# for that uninstall.sh to belong to, so a crash before project installation
# completes leaves no install to clean up regardless of markers; the batched
# write below covers the normal fresh-install case identically to before.
write_marker_now() {
    [ -d "$INSTALL_DIR" ] || return 0
    write_marker "$1"
}

# Capture cargo presence once for end-of-install Rust note.
HAVE_CARGO_AT_START=false
if command -v cargo >/dev/null 2>&1; then
    HAVE_CARGO_AT_START=true
fi

if $DRY_RUN; then
    info "Dry-run mode — no changes will be written."
fi

# -- Root check -------------------------------------------------------------

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    warn "Running as root — files will be installed into root's \$HOME."
    warn "This is usually not what you want."
    answer=""
    printf '    Continue anyway? [y/N] '
    { read -r answer </dev/tty; } 2>/dev/null || true
    case "${answer:-n}" in
        [Yy]*) ;;
        *)
            err "Aborted."
            exit 1
            ;;
    esac
fi

# -- Previous-install ownership check ---------------------------------------

if [ -d "$INSTALL_DIR" ] && [ ! -w "$INSTALL_DIR" ]; then
    err "Cannot write to $INSTALL_DIR (owned by a different user)."
    err "This usually happens when a previous install was run with sudo."
    err ""
    err "To fix, uninstall first then re-run this installer:"
    err "  sudo bash $INSTALL_DIR/uninstall.sh"
    err "  bash install.sh"
    exit 1
fi

# -- Idempotency banner -----------------------------------------------------

if [ -f "$INSTALL_DIR/.python-bin" ]; then
    info "Existing install detected at $INSTALL_DIR — updating to latest."
fi

# -- Python discovery -------------------------------------------------------

# Wrapped in a function so the menu's [2] path can re-resolve PYTHON_BIN
# after Homebrew + python@3.13 install without exiting.
discover_python() {
    PYTHON_BIN=""
    FIND_PY_LOCAL=""
    if [ "$LOCAL" = true ] && [ -f "$SCRIPT_DIR/tools/find_python.sh" ]; then
        FIND_PY_LOCAL="$SCRIPT_DIR/tools/find_python.sh"
    elif [ -f "$INSTALL_DIR/tools/find_python.sh" ]; then
        FIND_PY_LOCAL="$INSTALL_DIR/tools/find_python.sh"
    fi

    if [ -n "$FIND_PY_LOCAL" ]; then
        # shellcheck disable=SC1090
        . "$FIND_PY_LOCAL"
        find_python || true
        return
    fi

    # Inline probe — kept in sync with tools/find_python.sh.
    # 1. CLIPPY_PYTHON override
    if [ -n "${CLIPPY_PYTHON:-}" ] && [ -x "$CLIPPY_PYTHON" ] && \
       "$CLIPPY_PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' >/dev/null 2>&1; then
        PYTHON_BIN="$CLIPPY_PYTHON"
    fi
    # 2. Version-pinned
    if [ -z "$PYTHON_BIN" ]; then
        for v in 3.14 3.13 3.12 3.11 3.10; do
            cand="$(command -v "python$v" 2>/dev/null || true)"
            if [ -n "$cand" ] && \
               "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' >/dev/null 2>&1; then
                PYTHON_BIN="$cand"; break
            fi
        done
    fi
    # 3-4. Brew paths
    if [ -z "$PYTHON_BIN" ]; then
        for cand in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
            if [ -x "$cand" ] && \
               "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' >/dev/null 2>&1; then
                PYTHON_BIN="$cand"; break
            fi
        done
    fi
    # 5. uv-managed
    if [ -z "$PYTHON_BIN" ] && [ -d "$HOME/.local/share/uv/python" ]; then
        for match in $(ls -1d "$HOME"/.local/share/uv/python/cpython-* 2>/dev/null | sort -r); do
            cand="$match/bin/python3"
            if [ -x "$cand" ] && \
               "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' >/dev/null 2>&1; then
                PYTHON_BIN="$cand"; break
            fi
        done
    fi
    # 6. python3 (only if macOS xcode-select gate passes)
    if [ -z "$PYTHON_BIN" ]; then
        cand="$(command -v python3 2>/dev/null || true)"
        safe=1
        if [ -n "$cand" ] && is_macos && ! xcode-select -p >/dev/null 2>&1; then
            safe=0
        fi
        if [ -n "$cand" ] && [ "$safe" = "1" ] && \
           "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' >/dev/null 2>&1; then
            PYTHON_BIN="$cand"
        fi
    fi
}

info "Looking for Python 3.10+..."
discover_python

# -- macOS bootstrap --------------------------------------------------------

UV_INSTALLED_BY_US=false
UV_PYTHON_INSTALLED_BY_US=false
HOMEBREW_INSTALLED_BY_US=false
BREW_PYTHON_INSTALLED_BY_US=false
CARGO_INSTALLED_BY_US=false

uv_install_path() {
    # Deliberate choice: pipe-to-shell the official uv installer rather than
    # vendoring a GitHub release tarball download. astral.sh is a known
    # vendor, the URL is shown to the user, the prompt is opt-in, and we
    # roll back on failure. Vendoring would add ~50 lines of fragile
    # arch-detection / checksum / release-URL code with ongoing maintenance.
    local uv_was_present=true
    if ! command -v uv >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/uv" ]; then
        uv_was_present=false
    fi

    if ! $uv_was_present; then
        info "About to run the official uv installer:"
        info "  curl -LsSf https://astral.sh/uv/install.sh | sh"
        if $DRY_RUN; then
            info "WOULD: prompt to confirm uv installer (assume yes)"
            info "WOULD: curl -LsSf https://astral.sh/uv/install.sh | sh"
            info "WOULD: uv python install 3.13"
            PYTHON_BIN="(uv-managed CPython 3.13)"
            UV_INSTALLED_BY_US=true
            UV_PYTHON_INSTALLED_BY_US=true
            write_marker_now "$INSTALL_DIR/.uv-installed-by-us"
            write_marker_now "$INSTALL_DIR/.uv-python-installed-by-us"
            return 0
        fi
        local answer=""
        printf '    Proceed? [Y/n] '
        { read -r answer </dev/tty; } 2>/dev/null || answer="n"
        case "${answer:-y}" in
            [Yy]*) ;;
            *) warn "Cancelled."; exit 0 ;;
        esac

        if ! curl -LsSf https://astral.sh/uv/install.sh | sh; then
            err "Network error. Check your connection and re-run \`bash install.sh\`."
            exit 1
        fi
        UV_INSTALLED_BY_US=true
        write_marker_now "$INSTALL_DIR/.uv-installed-by-us"
    else
        ok "uv already installed — reusing it."
    fi

    # Make uv reachable in this script process.
    if [ -f "$HOME/.local/bin/env" ]; then
        # shellcheck disable=SC1091
        . "$HOME/.local/bin/env"
    else
        export PATH="$HOME/.local/bin:$PATH"
    fi

    if ! command -v uv >/dev/null 2>&1; then
        err "uv installed but not on PATH; aborting."
        exit 1
    fi

    info "Installing CPython 3.13 via uv..."
    if ! uv python install 3.13; then
        err "uv python install 3.13 failed."
        if $UV_INSTALLED_BY_US; then
            warn "Rolling back uv install we just did..."
            "$HOME/.local/bin/uv" self uninstall >/dev/null 2>&1 || \
                rm -rf "$HOME/.local/share/uv" "$HOME/.local/bin/uv"
            UV_INSTALLED_BY_US=false
            rm -f "$INSTALL_DIR/.uv-installed-by-us" 2>/dev/null || true
        fi
        err "Try the Advanced menu → Homebrew option instead."
        exit 1
    fi
    UV_PYTHON_INSTALLED_BY_US=true
    write_marker_now "$INSTALL_DIR/.uv-python-installed-by-us"

    PYTHON_BIN="$(uv python find 3.13)"
    if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
        err "uv reported Python 3.13 install but couldn't resolve interpreter path."
        exit 1
    fi
    ok "uv-managed Python 3.13 ready: $PYTHON_BIN"
}

_clt_sigint_trap() {
    err "Interrupted. Re-run \`bash install.sh\` once the Xcode CLT dialog finishes."
    exit 130
}

ensure_xcode_clt() {
    if xcode-select -p >/dev/null 2>&1; then
        ok "Xcode Command Line Tools already present."
        return 0
    fi
    if $DRY_RUN; then
        info "WOULD: trigger 'xcode-select --install' and wait for completion"
        return 0
    fi
    info "Triggering Xcode Command Line Tools install (a macOS dialog will open)."
    xcode-select --install >/dev/null 2>&1 || true
    info "Waiting for Xcode Command Line Tools install to finish."
    info "Press Ctrl-C anytime if you'd rather come back later."
    trap _clt_sigint_trap INT
    local elapsed=0
    local max=300  # 5 minutes
    local next_progress=30
    while [ $elapsed -lt $max ]; do
        if xcode-select -p >/dev/null 2>&1; then
            trap - INT
            ok "Xcode Command Line Tools detected."
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        if [ $elapsed -ge $next_progress ]; then
            local mins=$((elapsed / 60))
            local secs=$((elapsed % 60))
            info "Still waiting... (${mins}m ${secs}s elapsed). The macOS dialog must complete before we continue."
            next_progress=$((next_progress + 30))
        fi
    done
    trap - INT
    err "Timed out after 5 minutes waiting for Xcode Command Line Tools."
    err "Re-run \`bash install.sh\` once the CLT install dialog completes."
    exit 1
}

ensure_homebrew() {
    if command -v brew >/dev/null 2>&1; then
        ok "Homebrew already installed."
        return 0
    fi
    if $DRY_RUN; then
        info "WOULD: install Homebrew via official non-interactive installer"
        HOMEBREW_INSTALLED_BY_US=true
        write_marker_now "$INSTALL_DIR/.homebrew-installed-by-us"
        return 0
    fi
    info "Installing Homebrew (non-interactive)..."
    if ! NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
        err "Network error. Check your connection and re-run \`bash install.sh\`."
        exit 1
    fi
    HOMEBREW_INSTALLED_BY_US=true
    write_marker_now "$INSTALL_DIR/.homebrew-installed-by-us"
    # Make brew reachable in this process.
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    if ! command -v brew >/dev/null 2>&1; then
        err "Homebrew installed but 'brew' not on PATH; aborting."
        exit 1
    fi
    ok "Homebrew installed."
}

homebrew_install_path() {
    ensure_xcode_clt
    ensure_homebrew
    if $DRY_RUN; then
        info "WOULD: brew install python@3.13"
        BREW_PYTHON_INSTALLED_BY_US=true
        write_marker_now "$INSTALL_DIR/.brew-python-installed-by-us"
        PYTHON_BIN="(homebrew python@3.13)"
        return 0
    fi
    info "Installing python@3.13 via Homebrew..."
    if ! brew install python@3.13; then
        err "Network error. Check your connection and re-run \`bash install.sh\`."
        exit 1
    fi
    BREW_PYTHON_INSTALLED_BY_US=true
    write_marker_now "$INSTALL_DIR/.brew-python-installed-by-us"
    ok "python@3.13 installed."
    discover_python
    if [ -z "${PYTHON_BIN:-}" ]; then
        err "Could not resolve Python 3.13 after brew install."
        exit 1
    fi
}

print_manual_commands() {
    cat <<'EOF'

Run these yourself, then re-run this script:

  xcode-select --install
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  brew install python@3.13

EOF
    exit 0
}

mac_advanced_menu() {
    cat <<'EOF'

Advanced options:

  [a] Homebrew + python@3.13
      Installs Apple's developer tools (~3 GB, opens a system dialog),
      then Homebrew, then Python 3.13. Best if you already plan to use brew.

  [b] Print manual commands and quit
      Just show me the commands.

  [c] Back

EOF
    local choice=""
    if [ -t 0 ] || [ -r /dev/tty ]; then
        printf '    Choice [a/b/c] (default c): '
        { read -r choice </dev/tty; } 2>/dev/null || choice=""
    else
        choice="c"
    fi
    choice="${choice:-c}"

    case "$choice" in
        a|A) homebrew_install_path ;;
        b|B) print_manual_commands ;;
        *)   mac_bootstrap_menu ;;
    esac
}

mac_bootstrap_menu() {
    cat <<'EOF'

No Python 3.10+ found. Choose:

  [1] Recommended — install uv (default)
      Small download (~30 MB). Sets up Python 3.13 just for Clippy.
      Doesn't touch your system Python or developer tools.

  [2] Advanced options
      Other ways to get Python (Homebrew, manual commands).

  [3] Quit

EOF
    local choice=""
    if $DRY_RUN; then
        info "WOULD: prompt for Python bootstrap (assuming default [1] uv)"
        choice="1"
    elif [ -t 0 ] || [ -r /dev/tty ]; then
        printf '    Choice [1/2/3] (default 1): '
        { read -r choice </dev/tty; } 2>/dev/null || choice=""
    else
        choice="3"
    fi
    choice="${choice:-1}"

    case "$choice" in
        1) uv_install_path ;;
        2) mac_advanced_menu ;;
        *)
            info "Install Python 3.10+ then re-run this script."
            exit 0
            ;;
    esac
}

if [ -z "${PYTHON_BIN:-}" ]; then
    if is_macos; then
        mac_bootstrap_menu
    else
        err "No Python 3.10+ found."
        err "Install Python 3.10+ via your package manager, then re-run this script."
        exit 1
    fi
fi

# In dry-run the bootstrap paths never install anything, so PYTHON_BIN holds a
# descriptive placeholder rather than a real path — don't try to execute it.
if $DRY_RUN && [ ! -x "$PYTHON_BIN" ]; then
    ok "Python would be: $PYTHON_BIN"
else
    py_version="$("$PYTHON_BIN" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
    ok "Python $py_version at $PYTHON_BIN"
fi

# -- Git / tarball ----------------------------------------------------------

INSTALLED_VIA_TARBALL=false
HAVE_GIT=false
if command -v git >/dev/null 2>&1; then
    HAVE_GIT=true
    [ "$LOCAL" = true ] || ok "git $(git --version | awk '{print $3}')"
fi

if [ "$LOCAL" = false ] && ! $HAVE_GIT; then
    if is_macos; then
        warn "git not found. Will fetch source via tarball (no .git history)."
        warn "Future updates will re-download the tarball; install git for incremental updates."
    else
        err "git not found. Install git and try again."
        exit 1
    fi
fi

# -- Tattoy detection -------------------------------------------------------

TATTOY_INSTALLED_BY_US=false
TATTOY_INSTALLED_VIA_BREW=false
TATTOY_INSTALLED_VIA_BINARY=false

bootstrap_cargo_macos() {
    # Returns 0 if cargo is now usable, 1 otherwise. Only call on macOS.
    if command -v cargo >/dev/null 2>&1; then
        return 0
    fi
    info "cargo (Rust) not found. Tattoy needs cargo to install."
    info "rustup toolchain ~280 MB, ~1 min. Run the official rustup installer?"
    if $DRY_RUN; then
        info "WOULD: prompt to install rustup (assume no — advanced path)"
        return 1
    fi
    local answer="n"
    printf '    Install rustup now? [y/N] '
    { read -r answer </dev/tty; } 2>/dev/null || true
    case "${answer:-n}" in
        [Yy]*) ;;
        *) return 1 ;;
    esac

    if ! curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --default-toolchain stable --profile minimal; then
        err "Network error. Check your connection and re-run \`bash install.sh\`."
        return 1
    fi
    if [ -f "$HOME/.cargo/env" ]; then
        # shellcheck disable=SC1091
        . "$HOME/.cargo/env"
    else
        export PATH="$HOME/.cargo/bin:$PATH"
    fi
    if ! command -v cargo >/dev/null 2>&1; then
        err "rustup installed but 'cargo' not on PATH."
        return 1
    fi
    CARGO_INSTALLED_BY_US=true
    write_marker_now "$INSTALL_DIR/.cargo-installed-by-us"
    ok "rustup + cargo installed."
    return 0
}

# Download prebuilt tattoy macOS binary from the latest GitHub release.
# Returns 0 on success (binary at ~/.local/bin/tattoy + marker written),
# 1 on failure (caller should fall through to manual instructions).
download_tattoy_binary() {
    local arch asset url tmp bin
    case "$(uname -m)" in
        arm64|aarch64) arch="aarch64" ;;
        x86_64)        arch="x86_64" ;;
        *) err "Unsupported architecture: $(uname -m)"; return 1 ;;
    esac
    asset="tattoy-${arch}-apple-darwin.tar.gz"
    url="https://github.com/tattoy-org/tattoy/releases/latest/download/${asset}"

    if $DRY_RUN; then
        info "WOULD: download $url"
        info "WOULD: verify ${asset}.sha256 checksum"
        info "WOULD: extract and copy tattoy to $HOME/.local/bin/tattoy"
        TATTOY_INSTALLED_VIA_BINARY=true
        write_marker_now "$INSTALL_DIR/.tattoy-installed-via-binary"
        return 0
    fi

    info "Downloading $asset..."
    tmp="$(mktemp -d)"
    if ! curl -fsSL "$url" -o "$tmp/$asset"; then
        rm -rf "$tmp"
        err "Network error. Check your connection and re-run \`bash install.sh\`."
        return 1
    fi
    if ! curl -fsSL "${url}.sha256" -o "$tmp/${asset}.sha256"; then
        rm -rf "$tmp"
        err "Network error fetching checksum. Check your connection and re-run \`bash install.sh\`."
        return 1
    fi
    if ! ( cd "$tmp" && shasum -a 256 -c "${asset}.sha256" >/dev/null 2>&1 ); then
        rm -rf "$tmp"
        err "Checksum mismatch — download may be corrupt."
        return 1
    fi
    if ! tar -xzf "$tmp/$asset" -C "$tmp"; then
        rm -rf "$tmp"
        err "Extract failed."
        return 1
    fi
    bin="$(find "$tmp" -name tattoy -type f | head -1)"
    if [ -z "$bin" ]; then
        rm -rf "$tmp"
        err "tattoy binary not in archive."
        return 1
    fi

    mkdir -p "$HOME/.local/bin"
    cp "$bin" "$HOME/.local/bin/tattoy"
    chmod +x "$HOME/.local/bin/tattoy"
    rm -rf "$tmp"
    TATTOY_INSTALLED_VIA_BINARY=true
    write_marker_now "$INSTALL_DIR/.tattoy-installed-via-binary"
    ok "tattoy installed to ~/.local/bin/tattoy"
    return 0
}

# Install tattoy via brew tap. Returns 0 on success, 1 on failure.
install_tattoy_via_brew() {
    if $DRY_RUN; then
        info "WOULD: brew install tattoy-org/tap/tattoy"
        TATTOY_INSTALLED_VIA_BREW=true
        write_marker_now "$INSTALL_DIR/.tattoy-installed-via-brew"
        return 0
    fi
    info "Running: brew install tattoy-org/tap/tattoy"
    if brew install tattoy-org/tap/tattoy; then
        TATTOY_INSTALLED_VIA_BREW=true
        write_marker_now "$INSTALL_DIR/.tattoy-installed-via-brew"
        ok "tattoy installed via Homebrew"
        return 0
    fi
    err "brew install failed."
    return 1
}

# Recommended tattoy install path — brew if available, else binary.
tattoy_recommended_path() {
    if command -v brew >/dev/null 2>&1; then
        if install_tattoy_via_brew; then
            return 0
        fi
        warn "Homebrew install failed; falling back to prebuilt binary."
    fi
    if download_tattoy_binary; then
        return 0
    fi
    return 1
}

# Cargo-build path (advanced).
tattoy_cargo_path() {
    local have_cargo=false
    if command -v cargo >/dev/null 2>&1; then
        have_cargo=true
    elif is_macos; then
        if bootstrap_cargo_macos; then
            have_cargo=true
        fi
    fi
    if ! $have_cargo; then
        info "cargo not available. Install tattoy manually:"
        info "  https://tattoy.sh"
        return 1
    fi
    if $DRY_RUN; then
        info "WOULD: cargo install tattoy"
        TATTOY_INSTALLED_BY_US=true
        write_marker_now "$INSTALL_DIR/.tattoy-installed-by-us"
        return 0
    fi
    info "Running: cargo install tattoy"
    if cargo install tattoy; then
        ok "tattoy installed"
        TATTOY_INSTALLED_BY_US=true
        write_marker_now "$INSTALL_DIR/.tattoy-installed-by-us"
        return 0
    fi
    warn "cargo install tattoy failed; you can retry later."
    return 1
}

tattoy_advanced_menu() {
    cat <<'EOF'

Advanced tattoy install options:

  [a] Build from source via cargo
      Requires Rust. Slower (~1 min), uses more disk.
      If cargo isn't installed, this will offer to install rustup.
  [b] Print install commands and quit
      I'll handle it myself.
  [c] Back

EOF
    local choice=""
    if $DRY_RUN; then
        info "WOULD: prompt for tattoy advanced (assume [c] back)"
        choice="c"
    elif [ -t 0 ] || [ -r /dev/tty ]; then
        printf '    Choice [a/b/c] (default c): '
        { read -r choice </dev/tty; } 2>/dev/null || choice=""
    else
        choice="c"
    fi
    choice="${choice:-c}"

    case "$choice" in
        a|A) tattoy_cargo_path || true ;;
        b|B)
            cat <<'EOF'

Install tattoy yourself with one of:

  brew install tattoy-org/tap/tattoy
  cargo install tattoy

Or grab the prebuilt binary:
  https://github.com/tattoy-org/tattoy/releases/latest

Then re-run `bash install.sh`.

EOF
            exit 0
            ;;
        *) tattoy_menu ;;
    esac
}

tattoy_menu() {
    cat <<'EOF'

tattoy not found. tattoy is the terminal compositor that runs the live
effects when you launch `clippy`.  (You can still try `clippy --demo fire`
without it — demo mode runs standalone.)

  [1] Recommended — install tattoy automatically (default)
      Uses Homebrew if available, otherwise downloads the official
      prebuilt binary. No compiling, no Rust toolchain.

  [2] Advanced options
      Build from source, or skip and install yourself.

  [3] Skip — install it later

EOF
    local choice=""
    if $DRY_RUN; then
        info "WOULD: prompt for tattoy install (assume default [1] recommended)"
        choice="1"
    elif [ -t 0 ] || [ -r /dev/tty ]; then
        printf '    Choice [1/2/3] (default 1): '
        { read -r choice </dev/tty; } 2>/dev/null || choice=""
    else
        choice="3"
    fi
    choice="${choice:-1}"

    case "$choice" in
        1)
            if ! tattoy_recommended_path; then
                warn "Couldn't install tattoy automatically. Install it later:"
                info "  https://tattoy.sh"
            fi
            ;;
        2) tattoy_advanced_menu ;;
        *)
            info "Skipping tattoy install. You can install it later:"
            info "  brew install tattoy-org/tap/tattoy"
            info "  or visit https://tattoy.sh"
            ;;
    esac
}

tattoy_bin=""
if command -v tattoy &>/dev/null; then
    tattoy_bin="$(command -v tattoy)"
elif [ -x "$HOME/.cargo/bin/tattoy" ]; then
    tattoy_bin="$HOME/.cargo/bin/tattoy"
elif [ -x "$HOME/.local/bin/tattoy" ]; then
    tattoy_bin="$HOME/.local/bin/tattoy"
fi

if [ -n "$tattoy_bin" ]; then
    ok "tattoy found at $tattoy_bin"
elif is_macos; then
    warn "tattoy not found (needed at runtime, not for install)."
    tattoy_menu
else
    # Linux: keep existing cargo-only flow (no brew tap parity yet).
    warn "tattoy not found (needed at runtime, not for install)."
    if command -v cargo >/dev/null 2>&1; then
        if $DRY_RUN; then
            info "WOULD: prompt to cargo install tattoy (assume yes)"
            info "WOULD: cargo install tattoy"
            TATTOY_INSTALLED_BY_US=true
            write_marker_now "$INSTALL_DIR/.tattoy-installed-by-us"
        else
            answer="n"
            printf '    Install tattoy via cargo? [Y/n] '
            { read -r answer </dev/tty; } 2>/dev/null || true
            case "${answer:-y}" in
                [Yy]*)
                    info "Running: cargo install tattoy"
                    if cargo install tattoy; then
                        ok "tattoy installed"
                        TATTOY_INSTALLED_BY_US=true
                        write_marker_now "$INSTALL_DIR/.tattoy-installed-by-us"
                    else
                        warn "cargo install tattoy failed; you can retry later."
                    fi
                    ;;
                *)
                    info "Skipping tattoy install. You can install it later:"
                    info "  cargo install tattoy"
                    info "  or visit https://tattoy.sh"
                    ;;
            esac
        fi
    else
        info "Install tattoy before running clippy:"
        info "  https://tattoy.sh"
    fi
fi

# -- Project installation ---------------------------------------------------

# Several install paths below rm -rf $INSTALL_DIR. Ownership markers recorded by
# an earlier run must survive that, or uninstall can no longer offer to clean up
# tooling we installed (the tool is already present, so this run won't re-set the
# flag). Snapshot them now; restored just before the marker block below.
MARKER_BACKUP=""
if [ -d "$INSTALL_DIR" ] && ! $DRY_RUN; then
    MARKER_BACKUP="$(mktemp -d)"
    for _m in "$INSTALL_DIR"/.*-installed-by-us "$INSTALL_DIR"/.*-installed-via-*; do
        [ -f "$_m" ] || continue
        cp "$_m" "$MARKER_BACKUP/"
    done
fi

run_or_dry mkdir -p "$(dirname "$INSTALL_DIR")"

if [ "$LOCAL" = true ]; then
    info "Installing from local source: $SCRIPT_DIR"
    if [ -d "$INSTALL_DIR" ]; then
        if $DRY_RUN; then
            info "WOULD: rm -rf $INSTALL_DIR (existing install dir)"
        elif ! rm -rf "$INSTALL_DIR"; then
            err "Cannot remove $INSTALL_DIR (permission denied)."
            err "Try: sudo rm -rf $INSTALL_DIR"
            exit 1
        fi
    fi
    if $DRY_RUN; then
        info "WOULD: cp -r $SCRIPT_DIR $INSTALL_DIR"
    elif ! cp -r "$SCRIPT_DIR" "$INSTALL_DIR"; then
        err "Failed to copy files to $INSTALL_DIR."
        exit 1
    fi
    # Remove .git so a later normal install sees a clean slate and re-clones
    run_or_dry rm -rf "$INSTALL_DIR/.git"
    ok "Copied local files"
elif $HAVE_GIT && [ -d "$INSTALL_DIR/.git" ]; then
    info "Updating existing install..."
    if $DRY_RUN; then
        info "WOULD: git -C $INSTALL_DIR pull --ff-only"
    elif ! git -C "$INSTALL_DIR" pull --ff-only; then
        err "Network error. Check your connection and re-run \`bash install.sh\`."
        err "If this is a permissions issue, uninstall and re-install:"
        err "  sudo bash $INSTALL_DIR/uninstall.sh"
        err "  bash install.sh"
        exit 1
    fi
elif $HAVE_GIT; then
    if [ -d "$INSTALL_DIR" ]; then
        warn "Removing stale install dir (not a git repo)..."
        if $DRY_RUN; then
            info "WOULD: rm -rf $INSTALL_DIR"
        elif ! rm -rf "$INSTALL_DIR"; then
            err "Cannot remove $INSTALL_DIR (permission denied)."
            err "Try: sudo rm -rf $INSTALL_DIR"
            exit 1
        fi
    fi
    info "Cloning Clippy's Revenge..."
    if $DRY_RUN; then
        info "WOULD: git clone $REPO_URL $INSTALL_DIR"
    elif ! git clone "$REPO_URL" "$INSTALL_DIR"; then
        err "Network error. Check your connection and re-run \`bash install.sh\`."
        exit 1
    fi
else
    # Tarball fallback (macOS without git).
    if [ -d "$INSTALL_DIR" ]; then
        warn "Removing existing install dir..."
        run_or_dry rm -rf "$INSTALL_DIR"
    fi
    info "Downloading source tarball..."
    if $DRY_RUN; then
        info "WOULD: curl $TARBALL_URL | tar -xzC <tmp> && mv <tmp> $INSTALL_DIR"
        INSTALLED_VIA_TARBALL=true
    else
        tmp="$(mktemp -d)"
        if ! curl -fsSL "$TARBALL_URL" | tar -xzC "$tmp"; then
            err "Network error. Check your connection and re-run \`bash install.sh\`."
            rm -rf "$tmp"
            exit 1
        fi
        mv "$tmp/Clippys-Revenge-main" "$INSTALL_DIR"
        rm -rf "$tmp"
        INSTALLED_VIA_TARBALL=true
        ok "Source extracted to $INSTALL_DIR"
    fi
fi

# -- Persist interpreter path + markers -------------------------------------

# Restore markers from a previous install before layering this run's on top.
if [ -n "$MARKER_BACKUP" ]; then
    for _m in "$MARKER_BACKUP"/.*-installed-by-us "$MARKER_BACKUP"/.*-installed-via-*; do
        [ -f "$_m" ] || continue
        cp "$_m" "$INSTALL_DIR/"
    done
    rm -rf "$MARKER_BACKUP"
fi

# .python-bin is the source of truth for bin/clippy at runtime.
write_file "$INSTALL_DIR/.python-bin" "$PYTHON_BIN"

if $UV_INSTALLED_BY_US; then
    write_marker "$INSTALL_DIR/.uv-installed-by-us"
fi
if $UV_PYTHON_INSTALLED_BY_US; then
    write_marker "$INSTALL_DIR/.uv-python-installed-by-us"
fi
if $TATTOY_INSTALLED_BY_US; then
    write_marker "$INSTALL_DIR/.tattoy-installed-by-us"
fi
if $TATTOY_INSTALLED_VIA_BREW; then
    write_marker "$INSTALL_DIR/.tattoy-installed-via-brew"
fi
if $TATTOY_INSTALLED_VIA_BINARY; then
    write_marker "$INSTALL_DIR/.tattoy-installed-via-binary"
fi
if $CARGO_INSTALLED_BY_US; then
    write_marker "$INSTALL_DIR/.cargo-installed-by-us"
fi
if $HOMEBREW_INSTALLED_BY_US; then
    write_marker "$INSTALL_DIR/.homebrew-installed-by-us"
fi
if $BREW_PYTHON_INSTALLED_BY_US; then
    write_marker "$INSTALL_DIR/.brew-python-installed-by-us"
fi
if $INSTALLED_VIA_TARBALL; then
    write_marker "$INSTALL_DIR/.installed-via-tarball"
fi

# -- Mark executables -------------------------------------------------------

if $DRY_RUN; then
    info "WOULD: chmod +x $INSTALL_DIR/bin/clippy and effect plugins"
else
    if ! chmod +x "$INSTALL_DIR/bin/clippy"; then
        err "Cannot set executable permissions on $INSTALL_DIR/bin/clippy."
        err "If a previous install was run with sudo, uninstall first:"
        err "  sudo bash $INSTALL_DIR/uninstall.sh"
        err "  bash install.sh"
        exit 1
    fi
    if [ -f "$INSTALL_DIR/bin/clippy-uninstall" ]; then
        chmod +x "$INSTALL_DIR/bin/clippy-uninstall" || true
    fi
    for f in "$INSTALL_DIR"/clippy/effects/*.py; do
        [ -f "$f" ] && chmod +x "$f"
    done
fi

# -- Symlinks ---------------------------------------------------------------

run_or_dry mkdir -p "$BIN_DIR"
if $DRY_RUN; then
    info "WOULD: ln -sf $INSTALL_DIR/bin/clippy $BIN_DIR/clippy"
elif ! ln -sf "$INSTALL_DIR/bin/clippy" "$BIN_DIR/clippy"; then
    err "Cannot create symlink at $BIN_DIR/clippy (permission denied)."
    err "Check permissions on $BIN_DIR."
    exit 1
else
    ok "Symlinked $BIN_DIR/clippy"
fi

if $DRY_RUN; then
    info "WOULD: ln -sf $INSTALL_DIR/bin/clippy-uninstall $BIN_DIR/clippy-uninstall (if present)"
elif [ -f "$INSTALL_DIR/bin/clippy-uninstall" ]; then
    if ln -sf "$INSTALL_DIR/bin/clippy-uninstall" "$BIN_DIR/clippy-uninstall"; then
        ok "Symlinked $BIN_DIR/clippy-uninstall"
    else
        warn "Could not create symlink at $BIN_DIR/clippy-uninstall."
    fi
fi

# -- PATH check -------------------------------------------------------------

PATH_ON_PATH=true
RC_FILE_WRITTEN=""

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        PATH_ON_PATH=false
        warn "$BIN_DIR is not on your PATH."
        rc_file=""
        export_line='export PATH="$HOME/.local/bin:$PATH"'
        case "$(basename "${SHELL:-/bin/bash}")" in
            zsh)
                rc_file="$HOME/.zshrc"
                ;;
            bash)
                rc_file="$HOME/.bashrc"
                ;;
            fish)
                rc_file="$HOME/.config/fish/config.fish"
                export_line='set -gx PATH "$HOME/.local/bin" $PATH'
                ;;
            *)
                ;;
        esac

        if [ -z "$rc_file" ]; then
            info "Add this line to your shell's startup config:"
            info "  $export_line"
            info "  (couldn't auto-detect config file for shell: $(basename "${SHELL:-unknown}"))"
        else
            if $DRY_RUN; then
                info "WOULD: append PATH export to $rc_file"
                RC_FILE_WRITTEN="$rc_file"
            else
                if [ -t 0 ] || [ -r /dev/tty ]; then
                    answer=""
                    printf '    Add to %s? [Y/n] ' "$rc_file"
                    { read -r answer </dev/tty; } 2>/dev/null || true
                else
                    answer="n"
                fi
                case "${answer:-y}" in
                    [Yy]*)
                        # fish needs config dir to exist
                        mkdir -p "$(dirname "$rc_file")"
                        printf '\n# Added by Clippy'\''s Revenge installer\n%s\n' "$export_line" >> "$rc_file"
                        ok "Added to $rc_file"
                        RC_FILE_WRITTEN="$rc_file"
                        ;;
                    *)
                        info "Add this to your shell profile ($rc_file):"
                        info "  $export_line"
                        ;;
                esac
            fi
        fi
        ;;
esac

# -- Done -------------------------------------------------------------------

echo ""
if $DRY_RUN; then
    ok "Dry-run complete — no changes written."
else
    ok "Clippy's Revenge installed!"
fi
echo ""
info "Usage:"
info "  clippy --demo fire           # try it now (no tattoy needed)"
info "  clippy                       # launch with all effects"
info "  clippy --list                # list available effects"
info "  clippy --effects fire,grove  # limit Clippy to specific effects"
info "  clippy -- vim                # wrap a specific command"
echo ""

# Rust acceleration note. The launcher auto-builds the optional native
# module on first run if cargo is on PATH.
if $CARGO_INSTALLED_BY_US; then
    info "Bonus: that Rust toolchain you just got also gives Clippy faster animations on first launch."
elif $HAVE_CARGO_AT_START; then
    info "Rust detected — Clippy will compile its native acceleration module"
    info "  on first run for smoother animations. (Happens automatically.)"
else
    info "Tip: installing Rust (https://rustup.rs) unlocks a small animation"
    info "  speedup. Totally optional."
fi
echo ""

if ! $PATH_ON_PATH; then
    info "Try it now (works in this shell):"
    info "  ~/.local/bin/clippy --demo fire"
    echo ""
    if [ -n "$RC_FILE_WRITTEN" ]; then
        info "To use plain \`clippy\` in this shell right now:"
        info "  source $RC_FILE_WRITTEN"
        info "Or restart your shell:"
        info "  exec \$SHELL -l"
    else
        info "After your next shell restart, plain \`clippy\` will work."
        info "Or restart now:  exec \$SHELL -l"
    fi
    echo ""
fi

info "Uninstall:  clippy-uninstall   (or: bash $INSTALL_DIR/uninstall.sh)"
