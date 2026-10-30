#!/bin/bash
# ==============================================================================
# Disable jackdbus & Enable Global PipeWire-JACK
# ==============================================================================
# This script:
# 1. Stops any running jackdbus process and cleans up lock files.
# 2. Masks jackdbus in systemd to prevent auto-restart.
# 3. Overrides D-Bus service auto-activation so apps cannot spawn jackdbus.
# 4. Configures dynamic linker (ldconfig) so ALL 64-bit & 32-bit apps globally
#    load pipewire-jack instead of traditional jack2.
# 5. Ensures PipeWire and WirePlumber services are enabled and running.
# ==============================================================================

set -e

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
NC="\033[0m"

ACTION="all"

# ------------------------------------------------------------------------------
# Help
# ------------------------------------------------------------------------------
show_help() {
    echo -e "${BOLD}PipeWire-JACK Global Configuration & jackdbus Disabler${NC}

Usage:
  sudo ./setup-pipewire-jack.sh [OPTIONS]

Options:
  --all               Disable jackdbus + enable global PipeWire-JACK (Default)
  --disable-jackdbus  Only stop, mask, and block jackdbus auto-restart
  --global-jack       Only configure system-wide ldconfig for PipeWire-JACK
  --status            Display current status of jackdbus and PipeWire-JACK
  --restore           Restore default jackdbus behavior (undo all changes)
  -h, --help          Show this help message

Examples:
  # Recommended: Apply full global configuration:
  sudo ./setup-pipewire-jack.sh

  # Check current status:
  ./setup-pipewire-jack.sh --status
"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            ACTION="all"
            shift
            ;;
        --disable-jackdbus)
            ACTION="disable-jackdbus"
            shift
            ;;
        --global-jack)
            ACTION="global-jack"
            shift
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        --restore|--revert)
            ACTION="restore"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR] Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# User & Environment Detection
# ------------------------------------------------------------------------------
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    REAL_UID=$(id -u "$SUDO_USER")
else
    REAL_USER="$USER"
    REAL_HOME="$HOME"
    REAL_UID=$(id -u)
fi

run_user_systemctl() {
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" systemctl --user "$@"
    else
        systemctl --user "$@"
    fi
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}[ERROR] This operation requires root privileges. Please run with sudo:${NC}"
        echo -e "  ${BOLD}sudo $0 $*${NC}"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 1. Stop and Disable jackdbus
# ------------------------------------------------------------------------------
disable_jackdbus() {
    echo -e "${CYAN}==> [1/3] Stopping and disabling jackdbus...${NC}"

    # Kill running processes
    echo "  Terminating any running jackdbus instances..."
    pkill -9 -x jackdbus 2>/dev/null || true
    pkill -9 -x jackd 2>/dev/null || true

    # Clean up stale JACK shared memory / lockfiles
    rm -rf /dev/shm/jack* /tmp/jack* 2>/dev/null || true

    # Mask systemd service for user
    echo "  Masking jackdbus systemd service for user '${REAL_USER}'..."
    run_user_systemctl stop jackdbus.service 2>/dev/null || true
    run_user_systemctl mask jackdbus.service 2>/dev/null || true

    # D-Bus service override (User level)
    USER_DBUS_DIR="$REAL_HOME/.local/share/dbus-1/services"
    mkdir -p "$USER_DBUS_DIR"
    cat > "$USER_DBUS_DIR/org.jackaudio.service" << 'EOF'
[D-BUS Service]
Name=org.jackaudio.service
Exec=/bin/false
EOF
    chown -R "$REAL_USER:" "$USER_DBUS_DIR"
    echo -e "  [OK] User D-Bus override created at: $USER_DBUS_DIR/org.jackaudio.service"

    # D-Bus service override (System level, if root)
    if [ "$(id -u)" -eq 0 ]; then
        mkdir -p /etc/dbus-1/services
        cat > /etc/dbus-1/services/org.jackaudio.service << 'EOF'
[D-BUS Service]
Name=org.jackaudio.service
Exec=/bin/false
EOF
        echo -e "  [OK] System D-Bus override created at: /etc/dbus-1/services/org.jackaudio.service"
    fi

    echo -e "${GREEN}  ✓ jackdbus successfully disabled and auto-restart blocked.${NC}"
}

