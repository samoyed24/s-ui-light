#!/bin/sh
#
# install.sh — Install s-ui on Alpine Linux or Debian/Ubuntu
#
# Auto-detects the OS (Alpine → OpenRC, Debian/Ubuntu → systemd) and the
# architecture. Downloads binaries from GitHub Releases (no git needed).
#
# After installing, the script optionally:
#   - sets a random strong password for the admin account (username unchanged)
#   - generates a self-signed certificate and serves the panel over HTTPS
#   - deploys a Hysteria2 inbound with a self-signed certificate, a forged SNI
#     and "allow insecure" enabled
#
# Usage:
#   ./install.sh [OPTIONS]
#
# Options:
#   --repo <user/repo>  GitHub repo (default: samoyed24/s-ui-light)
#   --arch <arch>       Force architecture (amd64|arm64). Auto-detected by default.
#   --install-dir <dir> Installation directory. Default: /usr/local/s-ui
#   --version <ver>     Specific version to install (default: latest)
#   --uninstall         Remove s-ui and its service
#   --no-prompt         Skip every interactive question (answer "no" to each)
#   --yes               Skip every interactive question (answer "yes" to each)
#   --no-stats          Do not report this run to the public install counter
#   -h, --help          Show this help
#
# Examples:
#   ./install.sh
#   ./install.sh --arch arm64
#   ./install.sh --repo myuser/myrepo --version v1.4.2
#   ./install.sh --uninstall

set -e

# ── Interactivity ─────────────────────────────────────────────────────────────
# ASSUME carries the --yes/--no-prompt answer. Empty means "ask"; when there is
# no terminal to ask on (a pipe, cron, curl | sh), ask() falls back to no so an
# unattended run cannot silently turn on TLS or open a port.
ASSUME=""

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info()  { printf "${GREEN}[INF]${NC} %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WRN]${NC} %s\n" "$*"; }
log_error() { printf "${RED}[ERR]${NC} %s\n" "$*"; }

# ask prints a prompt and returns 0 for yes. There is no `read` when stdin is
# not a terminal, so an unattended run gets the safe answer instead of hanging
# forever on a prompt nobody can see.
ask() {
    case "$ASSUME" in
        yes) return 0 ;;
        no)  return 1 ;;
    esac
    [ -t 0 ] || return 1
    printf "%s [y/N]: " "$1"
    # A failed read (EOF, Ctrl-D) must not abort the script under set -e.
    read -r _ans || true
    case "$_ans" in
        y|Y|yes|YES) return 0 ;;
        *)           return 1 ;;
    esac
}

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO="samoyed24/s-ui-light"
INSTALL_DIR="/usr/local/s-ui"
DATA_DIR="/etc/s-ui"
LOG_FILE="/var/log/s-ui.log"
INIT_SCRIPT="/etc/init.d/s-ui"
SERVICE_FILE="/etc/systemd/system/s-ui.service"
# Filled in after the arguments are parsed, so --install-dir is honoured.
CERT_DIR=""
OS=""
ARCH=""
VERSION="latest"
UNINSTALL=false
ADMIN_USER="admin"
ADMIN_PASS=""
CERT_CRT=""
CERT_KEY=""
PANEL_TLS=false
NO_STATS=false

# Ports and names for the generated certificate. The SNI is a decoy: the
# certificate is self-signed, so its name is only there to look unremarkable
# to a passive observer, and clients skip verification anyway.
SNI_POOL="www.bing.com www.cloudflare.com www.apple.com www.microsoft.com www.amazon.com"
HY2_TAG_PREFIX="hysteria2"

# ── Parse arguments ───────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)        REPO="$2"; shift 2 ;;
        --arch)        ARCH="$2"; shift 2 ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --version)     VERSION="$2"; shift 2 ;;
        --uninstall)   UNINSTALL=true; shift ;;
        --yes)         ASSUME="yes"; shift ;;
        --no-prompt)   ASSUME="no"; shift ;;
        --no-stats)    NO_STATS=true; shift ;;
        -h|--help)
            # Every leading comment line, minus the shebang, up to the first
            # real statement. Stopping at a blank line instead ended the range
            # immediately: the header uses "#" on its own as a separator.
            # Written as two substitutions because the "\?" in "# \?" is a GNU
            # extension that BSD sed rejects, which printed nothing at all.
            sed -n -e '2,/^[^#]/s/^# //p' -e '2,/^[^#]/s/^#$//p' "$0" | sed '/^$/d'
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Certificates sit next to the binary so --install-dir moves them together.
CERT_DIR="$INSTALL_DIR/cert"

