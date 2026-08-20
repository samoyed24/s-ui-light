#!/bin/sh
#
# install.sh — Install s-ui on Alpine Linux or Debian/Ubuntu
#
# Auto-detects the OS (Alpine → OpenRC, Debian/Ubuntu → systemd) and the
# architecture. Downloads binaries from GitHub Releases (no git needed).
#
# Usage:
#   ./install.sh [OPTIONS]
#
# Options:
#   --repo <user/repo>  GitHub repo (default: samoyed24/alpine-s-ui-light)
#   --arch <arch>       Force architecture (amd64|arm64). Auto-detected by default.
#   --install-dir <dir> Installation directory. Default: /usr/local/s-ui
#   --version <ver>     Specific version to install (default: latest)
#   --uninstall         Remove s-ui and its service
#   -h, --help          Show this help
#
# Examples:
#   ./install.sh
#   ./install.sh --arch arm64
#   ./install.sh --repo myuser/myrepo --version v1.4.2
#   ./install.sh --uninstall

set -e

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info()  { printf "${GREEN}[INF]${NC} %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WRN]${NC} %s\n" "$*"; }
log_error() { printf "${RED}[ERR]${NC} %s\n" "$*"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO="samoyed24/alpine-s-ui-light"
INSTALL_DIR="/usr/local/s-ui"
DATA_DIR="/etc/s-ui"
LOG_FILE="/var/log/s-ui.log"
INIT_SCRIPT="/etc/init.d/s-ui"
SERVICE_FILE="/etc/systemd/system/s-ui.service"
OS=""
ARCH=""
VERSION="latest"
UNINSTALL=false

# ── Parse arguments ───────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)        REPO="$2"; shift 2 ;;
        --arch)        ARCH="$2"; shift 2 ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --version)     VERSION="$2"; shift 2 ;;
        --uninstall)   UNINSTALL=true; shift ;;
        -h|--help)
            sed -n '3,/^$/s/^# \?//p' "$0"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ── Root check ────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

# ── Detect OS ─────────────────────────────────────────────────────────────────
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            alpine)            OS="alpine" ;;
            debian|ubuntu)     OS="debian" ;;
            *)
                log_error "Unsupported OS: $ID"
                log_error "Supported: alpine, debian, ubuntu"
                exit 1
                ;;
        esac
    else
        log_error "Cannot detect OS (/etc/os-release not found)"
        exit 1
    fi
    log_info "Detected OS: $OS"
}

# ── Detect architecture ───────────────────────────────────────────────────────
detect_arch() {
    if [ -n "$ARCH" ]; then
        case "$ARCH" in
            amd64|arm64) ;;
            *) log_error "Unsupported architecture: $ARCH (use amd64 or arm64)"; exit 1 ;;
        esac
        return
    fi

    MACHINE=$(uname -m)
    case "$MACHINE" in
        x86_64|amd64)   ARCH="amd64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        *)
            log_error "Unsupported architecture: $MACHINE"
            log_error "Use --arch amd64|arm64 to force"
            exit 1
            ;;
    esac
    log_info "Detected architecture: $ARCH ($MACHINE)"
}

# ── Check dependencies ────────────────────────────────────────────────────────
check_deps() {
    case "$OS" in
        alpine)
            local need_wget=false need_openrc=false

            command -v wget >/dev/null 2>&1 || need_wget=true
            command -v rc-service >/dev/null 2>&1 || command -v rc-update >/dev/null 2>&1 || need_openrc=true

            if $need_wget || $need_openrc; then
                local packages=""
                $need_wget && packages="$packages wget"
                $need_openrc && packages="$packages openrc"

                log_info "Installing missing dependencies:$packages"
                apk add --no-cache $packages
                if [ $? -ne 0 ]; then
                    log_error "Failed to install dependencies. Run manually: apk add$packages"
                    exit 1
                fi
                log_info "Dependencies installed successfully"
            fi
            ;;
        debian)
            if ! command -v wget >/dev/null 2>&1; then
                log_info "Installing missing dependency: wget"
                apt-get update -qq
                apt-get install -y -qq wget
                if [ $? -ne 0 ]; then
                    log_error "Failed to install wget. Run manually: apt-get install -y wget"
                    exit 1
                fi
                log_info "Dependencies installed successfully"
            fi
            ;;
    esac
}

