#!/usr/bin/env bash
# zode installer - installs the latest release binary
# Usage: curl -fsSL https://raw.githubusercontent.com/jesusalcaladev/zode/main/install.sh | bash
#        or: curl -fsSL https://raw.githubusercontent.com/jesusalcaladev/zode/main/install.sh | bash -s -- --version v0.1.0

set -euo pipefail

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
            VERSION="$2"
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
            INSTALL_DIR="$2"
            shift 2
            ;;
        --help|-h)
            cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --version, -v VERSION    Install specific version (default: latest)
  --force, -f              Force reinstall even if same version
  --verbose                Verbose output
  --install-dir DIR        Installation directory (default: ~/.local/bin)
  --help, -h               Show this help

Environment:
  INSTALL_DIR              Same as --install-dir

Examples:
  $0                       # Install latest release
  $0 --version v0.1.0      # Install specific version
  $0 --force               # Force reinstall latest
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
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_verbose() { [[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $*"; }

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
        log_error "Failed to fetch latest release info"
        exit 1
    }
    echo "$response" | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4
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
    url=$(echo "$response" | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 | grep "$asset_name" | head -1)

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

    # Create install directory
    mkdir -p "$INSTALL_DIR"

    log_verbose "Downloading from $url"
    local tmp_file
    tmp_file=$(mktemp)
    trap 'rm -f "$tmp_file"' EXIT

    if ! curl -fL# "$url" -o "$tmp_file"; then
        log_error "Failed to download binary"
        exit 1
    fi

    # Verify it's an executable
    if ! file "$tmp_file" | grep -q "executable"; then
        log_error "Downloaded file is not an executable"
        exit 1
    fi

    chmod +x "$tmp_file"

    # Atomic install: write to temp then rename
    local tmp_install
    tmp_install=$(mktemp "$INSTALL_DIR/.${BINARY_NAME}.XXXXXX")
    mv "$tmp_file" "$tmp_install"
    mv "$tmp_install" "$binary_path"

    log_success "Installed zode to $binary_path"
}

# Add to PATH if needed
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

    local platform
    platform=$(detect_platform)
    log_verbose "Platform: $platform"

    if [[ -z "$VERSION" ]]; then
        VERSION=$(get_latest_version)
        log_info "Latest version: $VERSION"
    else
        log_info "Requested version: $VERSION"
    fi

    # Check if already installed
    if check_existing "$VERSION"; then
        check_path
        exit 0
    fi

    local asset_url
    asset_url=$(get_asset_url "$VERSION" "$platform")
    log_verbose "Asset URL: $asset_url"

    install_binary "$asset_url"
    check_path

    # Verify installation
    local installed_version
    installed_version=$("$INSTALL_DIR/$BINARY_NAME" --version 2>/dev/null | head -1) || {
        log_warn "Could not verify installation"
        exit 0
    }
    log_success "$installed_version"
}

main "$@"