# The service files interpolate these paths, so a value that could break out of
# a systemd "WorkingDirectory=" line or an OpenRC "directory=" assignment would
# produce a unit that cannot run -- or worse, one that runs something else.
case "$INSTALL_DIR" in
    *[\ \"\'\`\$\*]*)
        log_error "--install-dir must not contain spaces, quotes, or shell metacharacters"
        exit 1
        ;;
esac
case "$INSTALL_DIR" in
    /*) ;;
    *)
        log_error "--install-dir must be an absolute path"
        exit 1
        ;;
esac

# ── Root check ────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

# ── Detect OS ─────────────────────────────────────────────────────────────────
detect_os() {
    if [ -f /etc/os-release ]; then
        ID=$( . /etc/os-release; echo "$ID" )
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
    # curl and openssl are only needed for the optional post-install steps, but
    # installing them here keeps the whole script on one dependency pass.
    # busybox wget has no cookie jar, so the panel API calls cannot use it.
    case "$OS" in
        alpine)
            local need_wget=false need_openrc=false need_curl=false need_openssl=false

            command -v wget >/dev/null 2>&1 || need_wget=true
            command -v rc-service >/dev/null 2>&1 || command -v rc-update >/dev/null 2>&1 || need_openrc=true
            command -v curl >/dev/null 2>&1 || need_curl=true
            command -v openssl >/dev/null 2>&1 || need_openssl=true

            if $need_wget || $need_openrc || $need_curl || $need_openssl; then
                local packages=""
                $need_wget && packages="$packages wget"
                $need_openrc && packages="$packages openrc"
                $need_curl && packages="$packages curl"
                $need_openssl && packages="$packages openssl"

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
            local need_wget=false need_curl=false need_openssl=false

            command -v wget >/dev/null 2>&1 || need_wget=true
            command -v curl >/dev/null 2>&1 || need_curl=true
            command -v openssl >/dev/null 2>&1 || need_openssl=true

            if $need_wget || $need_curl || $need_openssl; then
                local packages=""
                $need_wget && packages="$packages wget"
                $need_curl && packages="$packages curl"
                $need_openssl && packages="$packages openssl"

                log_info "Installing missing dependencies:$packages"
                apt-get update -qq
                apt-get install -y -qq $packages
                if [ $? -ne 0 ]; then
                    log_error "Failed to install dependencies. Run manually: apt-get install -y$packages"
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
        _body=$(wget -qO- "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)

        # A renamed or transferred repository answers this endpoint with 301 and
        # a "Moved Permanently" body naming a numeric id, not with releases.
        # wget does not follow it, so the tag comes back empty. Follow the
        # redirect explicitly: opaque, but far better than failing the install
        # with "Failed to fetch latest version" on a repo that still exists.
        if [ -z "$_body" ] || ! echo "$_body" | grep -q '"tag_name"'; then
            _moved=$(echo "$_body" | sed -n 's/.*"url": *"\([^"]*\)".*/\1/p' | head -1)
            if [ -n "$_moved" ]; then
                log_warn "GitHub reports this repository has moved; following the redirect"
                _body=$(wget -qO- "$_moved" 2>/dev/null || true)
            fi
        fi

        VERSION=$(echo "$_body" | grep '"tag_name"' | head -1 | sed 's/.*: "//;s/".*//')
        if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
            log_error "Failed to fetch the latest version from GitHub ($REPO)"
            log_error "Check the repo name with --repo <user/repo>, or pass --version <ver>"
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

    # Download main binary (with arch suffix).
    # No --show-progress: Alpine's wget is the busybox applet, whose long-option
    # table has no such flag. busybox getopt32 calls bb_show_usage() and exits
    # non-zero on an unknown long option, so the download would fail on every
    # Alpine host. It also contradicts -q, which is already passed.
    log_info "Downloading sui-$ARCH..."
    wget -q -O "$INSTALL_DIR/sui" "$base_url/sui-$ARCH" || {
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

    # The panel's database and settings live under $INSTALL_DIR/db -- the
    # binary resolves its data directory from argv[0], and $DATA_DIR (/etc/s-ui)
    # is a leftover from the community script that nothing reads. Asking about
    # "$DATA_DIR" *after* deleting $INSTALL_DIR therefore offered to preserve
    # something empty while the real database was already gone. Ask first, and
    # describe what is actually at stake.
    _keep_data=false
    if [ -d "$INSTALL_DIR/db" ]; then
        if [ -t 0 ] && [ -z "$ASSUME" ]; then
            printf "Keep the panel database (accounts, nodes, settings) in %s/db? [Y/n]: " "$INSTALL_DIR"
            read -r ans || true
            case "$ans" in
                n|N|no|NO) _keep_data=false ;;
                *)         _keep_data=true ;;
            esac
        else
            # No terminal (curl | sh, cron), or --yes/--no-prompt. Reading here
            # would consume the script's own source text out of the shell's
            # stdin buffer and corrupt the rest of the run, so take the default
            # that cannot lose data. --no-prompt does not mean "delete my
            # accounts": an unattended uninstall should still be recoverable.
            _keep_data=true
        fi
    fi

    if $_keep_data; then
        _backup_db="/root/s-ui-db-backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$_backup_db"
        cp -a "$INSTALL_DIR/db/." "$_backup_db/" 2>/dev/null || true
        log_info "Database backed up to $_backup_db"
    fi

    # Takes $INSTALL_DIR/db and $CERT_DIR (the private key) with it.
    rm -rf "$INSTALL_DIR"

    if [ -d "$DATA_DIR" ]; then
        rm -rf "$DATA_DIR"
        log_info "Removed legacy directory $DATA_DIR"
    fi

    rm -f "$LOG_FILE"
    log_info "s-ui uninstalled successfully"
    exit 0
}

