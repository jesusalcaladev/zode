#!/usr/bin/env bash
# zode installer - installs the latest release binary
# Usage: curl -fsSL https://raw.githubusercontent.com/jesusalcaladev/zode/main/install.sh | bash
#        or: curl -fsSL https://raw.githubusercontent.com/jesusalcaladev/zode/main/install.sh | bash -s -- --version v0.1.0

set -euo pipefail

# `$0` is just "bash" when the script arrives through a pipe, so the usage
# text names the script instead of the shell that happens to run it.
PROG="install.sh"

# Configuration
REPO="jesusalcaladev/zode"
BINARY_NAME="zode"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
GITHUB_API="https://api.github.com/repos/${REPO}"
GITHUB_RELEASES="https://github.com/${REPO}/releases"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
VERSION=""
FORCE=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --version|-v)
            VERSION="${2:-}"
            [[ -n "$VERSION" ]] || { echo "--version needs a value (e.g. --version v0.1.0)" >&2; exit 1; }
            shift 2
            ;;
        --force|-f)
            FORCE=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --install-dir)
            INSTALL_DIR="${2:-}"
            [[ -n "$INSTALL_DIR" ]] || { echo "--install-dir needs a path" >&2; exit 1; }
            shift 2
            ;;
        --help|-h)
            # shellcheck disable=SC2016 # the examples are literal
            cat <<EOF
Usage: $PROG [OPTIONS]

Options:
  --version, -v VERSION    Install specific version (default: latest)
  --force, -f              Force reinstall even if same version
  --verbose                Verbose output
  --install-dir DIR        Installation directory (default: ~/.local/bin)
  --help, -h               Show this help

Environment:
  INSTALL_DIR              Same as --install-dir

Examples:
  $PROG                       # Install latest release
  $PROG --version v0.1.0      # Install specific version
  $PROG --force               # Force reinstall latest
EOF
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}" >&2
            exit 1
            ;;
    esac
done

# Logging functions
#
# `log_verbose` MUST return 0 when it prints nothing. It used to end in
# `[[ ... ]] && echo ...`, so under `set -e` the first verbose line that was
# skipped (i.e. every run without `--verbose`) killed the whole installer — it
# printed `[INFO] zode installer`, stopped, and left no error behind. An `if`
# has no such trap: a false condition inside it is not a failing command.
log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_verbose() { if [[ "$VERBOSE" == "true" ]]; then echo -e "${BLUE}[DEBUG]${NC} $*" >&2; fi; }

# Detect platform
detect_platform() {
    local os arch
    case "$(uname -s)" in
        Linux*) os="linux" ;;
        Darwin*) os="macos" ;;
        *) log_error "Unsupported OS: $(uname -s)"; exit 1 ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) log_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac

    echo "${os}-${arch}"
}

# Get latest release version from GitHub API
get_latest_version() {
    log_verbose "Fetching latest release from $GITHUB_API/releases/latest"
    local response
    response=$(curl -fsSL "$GITHUB_API/releases/latest" 2>/dev/null) || {
        log_error "Failed to fetch latest release info (network, or GitHub rate limit)"
        exit 1
    }
    # `|| true` on the pipeline: with `set -e` + `pipefail`, a response with no
    # `tag_name` (a rate-limit JSON, an empty body) made this function return 1
    # and the CALLER died silently, before the empty check below could speak.
    local tag
    tag=$(echo "$response" | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4 || true)
    if [[ -z "$tag" ]]; then
        log_error "GitHub answered without a release tag (rate limited?) — try again in a minute"
        exit 1
    fi
    echo "$tag"
}

# Get release asset URL for platform
get_asset_url() {
    local version="$1"
    local platform="$2"

    log_verbose "Fetching release assets for $version"
    local response
    response=$(curl -fsSL "$GITHUB_API/releases/tags/$version" 2>/dev/null) || {
        log_error "Failed to fetch release $version"
        exit 1
    }

    # Find matching asset: zode-{platform}
    local asset_name="${BINARY_NAME}-${platform}"
    local url
    # `|| true` for the same reason as in `get_latest_version`: the empty check
    # below is the one that has to speak, and `set -e` was exiting before it.
    url=$(echo "$response" | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 | grep "$asset_name" | head -1 || true)

    if [[ -z "$url" ]]; then
        log_error "No binary found for platform: $platform"
        log_verbose "Available assets:"
        echo "$response" | grep -o '"name": *"[^"]*"' | cut -d'"' -f4
        exit 1
    fi

    echo "$url"
}

# Check if already installed with same version
check_existing() {
    local version="$1"
    local binary_path="$INSTALL_DIR/$BINARY_NAME"

    if [[ -x "$binary_path" ]]; then
        local current_version
        current_version=$("$binary_path" --version 2>/dev/null | head -1 | awk '{print $2}') || current_version="unknown"

        if [[ "$current_version" == "$version" && "$FORCE" != "true" ]]; then
            log_info "zode $version is already installed at $binary_path"
            return 0
        fi
        log_info "Upgrading zode from $current_version to $version"
    fi
    return 1
}