# ------------------------------------------------------------------------------
# 2. Configure Global PipeWire-JACK (ld.so.conf.d)
# ------------------------------------------------------------------------------
enable_global_pipewire_jack() {
    check_root
    echo -e "${CYAN}==> [2/3] Configuring global PipeWire-JACK dynamic linker priority...${NC}"

    PW_JACK64=""
    PW_JACK32=""

    # Detect 64-bit PipeWire-JACK path
    for p in \
        "/usr/lib/x86_64-linux-gnu/pipewire-0.3/jack" \
        "/usr/lib64/pipewire-0.3/jack" \
        "/usr/lib/pipewire-0.3/jack"; do
        if [ -f "$p/libjack.so.0" ]; then
            PW_JACK64="$p"
            break
        fi
    done

    # Detect 32-bit PipeWire-JACK path
    for p in \
        "/usr/lib/i386-linux-gnu/pipewire-0.3/jack" \
        "/usr/lib32/pipewire-0.3/jack"; do
        if [ -f "$p/libjack.so.0" ]; then
            PW_JACK32="$p"
            break
        fi
    done

    if [ -z "$PW_JACK64" ]; then
        echo -e "  ${YELLOW}[NOTICE] 64-bit pipewire-jack was not found. Installing package...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y pipewire-jack
            PW_JACK64="/usr/lib/x86_64-linux-gnu/pipewire-0.3/jack"
        fi
    fi

    if [ -n "$PW_JACK64" ]; then
        echo "$PW_JACK64" > /etc/ld.so.conf.d/00-pipewire-jack-x86_64-linux-gnu.conf
        echo -e "  [OK] Created /etc/ld.so.conf.d/00-pipewire-jack-x86_64-linux-gnu.conf -> $PW_JACK64"
    else
        echo -e "  ${RED}[WARN] 64-bit libjack for PipeWire not found!${NC}"
    fi

    if [ -n "$PW_JACK32" ]; then
        echo "$PW_JACK32" > /etc/ld.so.conf.d/00-pipewire-jack-i386-linux-gnu.conf
        echo -e "  [OK] Created /etc/ld.so.conf.d/00-pipewire-jack-i386-linux-gnu.conf -> $PW_JACK32"
    else
        echo -e "  ${YELLOW}[TIP] 32-bit pipewire-jack not installed. If you run 32-bit Windows audio apps, run:${NC}"
        echo -e "        ${BOLD}sudo apt install pipewire-jack:i386${NC}"
    fi

    # Update dynamic linker cache
    echo "  Rebuilding dynamic linker cache (ldconfig)..."
    ldconfig

    echo -e "${GREEN}  ✓ Global PipeWire-JACK dynamic linking activated.${NC}"
}

# ------------------------------------------------------------------------------
# 3. Ensure PipeWire Services
# ------------------------------------------------------------------------------
ensure_pipewire_services() {
    echo -e "${CYAN}==> [3/3] Ensuring PipeWire user services are active...${NC}"
    run_user_systemctl enable --now pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null || true
    echo -e "${GREEN}  ✓ PipeWire & WirePlumber services enabled.${NC}"
}