# ── Install service (OpenRC) ─────────────────────────────────────────────────
install_openrc_service() {
    log_info "Creating OpenRC service..."

    # Unquoted heredoc so $INSTALL_DIR and $LOG_FILE are substituted -- a
    # hardcoded /usr/local/s-ui broke --install-dir, leaving a service that
    # pointed at a directory the binaries were never written to.
    cat > "$INIT_SCRIPT" << INITEOF
#!/sbin/openrc-run

supervisor=supervise-daemon

name="s-ui"
description="s-ui Panel (Sing-Box based)"
command="$INSTALL_DIR/sui"
directory="$INSTALL_DIR"

output_log="$LOG_FILE"
error_log="$LOG_FILE"

depend() {
    need net
    after firewall
}

start_pre() {
    if [ ! -d "$INSTALL_DIR" ]; then
        mkdir -p "$INSTALL_DIR"
    fi
}
INITEOF

    chmod +x "$INIT_SCRIPT"
    log_info "OpenRC service created at $INIT_SCRIPT"
}

# ── Install service (systemd) ────────────────────────────────────────────────
install_systemd_service() {
    log_info "Creating systemd service..."

    # Unquoted heredoc so $INSTALL_DIR and $LOG_FILE are substituted, so
    # --install-dir works. LimitNOFILE matches upstream's unit: a proxy holds
    # two descriptors per connection, and the default 1024 is reached by a few
    # hundred clients, after which sockets fail to open with no clear cause.
    cat > "$SERVICE_FILE" << SERVICEEOF
[Unit]
Description=s-ui Panel (Sing-Box based)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/sui
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

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

# ── Service control ──────────────────────────────────────────────────────────
service_restart() {
    case "$OS" in
        alpine) rc-service s-ui restart >/dev/null 2>&1 || rc-service s-ui start ;;
        debian) systemctl restart s-ui ;;
    esac
}

# sui runs a subcommand against the installed binary. The binary resolves its
# database from the directory of argv[0], so /etc/s-ui (which the community
# script creates and this one kept) is not where the data lives.
sui() {
    "$INSTALL_DIR/sui" "$@"
}