# Download and install binary
install_binary() {
    local url="$1"
    local binary_path="$INSTALL_DIR/$BINARY_NAME"
    local asset_name
    asset_name=$(basename "$url")

    # Create install directory
    mkdir -p "$INSTALL_DIR"

    log_info "downloading $asset_name"
    log_verbose "Downloading from $url"
    local tmp_file
    tmp_file=$(mktemp)

    if ! curl -fL# "$url" -o "$tmp_file"; then
        rm -f "$tmp_file"
        log_error "Failed to download binary from $url"
        exit 1
    fi

    # Verify it's an executable. `file` is not present on every minimal
    # system, and when it was missing this said "not an executable" about a
    # perfectly good download. The real check is whether it RUNS, below.
    if command -v file >/dev/null 2>&1; then
        if ! file "$tmp_file" | grep -q "executable"; then
            rm -f "$tmp_file"
            log_error "Downloaded file is not an executable"
            exit 1
        fi
    fi

    chmod +x "$tmp_file"

    # The one check that catches a binary built for another machine. A release
    # compiled with the CI runner's CPU (SHA-NI, AVX-512) dies with SIGILL on
    # an older one, and the crash is at startup, NOT in `--version`.
    if ! "$tmp_file" --version >/dev/null 2>&1; then
        rm -f "$tmp_file"
        log_error "the downloaded binary does not run on this machine (wrong architecture or CPU)"
        log_error "report it: https://github.com/${REPO}/issues"
        exit 1
    fi

    # Atomic install: write to temp then rename
    local tmp_install
    tmp_install=$(mktemp "$INSTALL_DIR/.${BINARY_NAME}.XXXXXX")
    mv "$tmp_file" "$tmp_install"
    mv "$tmp_install" "$binary_path"

    log_success "installed $binary_path"
}

# Add to PATH if needed - automatically update shell config
ensure_path() {
    if [[ ":$PATH:" == *":$INSTALL_DIR:"* ]]; then
        return 0
    fi
    
    local shell_name
    # `${SHELL:-}`: with `set -u`, an environment without SHELL (a container,
    # `env -i`, some CI shells) killed the installer right before the last step.
    shell_name=$(basename "${SHELL:-/bin/bash}")
    local config_file=""
    local export_line="export PATH=\"\$PATH:$INSTALL_DIR\""
    
    case "$shell_name" in
        bash)
            config_file="$HOME/.bashrc"
            ;;
        zsh)
            config_file="$HOME/.zshrc"
            ;;
        fish)
            config_file="$HOME/.config/fish/config.fish"
            export_line="set -gx PATH \$PATH $INSTALL_DIR"
            ;;
        *)
            # Default to .profile for other shells
            config_file="$HOME/.profile"
            ;;
    esac
    
    # Create config file if it doesn't exist
    [[ -f "$config_file" ]] || touch "$config_file"
    
    # Check if already in config
    if grep -q "$INSTALL_DIR" "$config_file" 2>/dev/null; then
        log_info "PATH already configured in $config_file"
        return 0
    fi
    
    # Add to config
    echo "" >> "$config_file"
    echo "# Added by zode installer" >> "$config_file"
    echo "$export_line" >> "$config_file"
    
    log_success "Added $INSTALL_DIR to PATH in $config_file"
    log_info "Run 'source $config_file' or restart your shell to use zode"
}

# Legacy check_path for backwards compat
check_path() {
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        log_warn "$INSTALL_DIR is not in your PATH"
        log_warn "Add this to your shell config (~/.bashrc, ~/.zshrc, etc.):"
        echo "  export PATH=\"\$PATH:$INSTALL_DIR\""
    fi
}

# Main
main() {
    log_info "zode installer"

    # curl is the whole installer; saying so beats "command not found" halfway.
    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required and was not found"
        exit 1
    fi

    local platform
    platform=$(detect_platform)
    log_info "platform: $platform"

    if [[ -z "$VERSION" ]]; then
        VERSION=$(get_latest_version)
        log_info "latest version: $VERSION"
    else
        log_info "requested version: $VERSION"
    fi

    # Check if already installed
    if check_existing "$VERSION"; then
        ensure_path
        log_success "nothing to do"
        exit 0
    fi

    local asset_url
    asset_url=$(get_asset_url "$VERSION" "$platform")
    log_verbose "Asset URL: $asset_url"

    install_binary "$asset_url"
    ensure_path

    # Verify installation
    local installed_version
    installed_version=$("$INSTALL_DIR/$BINARY_NAME" --version 2>/dev/null | head -1) || {
        log_warn "Could not verify the installed binary"
        exit 0
    }
    log_success "$installed_version is ready — run 'zode' to start"
}

main "$@"