# ── Get version ───────────────────────────────────────────────────────────────
get_version() {
    if [ "$VERSION" = "latest" ]; then
        VERSION=$(wget -qO- "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | head -1 | sed 's/.*: "//;s/".*//')
        if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
            log_error "Failed to fetch latest version from GitHub"
            exit 1
        fi
    fi
    log_info "Target version: $VERSION"
}

# ── Download files ────────────────────────────────────────────────────────────
download_files() {
    local base_url="https://github.com/$REPO/releases/download/$VERSION"

    log_info "Downloading s-ui $VERSION ($ARCH)..."
    log_info "URL base: $base_url"

    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR"

    # Download main binary (with arch suffix)
    log_info "Downloading sui-$ARCH..."
    wget -q --show-progress -O "$INSTALL_DIR/sui" "$base_url/sui-$ARCH" || {
        log_error "Failed to download sui-$ARCH. Check if version $VERSION exists"
        exit 1
    }
    chmod +x "$INSTALL_DIR/sui"

    # Download optional management script
    log_info "Downloading s-ui-$ARCH.sh..."
    wget -q -O "$INSTALL_DIR/s-ui.sh" "$base_url/s-ui-$ARCH.sh" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/s-ui.sh" 2>/dev/null || true

    # Save version
    echo "$VERSION" > "$INSTALL_DIR/version.txt"

    log_info "Installed s-ui $VERSION ($ARCH) to $INSTALL_DIR"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
do_uninstall() {
    log_info "Uninstalling s-ui..."

    case "$OS" in
        alpine)
            if rc-service s-ui status >/dev/null 2>&1; then
                rc-service s-ui stop 2>/dev/null || true
            fi
            rc-update del s-ui default 2>/dev/null || true
            rm -f "$INIT_SCRIPT"
            ;;
        debian)
            if systemctl is-active --quiet s-ui; then
                systemctl stop s-ui 2>/dev/null || true
            fi
            systemctl disable s-ui 2>/dev/null || true
            rm -f "$SERVICE_FILE"
            systemctl daemon-reload 2>/dev/null || true
            ;;
    esac

    # Remove install dir
    rm -rf "$INSTALL_DIR"

    # Ask about data
    if [ -d "$DATA_DIR" ]; then
        printf "Remove data directory %s? [y/N]: " "$DATA_DIR"
        read -r ans
        case "$ans" in
            y|Y) rm -rf "$DATA_DIR"; log_info "Removed $DATA_DIR" ;;
            *)   log_info "Kept $DATA_DIR" ;;
        esac
    fi

    rm -f "$LOG_FILE"
    log_info "s-ui uninstalled successfully"
    exit 0
}

# ── Install service (OpenRC) ─────────────────────────────────────────────────
install_openrc_service() {
    log_info "Creating OpenRC service..."

    cat > "$INIT_SCRIPT" << 'INITEOF'
#!/sbin/openrc-run

supervisor=supervise-daemon

name="s-ui"
description="s-ui Panel (Sing-Box based)"
command="/usr/local/s-ui/sui"
directory="/usr/local/s-ui"

output_log="/var/log/s-ui.log"
error_log="/var/log/s-ui.log"

depend() {
    need net
    after firewall
}

start_pre() {
    if [ ! -d /etc/s-ui ]; then
        mkdir -p /etc/s-ui
    fi
}
INITEOF

    chmod +x "$INIT_SCRIPT"
    log_info "OpenRC service created at $INIT_SCRIPT"
}

# ── Install service (systemd) ────────────────────────────────────────────────
install_systemd_service() {
    log_info "Creating systemd service..."

    cat > "$SERVICE_FILE" << 'SERVICEEOF'
[Unit]
Description=s-ui Panel (Sing-Box based)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/usr/local/s-ui
ExecStart=/usr/local/s-ui/sui
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/s-ui.log
StandardError=append:/var/log/s-ui.log

[Install]
WantedBy=multi-user.target
SERVICEEOF

    systemctl daemon-reload
    log_info "systemd service created at $SERVICE_FILE"
}

# ── Install service ──────────────────────────────────────────────────────────
install_service() {
    case "$OS" in
        alpine) install_openrc_service ;;
        debian) install_systemd_service ;;
    esac
}

# ── Enable and start ─────────────────────────────────────────────────────────
enable_and_start() {
    case "$OS" in
        alpine)
            rc-update add s-ui default 2>/dev/null || {
                log_warn "s-ui already in default runlevel or rc-update failed"
            }
            log_info "Starting s-ui service..."
            rc-service s-ui start
            sleep 2
            if rc-service s-ui status; then
                SERVICE_OK=true
            else
                SERVICE_OK=false
            fi
            ;;
        debian)
            systemctl enable s-ui 2>/dev/null || {
                log_warn "s-ui already enabled or systemctl enable failed"
            }
            log_info "Starting s-ui service..."
            systemctl start s-ui
            sleep 2
            if systemctl is-active --quiet s-ui; then
                SERVICE_OK=true
            else
                SERVICE_OK=false
            fi
            ;;
    esac

    if $SERVICE_OK; then
        log_info "s-ui is running!"
        LOCAL_VER=$(cat "$INSTALL_DIR/version.txt" 2>/dev/null || echo "unknown")
        log_info "Version: $LOCAL_VER"
        log_info "Data directory: $DATA_DIR"
        log_info "Log file: $LOG_FILE"
    else
        log_error "s-ui failed to start. Check logs: $LOG_FILE"
        exit 1
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    detect_os

    if $UNINSTALL; then
        do_uninstall
    fi

    log_info "=== s-ui Installer ($OS) ==="

    detect_arch
    check_deps
    get_version
    download_files
    install_service
    enable_and_start

    log_info "=== Installation complete ==="
    if [ "$OS" = "alpine" ]; then
        log_info "Service: rc-service s-ui {start|stop|restart|status}"
        log_info "Manage:  rc-update {add|del} s-ui default"
    else
        log_info "Service: systemctl {start|stop|restart|status} s-ui"
        log_info "Manage:  systemctl {enable|disable} s-ui"
    fi
    log_info "Logs:    tail -f $LOG_FILE"
}

main