# ── Generate a random password ───────────────────────────────────────────────
# 24 chars from a charset with no shell or URL metacharacters, so the value
# survives being written into a URL and pasted into a terminal. Read from
# /dev/urandom, not $RANDOM: this protects an internet-facing panel.
random_password() {
    # `|| true` because dd exits as soon as it has its 24 bytes, which closes
    # the pipe under tr and makes the pipeline exit non-zero -- fatal under
    # set -e, and silent, since the password itself was produced correctly.
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | dd bs=1 count=24 2>/dev/null || true
}

# ── Random port above 20000 ──────────────────────────────────────────────────
random_port() {
    _n=$(od -An -N2 -tu2 < /dev/urandom 2>/dev/null | tr -d ' ' || true)
    case "$_n" in
        ''|*[!0-9]*) _n=0 ;;
    esac
    echo $(( 20000 + (_n % 40000) ))
}

# ── Set the admin password ───────────────────────────────────────────────────
# The password is only known here, and s-ui stores a one-way hash, so this is
# the single chance to show it. Kept in a variable rather than re-read from the
# database, which holds no recoverable value.
set_admin_password() {
    ADMIN_PASS=$(random_password)
    if [ ${#ADMIN_PASS} -lt 24 ]; then
        log_error "Failed to generate a random password (/dev/urandom unavailable)"
        exit 1
    fi

    log_info "Setting a random password for the '$ADMIN_USER' account..."
    if sui admin -username "$ADMIN_USER" -password "$ADMIN_PASS" >/dev/null 2>&1; then
        ADMIN_PASS_SET=true
        log_info "Admin password updated"
    else
        ADMIN_PASS_SET=false
        log_error "Failed to set the admin password. Set it manually with:"
        log_error "  $INSTALL_DIR/sui admin -username $ADMIN_USER -password <newpassword>"
    fi
}

# ── Generate a self-signed certificate ───────────────────────────────────────
# The key is generated as a NAMED curve on purpose. OpenSSL in Alpine is
# LibreSSL, and a plain "-newkey ec" there writes the curve as explicit
# parameters, which Go's crypto/x509 refuses: s-ui then cannot load the pair
# and every TLS-bound inbound fails with "x509: invalid ECDSA parameters".
# Named-curve output is byte-identical in intent on OpenSSL 3 (Debian/Ubuntu).
generate_cert() {
    mkdir -p "$CERT_DIR" || return 1
    chmod 700 "$CERT_DIR"

    log_info "Generating a self-signed certificate in $CERT_DIR ..."
    # Both files are removed up front. A pair left over from an earlier run
    # would otherwise satisfy the "does the crt exist" check below while its
    # key is missing or does not match, and the panel accepts that save and
    # then fails to load the certificate.
    rm -f "$CERT_DIR/self.key" "$CERT_DIR/self.crt"

    if ! openssl ecparam -name prime256v1 -genkey -noout -param_enc named_curve \
            -out "$CERT_DIR/self.key" 2>/dev/null; then
        log_error "Failed to generate the private key"
        return 1
    fi
    if ! openssl req -x509 -new -nodes -days 3650 \
            -key "$CERT_DIR/self.key" \
            -out "$CERT_DIR/self.crt" \
            -subj "/CN=myserver" 2>/dev/null; then
        log_error "Failed to generate the certificate"
        rm -f "$CERT_DIR/self.key" "$CERT_DIR/self.crt"
        return 1
    fi

    # Verified as a pair, not file-by-file: openssl will happily write a cert
    # from a key, and the panel needs both to be present and consistent.
    if ! openssl x509 -in "$CERT_DIR/self.crt" -noout -pubkey >/dev/null 2>&1; then
        log_error "The generated certificate is not readable"
        rm -f "$CERT_DIR/self.key" "$CERT_DIR/self.crt"
        return 1
    fi

    # The private key is as sensitive as the admin password.
    chmod 600 "$CERT_DIR/self.key" "$CERT_DIR/self.crt"

    CERT_CRT="$CERT_DIR/self.crt"
    CERT_KEY="$CERT_DIR/self.key"
    log_info "Certificate: $CERT_CRT"
    log_info "Private key: $CERT_KEY"
    return 0
}

# ── Panel HTTP client ────────────────────────────────────────────────────────
# Every request carries X-Requested-With, which the panel's SameOrigin CSRF
# middleware accepts in place of an Origin/Referer match, and the session
# cookie saved at login. curl is used because busybox wget (Alpine's default)
# has no cookie jar at all.
# API_BASE already carries the "api/" segment. Every endpoint hangs off it, so
# a bare "$PANEL_PATH$action" would land on the SPA's catch-all route and come
# back as HTML with a 200, which reads as success to anything but a JSON check.
API_BASE=""
COOKIE_JAR=""

panel_request() {
    _method="$1"; shift
    _path="$1"; shift
    curl -sk -m 20 -X "$_method" \
        -H "X-Requested-With: XMLHttpRequest" \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        "$API_BASE$_path" "$@" 2>/dev/null
}

# panel_login waits for the panel to answer at all -- TLS finishes coming up a
# moment after the service reports started. The session is written to
# COOKIE_JAR, so a later step can reuse it instead of logging in again.
#
# The retry only covers the panel not being ready yet. An *answered* rejection
# is returned immediately: the panel counts failed logins per source address
# and locks the address out for 10 minutes after 10 of them, so retrying a
# wrong password 20 times would lock out 127.0.0.1 and make every later call in
# this run fail too. A rejected login means the credentials need looking at,
# not that the panel is still starting.
panel_login() {
    _i=0
    while [ "$_i" -lt 20 ]; do
        # curl exits non-zero on a connection refused while TLS is still coming
        # up, which set -e would take as fatal.
        _out=$(panel_request POST "login" -d "user=$ADMIN_USER" --data-urlencode "pass=$ADMIN_PASS" || true)
        case "$_out" in
            *'"success":true'*) return 0 ;;
            # Any JSON at all means the panel answered, so retrying cannot help.
            *'"success":false'*)
                log_error "The panel rejected the login: $(echo "$_out" | head -c 160)"
                return 1
                ;;
        esac
        _i=$(( _i + 1 ))
        sleep 1
    done
    log_error "The panel did not answer on $API_BASE"
    return 1
}