# ------------------------------------------------------------------------------
# Status Check
# ------------------------------------------------------------------------------
check_status() {
    echo -e "${CYAN}==> PipeWire-JACK and jackdbus Status Overview:${NC}"
    echo ""

    # Check jackdbus process
    if pgrep -x jackdbus >/dev/null 2>&1; then
        JACK_PID=$(pgrep -x jackdbus | tr '\n' ' ')
        echo -e "  jackdbus process:     ${RED}RUNNING (PID: $JACK_PID)${NC}"
    else
        echo -e "  jackdbus process:     ${GREEN}STOPPED (Not running)${NC}"
    fi

    # Check systemd mask
    UNIT_STATUS=$(run_user_systemctl is-enabled jackdbus.service 2>/dev/null) || true
    [ -z "$UNIT_STATUS" ] && UNIT_STATUS="not-found"
    if [ "$UNIT_STATUS" = "masked" ]; then
        echo -e "  jackdbus systemd:     ${GREEN}MASKED (Cannot auto-start)${NC}"
    else
        echo -e "  jackdbus systemd:     ${YELLOW}$UNIT_STATUS${NC}"
    fi

    # Check D-Bus override
    USER_OVERRIDE="$REAL_HOME/.local/share/dbus-1/services/org.jackaudio.service"
    SYS_OVERRIDE="/etc/dbus-1/services/org.jackaudio.service"
    if [ -f "$USER_OVERRIDE" ] || [ -f "$SYS_OVERRIDE" ]; then
        echo -e "  D-Bus auto-wake:      ${GREEN}BLOCKED (/bin/false override active)${NC}"
    else
        echo -e "  D-Bus auto-wake:      ${YELLOW}DEFAULT (May auto-wake jackdbus)${NC}"
    fi

    # Check Dynamic Linker Priority
    echo ""
    echo -e "${BOLD}Current Dynamic Linker libjack.so.0 Resolution:${NC}"
    ldconfig -p 2>/dev/null | grep "libjack.so.0" | while read -r line; do
        if echo "$line" | grep -q "pipewire"; then
            echo -e "  ${GREEN}$line${NC}"
        else
            echo -e "  $line"
        fi
    done

    # Check PipeWire server
    PW_ACTIVE=0
    if command -v pw-cli >/dev/null 2>&1 && pw-cli info 0 >/dev/null 2>&1; then
        PW_ACTIVE=1
    elif pgrep -x pipewire >/dev/null 2>&1; then
        PW_ACTIVE=1
    elif [ "$(run_user_systemctl is-active pipewire.service 2>/dev/null)" = "active" ]; then
        PW_ACTIVE=1
    fi

    if [ "$PW_ACTIVE" -eq 1 ]; then
        echo -e "\n  PipeWire daemon:      ${GREEN}ACTIVE & READY${NC}"
    else
        echo -e "\n  PipeWire daemon:      ${YELLOW}NOT RUNNING${NC}"
        echo -e "  To start PipeWire, run as your normal user (without sudo):"
        echo -e "    ${BOLD}systemctl --user start pipewire pipewire-pulse wireplumber${NC}"
    fi
}

# ------------------------------------------------------------------------------
# Restore / Undo
# ------------------------------------------------------------------------------
restore_defaults() {
    check_root
    echo -e "${CYAN}==> Restoring default jackdbus and JACK configuration...${NC}"

    # Remove D-Bus overrides
    rm -f "$REAL_HOME/.local/share/dbus-1/services/org.jackaudio.service"
    rm -f "/etc/dbus-1/services/org.jackaudio.service"

    # Unmask systemd service
    run_user_systemctl unmask jackdbus.service 2>/dev/null || true

    # Remove ld.so.conf.d entries
    rm -f /etc/ld.so.conf.d/00-pipewire-jack-*.conf
    ldconfig

    echo -e "${GREEN}  ✓ Defaults restored. Dynamic linker cache updated.${NC}"
}

# ------------------------------------------------------------------------------
# Main Dispatcher
# ------------------------------------------------------------------------------
case "$ACTION" in
    status)
        check_status
        ;;
    restore)
        restore_defaults
        check_status
        ;;
    disable-jackdbus)
        disable_jackdbus
        check_status
        ;;
    global-jack)
        enable_global_pipewire_jack
        check_status
        ;;
    all)
        disable_jackdbus
        enable_global_pipewire_jack
        ensure_pipewire_services
        echo ""
        echo -e "${BOLD}${GREEN}================================================================${NC}"
        echo -e "${BOLD}${GREEN}  Global PipeWire-JACK is active! jackdbus is fully disabled.  ${NC}"
        echo -e "${BOLD}${GREEN}================================================================${NC}"
        echo ""
        check_status
        ;;
esac