# ensure_session logs in unless a live session is already in the jar. A panel
# restart drops every session, so this is checked rather than assumed.
ensure_session() {
    _out=$(panel_request GET "status" || true)
    case "$_out" in
        *'"success":true'*) return 0 ;;
    esac
    panel_login
}

# panel_save posts one object to the panel's save endpoint. s-ui builds the
# derived data (out_json, subscription links) and reloads sing-box inside this
# call, so writing the database directly would produce a node that exists but
# carries no usable link.
panel_save() {
    _object="$1"; _action="$2"; _data="$3"
    panel_request POST "save" \
        --data-urlencode "object=$_object" \
        --data-urlencode "action=$_action" \
        --data-urlencode "data=$_data" \
        --data-urlencode "initUsers=" || true
}

# ── Enable HTTPS on the panel ────────────────────────────────────────────────
# s-ui reads webCertFile/webKeyFile from its settings at startup, so the panel
# has to be restarted for the change to take effect.
enable_panel_tls() {
    log_info "Enabling HTTPS for the panel..."
    # The settings branch of the panel's save ignores the action, so it is left
    # empty; certFile and keyFile must both be set or the panel refuses to start.
    _out=$(panel_save settings "" "{\"webCertFile\":\"$CERT_CRT\",\"webKeyFile\":\"$CERT_KEY\"}")
    case "$_out" in
        *'"success":true'*) ;;
        *)
            log_error "Failed to enable HTTPS: $(echo "$_out" | head -c 200)"
            return 1
            ;;
    esac

    # The setting is committed before the restart, so the panel is on HTTPS
    # from here on whether or not the switch below succeeds. PANEL_TLS is
    # therefore set from what the panel actually serves, not from the intent --
    # a failed switch must not leave the summary advertising http:// for a
    # panel that now refuses it.
    _http_base="http://127.0.0.1:$PANEL_PORT${PANEL_PATH}api/"
    API_BASE="https://127.0.0.1:$PANEL_PORT${PANEL_PATH}api/"
    service_restart
    sleep 3

    _i=0
    while [ "$_i" -lt 10 ]; do
        _out=$(panel_request GET "status" || true)
        case "$_out" in
            # Any JSON at all means the TLS listener accepted the request.
            *'"success"'*) PANEL_TLS=true; return 0 ;;
        esac
        _i=$(( _i + 1 ))
        sleep 1
    done

    # Not answering over HTTPS. Fall back so the remaining steps can still run,
    # and say so plainly rather than reporting a switch that did not take.
    log_warn "The panel is not answering over HTTPS; falling back to HTTP"
    API_BASE="$_http_base"
    PANEL_TLS=false
    return 1
}

# ── Deploy a Hysteria2 inbound ───────────────────────────────────────────────
deploy_hysteria2() {
    _port=$(random_port)
    # Pick one decoy hostname at random from the pool. Counted rather than
    # hardcoded so adding a name to SNI_POOL does not skew the odds.
    _sni_n=$(for _s in $SNI_POOL; do printf '%s\n' "$_s"; done | wc -l | tr -d ' ')
    _sni=$(for _s in $SNI_POOL; do printf '%s\n' "$_s"; done | awk -v n="$_RAND" -v c="$_sni_n" 'NR==(n%c)+1')
    # A draw that yields nothing (empty pool, or awk comparing against an empty
    # seed and matching no record) exits 0 and prints an empty string. That
    # would post a TLS record with "server_name":"" and still report success, so
    # fall back to the first name rather than deploy a node with no SNI.
    if [ -z "$_sni" ]; then
        _sni=$(for _s in $SNI_POOL; do printf '%s\n' "$_s"; done | head -1)
    fi
    if [ -z "$_sni" ]; then
        log_error "No SNI available to use (SNI_POOL is empty)"
        return 1
    fi

    log_info "Deploying a Hysteria2 node..."
    log_info "  Port: $_port  SNI: $_sni"

    # 1. TLS config: the certificate, the forged SNI, and "allow insecure" on
    #    the client side. That last flag is client.insecure -- the inbound's own
    #    TLS block has no such field, and sing-box would reject an unknown key.
    _tls="{\"id\":0,\"name\":\"hy2-tls\",\"server\":{\"enabled\":true,\"server_name\":\"$_sni\",\"alpn\":[\"h3\"],\"certificate_path\":\"$CERT_CRT\",\"key_path\":\"$CERT_KEY\"},\"client\":{\"insecure\":true}}"
    _out=$(panel_save tls new "$_tls")
    case "$_out" in
        *'"success":true'*) ;;
        *)
            log_error "Failed to create the TLS config: $(echo "$_out" | head -c 200)"
            return 1
            ;;
    esac

    # The id of the record just created, taken from the first "id" *inside* the
    # response's "tls" array. Truncating the line at the marker first matters:
    # a greedy sed over the whole line returns the id belonging to whichever
    # array happens to sort last, so a response ordered with "tls" before
    # clients/inbounds yields the wrong row's id and binds the inbound to
    # another TLS config, silently.
    _tls_id=$(echo "$_out" | awk '{
        i = index($0, "\"tls\":[")
        if (i == 0) { exit }
        rest = substr($0, i + 7)
        if (match(rest, /"id"[ ]*:[ ]*[0-9]+/)) print substr(rest, RSTART, RLENGTH)
    }' | sed 's/[^0-9]//g')

    case "$_tls_id" in
        ''|*[!0-9]*)
            log_error "Could not determine the new TLS config id"
            return 1
            ;;
    esac
    log_info "  TLS config id: $_tls_id"

    # 2. The inbound itself. The tag is unique and carries the port, so a
    #    second run makes a new node instead of colliding with this one.
    _tag="$HY2_TAG_PREFIX-$_port"
    _inb="{\"id\":0,\"type\":\"hysteria2\",\"tag\":\"$_tag\",\"tls_id\":$_tls_id,\"listen\":\"::\",\"listen_port\":$_port,\"addrs\":[],\"out_json\":{}}"
    _out=$(panel_save inbounds new "$_inb")
    case "$_out" in
        *'"success":true'*) ;;
        *)
            log_error "Failed to create the Hysteria2 inbound: $(echo "$_out" | head -c 200)"
            return 1
            ;;
    esac

    HY2_PORT="$_port"
    HY2_SNI="$_sni"
    HY2_TAG="$_tag"
    HY2_OK=true
    log_info "Hysteria2 node created: $_tag"
    return 0
}

# ── Read the panel's own address ─────────────────────────────────────────────
# Asked of the binary rather than assumed: webPort/webPath are panel settings a
# previous install may have changed. `sui setting -show` prints them without
# needing sqlite3, which is not on Alpine by default.
read_panel_address() {
    _show=$(sui setting -show 2>/dev/null || true)
    PANEL_PORT=$(echo "$_show" | awk -F'\t' '/Panel port:/{print $NF}' | tr -d ' ')
    PANEL_PATH=$(echo "$_show" | awk -F'\t' '/Panel path:/{print $NF}' | tr -d ' ')

    case "$PANEL_PORT" in
        ''|*[!0-9]*) PANEL_PORT="2095" ;;
    esac
    case "$PANEL_PATH" in
        /*) ;;
        *) PANEL_PATH="/app/" ;;
    esac
    case "$PANEL_PATH" in
        */) ;;
        *) PANEL_PATH="$PANEL_PATH/" ;;
    esac
}

# ── Report ───────────────────────────────────────────────────────────────────
# Printed at the very end so credentials and the node details are the last
# thing on screen rather than scrolled past.
show_summary() {
    _host=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$_host" ] && _host=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    [ -z "$_host" ] && _host="<server-ip>"

    _scheme="http"; $PANEL_TLS && _scheme="https"

    printf "\n"
    printf "${GREEN}=================== Deployment summary ===================${NC}\n"
    printf "\n"
    printf "  Panel:    %s://%s:%s%s\n" "$_scheme" "$_host" "$PANEL_PORT" "$PANEL_PATH"
    if $PANEL_TLS; then
        printf "            (self-signed certificate -- the browser will warn)\n"
    fi
    printf "\n"
    if $ADMIN_PASS_SET; then
        printf "  Login:    %s\n" "$ADMIN_USER"
        printf "  Password: %s\n" "$ADMIN_PASS"
        printf "            ${YELLOW}Save this now. It cannot be recovered.${NC}\n"
    else
        printf "  Login:    %s\n" "$ADMIN_USER"
        printf "  Password: ${RED}not set -- run: $INSTALL_DIR/sui admin -reset${NC}\n"
    fi

    if $HY2_OK; then
        printf "\n"
        printf "  Hysteria2 node: %s\n" "$HY2_TAG"
        printf "    Port: %s/UDP\n" "$HY2_PORT"
        printf "    SNI:  %s\n" "$HY2_SNI"
        printf "    Add a client in the panel to get a subscription link.\n"
        if [ -n "$_host" ] && [ "$_host" != "<server-ip>" ]; then
            printf "    ${YELLOW}Open %s/UDP in your firewall/security group.${NC}\n" "$HY2_PORT"
        fi
    fi
    printf "\n"
    printf "${GREEN}==========================================================${NC}\n"
}

# ── Run counter ───────────────────────────────────────────────────────────────
# Reports this run to a public counter and prints how many times the script has
# been run in total. The script is delivered as a single file over wget|sh, so
# it keeps no state of its own and a local tally would only ever describe the
# one machine it sits on; a shared counter is the only way "total runs" means
# anything.
#
# Abacus is used because it is the one counter that needs no signup: an API key
# baked into a public script is not a secret, so keyed services are out.
# The counter name carries the repo, so forks count separately.
#
# Reporting is best-effort in both directions. A failed request must never
# abort an install that is otherwise fine, and a failure to report must not be
# confused with a total of zero -- hence the "unknown" wording.
report_run() {
    if $NO_STATS; then
        log_info "Run counter: skipped (--no-stats)"
        return 0
    fi

    # curl, not wget: the panel API calls already require it, and it is the
    # dependency check_deps guarantees. Give up quickly -- the install is
    # already finished and nobody should wait on a tally.
    _repo_slug=$(echo "$REPO" | tr '/.' '__')
    _url="https://abacus.jasoncameron.dev/hit/s-ui-light/$_repo_slug"
    _resp=$(curl -fsS --max-time 5 "$_url" 2>/dev/null || true)

    # Response is {"value": 42}. Parse it without depending on a JSON tool:
    # busybox has no jq, and this is a single flat field.
    _count=$(echo "$_resp" | sed -n 's/.*"value"[: ]*\([0-9][0-9]*\).*/\1/p' | head -1)

    if [ -n "$_count" ]; then
        log_info "Run counter: this script has been run $_count time(s) in total"
    else
        # Offline, rate-limited (30 requests per 10s per IP), or the service is
        # down. Say so plainly rather than printing a number that looks real.
        log_warn "Run counter: unavailable (could not reach the counter service)"
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

    # ── Optional post-install steps ──────────────────────────────────────────
    read_panel_address
    API_BASE="http://127.0.0.1:$PANEL_PORT${PANEL_PATH}api/"
    # Holds a live panel session cookie, so it must not land on a predictable
    # path in world-writable /tmp. mktemp is in busybox and coreutils; the
    # fallback goes under the install directory, which is root-only.
    COOKIE_JAR=$(mktemp 2>/dev/null || echo "$INSTALL_DIR/.cookie.$$")
    ADMIN_PASS_SET=true
    HY2_OK=false
    # Seeds the SNI choice. Guarded like random_port's: a failing od under
    # set -e would abort the install at the last step.
    _RAND=$(od -An -N2 -tu2 < /dev/urandom 2>/dev/null | tr -d ' ' || true)
    case "$_RAND" in
        ''|*[!0-9]*) _RAND=0 ;;
    esac

    # 1. Replace the default admin/admin credentials. The panel is already
    #    reachable, so leaving the shipped password on it is the first thing to
    #    fix and is not made optional.
    set_admin_password

    # 2. Offer TLS for the panel itself.
    if ask "Serve the s-ui panel over HTTPS with a self-signed certificate?"; then
        if generate_cert; then
            if panel_login; then
                enable_panel_tls || log_warn "The panel did not come up on HTTPS"
                # The cookie was issued over HTTP; HTTPS logins are re-issued
                # per request by the panel, so reuse it instead of logging in
                # again over a certificate curl would have to be told to trust.
            else
                log_warn "Could not log in to the panel; skipping HTTPS"
            fi
        else
            log_warn "Skipping HTTPS"
        fi
    else
        log_info "Panel will keep serving HTTP"
    fi

    # 3. Offer a Hysteria2 node. The certificate from step 2 is reused when it
    #    exists; otherwise one is generated now, since the protocol requires TLS.
    if ask "Deploy a Hysteria2 node?"; then
        # Hysteria2 requires TLS. Reuse the certificate from step 2, or make
        # one now if that step was declined.
        [ -n "$CERT_CRT" ] || generate_cert || log_warn "Certificate generation failed"

        if [ -z "$CERT_CRT" ]; then
            log_error "No certificate available; skipping Hysteria2"
        elif ensure_session; then
            # The panel restarted when HTTPS was enabled, which drops the
            # session from step 2 -- ensure_session logs in again if needed.
            deploy_hysteria2 || log_warn "Hysteria2 deployment failed"
        else
            log_error "Could not log in to the panel; skipping Hysteria2"
        fi
    else
        log_info "Skipping Hysteria2"
    fi

    rm -f "$COOKIE_JAR" 2>/dev/null || true
    show_summary

    log_info "=== Installation complete ==="
    if [ "$OS" = "alpine" ]; then
        log_info "Service: rc-service s-ui {start|stop|restart|status}"
        log_info "Manage:  rc-update {add|del} s-ui default"
    else
        log_info "Service: systemctl {start|stop|restart|status} s-ui"
        log_info "Manage:  systemctl {enable|disable} s-ui"
    fi
    log_info "Logs:    tail -f $LOG_FILE"

    report_run
}

main
