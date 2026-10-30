#!/bin/bash
# ==============================================================================
# WineASIO Automated Installation and Registration Script
# Supports Wine 11+ / Wine 10+ / Wine 9+ (PE / Unix split architecture & WoW64)
# ==============================================================================

set -e

# ANSI Color codes
BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
NC="\033[0m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="all"
CUSTOM_WINE_DIR=""
CUSTOM_WINEPREFIX=""

# ------------------------------------------------------------------------------
# Usage / Help
# ------------------------------------------------------------------------------
show_help() {
    echo -e "${BOLD}WineASIO Automated Deployment & Registration Tool${NC}

Usage:
  ./install.sh [OPTIONS]

Options:
  --all              Perform complete installation, setup and registration (Default)
  --install-only     Install libraries and GUI only (requires sudo/root)
  --register-only    Register WineASIO in WINEPREFIX only (runs as current user)
  --unregister       Unregister WineASIO from WINEPREFIX
  --verify           Verify current installation and registry status
  --package          Package prebuilt binaries & scripts into a portable tarball
  -p, --prefix <DIR> Target WINEPREFIX (Default: \$HOME/.wine)
  -w, --wine-dir <DIR> Wine installation directory (e.g., /opt/wine-staging)
  -h, --help         Show this help message

Examples:
  # Standard deployment on a target machine (system install + default user prefix):
  sudo ./install.sh

  # Register into a custom WINEPREFIX without root:
  ./install.sh --register-only --prefix ~/.wine-custom

  # Package for deployment onto other computers:
  ./install.sh --package"
}

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            ACTION="all"
            shift
            ;;
        --install-only)
            ACTION="install"
            shift
            ;;
        --register-only)
            ACTION="register"
            shift
            ;;
        --unregister)
            ACTION="unregister"
            shift
            ;;
        --verify)
            ACTION="verify"
            shift
            ;;
        --package)
            ACTION="package"
            shift
            ;;
        -p|--prefix)
            CUSTOM_WINEPREFIX="$2"
            shift 2
            ;;
        -w|--wine-dir)
            CUSTOM_WINE_DIR="$2"
            shift 2
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
# Environment & User Detection
# ------------------------------------------------------------------------------
# Detect the real non-root user when run via sudo, so WINEPREFIX permissions stay clean
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    REAL_USER="$USER"
    REAL_HOME="$HOME"
fi

if [ -n "$CUSTOM_WINEPREFIX" ]; then
    TARGET_WINEPREFIX="$CUSTOM_WINEPREFIX"
elif [ -n "$WINEPREFIX" ]; then
    TARGET_WINEPREFIX="$WINEPREFIX"
else
    TARGET_WINEPREFIX="$REAL_HOME/.wine"
fi

# Run wine commands as the target user (prevent ~/.wine being owned by root)
run_as_user() {
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$SUDO_USER" env HOME="$REAL_HOME" WINEPREFIX="$TARGET_WINEPREFIX" "$@"
    else
        env WINEPREFIX="$TARGET_WINEPREFIX" "$@"
    fi
}

# Check sudo / root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${YELLOW}[!] This action requires root permissions. Prompting for sudo...${NC}"
        SUDO_CMD="sudo"
    else
        SUDO_CMD=""
    fi
}

# ------------------------------------------------------------------------------
# Wine Detection
# ------------------------------------------------------------------------------
detect_wine() {
    echo -e "${CYAN}==> Checking Wine environment...${NC}"
    if ! command -v wine >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] 'wine' command not found! Please install Wine first.${NC}"
        exit 1
    fi

    WINE_VER=$(run_as_user wine --version 2>/dev/null || wine --version)
    echo -e "  Found Wine version: ${GREEN}${WINE_VER}${NC}"

    if [ -n "$CUSTOM_WINE_DIR" ]; then
        WINE_DIR="$CUSTOM_WINE_DIR"
    else
        # Inspect where wine is installed
        WINE_EXEC=$(readlink -f "$(which wine)")
        CANDIDATE_DIR=$(dirname "$(dirname "$WINE_EXEC")")

        if [ -d "$CANDIDATE_DIR/lib/wine" ]; then
            WINE_DIR="$CANDIDATE_DIR"
        elif [ -d "/opt/wine-staging/lib/wine" ]; then
            WINE_DIR="/opt/wine-staging"
        elif [ -d "/opt/wine-stable/lib/wine" ]; then
            WINE_DIR="/opt/wine-stable"
        elif [ -d "/opt/wine-devel/lib/wine" ]; then
            WINE_DIR="/opt/wine-devel"
        elif [ -d "/usr/lib/wine" ] || [ -d "/usr/lib64/wine" ]; then
            WINE_DIR="/usr"
        else
            echo -e "${RED}[ERROR] Could not detect Wine library directory.${NC}"
            echo -e "Please specify it using: --wine-dir /path/to/wine"
            exit 1
        fi
    fi

    echo -e "  Wine install prefix: ${GREEN}${WINE_DIR}${NC}"
    echo -e "  Target WINEPREFIX:   ${GREEN}${TARGET_WINEPREFIX}${NC} (User: ${REAL_USER})"
}

# ------------------------------------------------------------------------------
# System Diagnostics & Dependency Checks
# ------------------------------------------------------------------------------
check_dependencies() {
    echo -e "${CYAN}==> Checking Audio & System dependencies...${NC}"

    # Check 64-bit JACK / PipeWire-JACK
    if ldconfig -p 2>/dev/null | grep -q "libjack.so.0.*x86-64"; then
        echo -e "  [OK] 64-bit JACK library detected"
    else
        echo -e "  ${YELLOW}[WARN] 64-bit libjack.so.0 not found in ldconfig.${NC}"
        echo -e "         Ensure pipewire-jack or libjack-jackd2-0 is installed."
    fi

    # Check 32-bit JACK / PipeWire-JACK (critical for 32-bit DAWs/VSTs like OpenMPT32, S-YXG100)
    HAS_JACK32=0
    for p in \
        "/usr/lib/i386-linux-gnu/pipewire-0.3/jack/libjack.so.0" \
        "/usr/lib/i386-linux-gnu/libjack.so.0" \
        "/usr/lib32/libjack.so.0" \
        "/usr/lib/libjack.so.0"; do
        if [ -f "$p" ]; then
            HAS_JACK32=1
            echo -e "  [OK] 32-bit JACK library detected: $p"
            break
        fi
    done

    if [ "$HAS_JACK32" -eq 0 ]; then
        echo -e "  ${YELLOW}[NOTICE] 32-bit JACK library was not detected!${NC}"
        echo -e "           If you intend to run 32-bit audio software (e.g. OpenMPT 32-bit, S-YXG100),"
        echo -e "           please install the 32-bit JACK client on Debian/Ubuntu/Mint:"
        echo -e "             ${BOLD}sudo apt install pipewire-jack:i386${NC}"
    fi

    # Audio group check
    if id -nG "$REAL_USER" 2>/dev/null | grep -qw "audio"; then
        echo -e "  [OK] User '${REAL_USER}' is in the 'audio' group"
    else
        echo -e "  ${YELLOW}[TIP] User '${REAL_USER}' is not in the 'audio' group.${NC}"
        echo -e "        For realtime audio performance, consider: ${BOLD}sudo usermod -aG audio ${REAL_USER}${NC}"
    fi
}

# ------------------------------------------------------------------------------
# Locate Binaries / Build if necessary
# ------------------------------------------------------------------------------
prepare_binaries() {
    echo -e "${CYAN}==> Locating WineASIO binaries...${NC}"

    # Search paths for prebuilt binaries
    SEARCH_DIRS=(
        "$SCRIPT_DIR/build_wine11"
        "$SCRIPT_DIR/bin"
        "$SCRIPT_DIR/64bit"
        "$SCRIPT_DIR"
    )

    DLL64=""
    SO64=""
    DLL32=""
    SO32=""

    for d in "${SEARCH_DIRS[@]}"; do
        [ -f "$d/wineasio64.dll" ] && [ -z "$DLL64" ] && DLL64="$d/wineasio64.dll"
        [ -f "$d/wineasio64.so" ]  && [ -z "$SO64" ]  && SO64="$d/wineasio64.so"
        [ -f "$d/wineasio.dll" ]    && [ -z "$DLL32" ] && DLL32="$d/wineasio.dll"
        [ -f "$d/wineasio.so" ]     && [ -z "$SO32" ]  && SO32="$d/wineasio.so"
    done

    # If any binaries are missing, check if source can be built
    if [ -z "$DLL64" ] || [ -z "$SO64" ] || [ -z "$DLL32" ] || [ -z "$SO32" ]; then
        if [ -f "$SCRIPT_DIR/Makefile.wine11" ]; then
            echo -e "${YELLOW}[!] Some binaries are missing. Attempting to build from source...${NC}"
            make -C "$SCRIPT_DIR" -f Makefile.wine11 WINE_PREFIX="$WINE_DIR" all
            DLL64="$SCRIPT_DIR/build_wine11/wineasio64.dll"
            SO64="$SCRIPT_DIR/build_wine11/wineasio64.so"
            DLL32="$SCRIPT_DIR/build_wine11/wineasio.dll"
            SO32="$SCRIPT_DIR/build_wine11/wineasio.so"
        else
            echo -e "${RED}[ERROR] Required WineASIO binaries not found in $SCRIPT_DIR and no Makefile.wine11 to build.${NC}"
            echo -e "Missing files:"
            [ -z "$DLL64" ] && echo "  - wineasio64.dll"
            [ -z "$SO64" ]  && echo "  - wineasio64.so"
            [ -z "$DLL32" ] && echo "  - wineasio.dll"
            [ -z "$SO32" ]  && echo "  - wineasio.so"
            exit 1
        fi
    fi

    echo -e "  [OK] 64-bit PE DLL:  $DLL64"
    echo -e "  [OK] 64-bit Unix SO: $SO64"
    echo -e "  [OK] 32-bit PE DLL:  $DLL32"
    echo -e "  [OK] 32-bit Unix SO: $SO32"
}

# ------------------------------------------------------------------------------
# System Installation (Libraries & GUI)
# ------------------------------------------------------------------------------
install_system() {
    check_root
    echo -e "${CYAN}==> Installing WineASIO to system directories (${WINE_DIR})...${NC}"

    INSTALL_WIN64="$WINE_DIR/lib/wine/x86_64-windows"
    INSTALL_UNIX64="$WINE_DIR/lib/wine/x86_64-unix"
    INSTALL_WIN32="$WINE_DIR/lib/wine/i386-windows"

    # Multiarch vs pure new WoW64 detection
    if [ -d "$WINE_DIR/lib/wine/i386-unix" ]; then
        INSTALL_UNIX32="$WINE_DIR/lib/wine/i386-unix"
    else
        INSTALL_UNIX32="$WINE_DIR/lib/wine/x86_64-unix"
    fi

    $SUDO_CMD mkdir -p "$INSTALL_WIN64" "$INSTALL_UNIX64" "$INSTALL_WIN32" "$INSTALL_UNIX32"

    echo "  Copying 64-bit files..."
    $SUDO_CMD cp -f "$DLL64" "$INSTALL_WIN64/wineasio64.dll"
    $SUDO_CMD cp -f "$SO64" "$INSTALL_UNIX64/wineasio64.so"
    # In Wine 11 WoW64, 32-bit PE DLL loads wineasio.so from x86_64-unix (must be 64-bit SO with WoW64 thunk)
    $SUDO_CMD cp -f "$SO64" "$INSTALL_UNIX64/wineasio.so"

    echo "  Copying 32-bit files..."
    $SUDO_CMD cp -f "$DLL32" "$INSTALL_WIN32/wineasio.dll"
    if [ "$INSTALL_UNIX32" != "$INSTALL_UNIX64" ]; then
        $SUDO_CMD cp -f "$SO32" "$INSTALL_UNIX32/wineasio.so"
    fi

    # If winebuild is available, mark DLLs as builtins
    if command -v winebuild >/dev/null 2>&1; then
        echo "  Registering Wine builtin metadata via winebuild..."
        $SUDO_CMD winebuild --builtin "$INSTALL_WIN64/wineasio64.dll" 2>/dev/null || true
        $SUDO_CMD winebuild --builtin "$INSTALL_WIN32/wineasio.dll" 2>/dev/null || true
    fi

    # Install GUI settings panel
    echo "  Installing wineasio-settings GUI..."
    GUI_DIR="$SCRIPT_DIR/gui"
    if [ -d "$GUI_DIR" ]; then
        $SUDO_CMD mkdir -p /usr/bin /usr/share/wineasio
        [ -f "$GUI_DIR/settings.py" ] && $SUDO_CMD cp -f "$GUI_DIR/settings.py" /usr/share/wineasio/
        [ -f "$GUI_DIR/ui_settings.py" ] && $SUDO_CMD cp -f "$GUI_DIR/ui_settings.py" /usr/share/wineasio/
        [ -f "$GUI_DIR/wineasio-settings.exe" ] && $SUDO_CMD cp -f "$GUI_DIR/wineasio-settings.exe" /usr/share/wineasio/ 2>/dev/null || true
        [ -f "$GUI_DIR/wineasio-settings64.exe" ] && $SUDO_CMD cp -f "$GUI_DIR/wineasio-settings64.exe" /usr/share/wineasio/ 2>/dev/null || true

        if [ -f "$GUI_DIR/wineasio-settings" ]; then
            $SUDO_CMD cp -f "$GUI_DIR/wineasio-settings" /usr/bin/wineasio-settings
            $SUDO_CMD sed -i "s?X-PREFIX-X?/usr?" /usr/bin/wineasio-settings
            $SUDO_CMD chmod 755 /usr/bin/wineasio-settings
        fi
        echo -e "  ${GREEN}[OK] GUI installed to /usr/bin/wineasio-settings${NC}"
    fi

    echo -e "${GREEN}==> System installation completed successfully!${NC}"
}

# ------------------------------------------------------------------------------
# WinePrefix Registration
# ------------------------------------------------------------------------------
register_prefix() {
    echo -e "${CYAN}==> Registering WineASIO in prefix: ${TARGET_WINEPREFIX}${NC}"

    # Ensure prefix exists
    if [ ! -d "$TARGET_WINEPREFIX" ]; then
        echo "  Initializing WINEPREFIX with wineboot -u..."
        run_as_user wineboot -u
    fi

    # Copy DLLs into prefix drive_c windows folders to ensure instant discovery
    SYS32="$TARGET_WINEPREFIX/drive_c/windows/system32"
    SYSWOW64="$TARGET_WINEPREFIX/drive_c/windows/syswow64"

    if [ -d "$SYSWOW64" ]; then
        # 64-bit WoW64 prefix: 64-bit in system32, 32-bit in syswow64
        run_as_user cp -f "$DLL64" "$SYS32/wineasio64.dll"
        run_as_user cp -f "$DLL32" "$SYSWOW64/wineasio.dll"
        run_as_user rm -f "$SYS32/wineasio.dll" 2>/dev/null || true
    elif [ -d "$SYS32" ]; then
        # Pure 32-bit prefix
        run_as_user cp -f "$DLL32" "$SYS32/wineasio.dll"
    fi

    # Register 64-bit DLL
    echo "  Registering 64-bit WineASIO driver (regsvr32 /s wineasio64.dll)..."
    run_as_user wine regsvr32 /s wineasio64.dll 2>/dev/null || true

    # Register 32-bit DLL
    if [ -f "$SYSWOW64/regsvr32.exe" ]; then
        echo "  Registering 32-bit WineASIO driver (syswow64 regsvr32 /s wineasio.dll)..."
        run_as_user wine "$SYSWOW64/regsvr32.exe" /s wineasio.dll 2>/dev/null || true
    else
        echo "  Registering 32-bit WineASIO driver (regsvr32 /s wineasio.dll)..."
        run_as_user wine regsvr32 /s wineasio.dll 2>/dev/null || true
    fi

    echo -e "${GREEN}==> Driver registration completed.${NC}"
}

# ------------------------------------------------------------------------------
# WinePrefix Unregistration
# ------------------------------------------------------------------------------
unregister_prefix() {
    echo -e "${CYAN}==> Unregistering WineASIO from prefix: ${TARGET_WINEPREFIX}${NC}"
    SYSWOW64="$TARGET_WINEPREFIX/drive_c/windows/syswow64"

    run_as_user wine regsvr32 /s /u wineasio64.dll 2>/dev/null || true

    if [ -f "$SYSWOW64/regsvr32.exe" ]; then
        run_as_user wine "$SYSWOW64/regsvr32.exe" /s /u wineasio.dll 2>/dev/null || true
    else
        run_as_user wine regsvr32 /s /u wineasio.dll 2>/dev/null || true
    fi

    echo -e "${GREEN}==> Unregistration complete.${NC}"
}

# ------------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------------
verify_installation() {
    echo -e "${CYAN}==> Verifying WineASIO status...${NC}"

    # Check 64-bit Registry
    REG64=$(run_as_user wine reg query "HKLM\\Software\\ASIO\\WineASIO" 2>/dev/null || true)
    if echo "$REG64" | grep -q "WineASIO"; then
        echo -e "  [OK] 64-bit Registry: ${GREEN}Registered${NC}"
    else
        echo -e "  [!!] 64-bit Registry: ${RED}Not found${NC}"
    fi

    # Check 32-bit WoW64 Registry
    REG32=$(run_as_user wine reg query "HKLM\\Software\\WOW6432Node\\ASIO\\WineASIO" 2>/dev/null || true)
    if echo "$REG32" | grep -q "WineASIO"; then
        echo -e "  [OK] 32-bit WoW64 Registry: ${GREEN}Registered${NC}"
    else
        echo -e "  [!!] 32-bit WoW64 Registry: ${YELLOW}Not found (Normal if prefix is pure 32-bit)${NC}"
    fi

    echo ""
    echo -e "${BOLD}Summary:${NC}"
    echo -e "  - Test GUI: Run '${BOLD}wineasio-settings${NC}' from terminal"
    echo -e "  - Per-App Isolation: Use '${BOLD}WINEASIO_CLIENT_NAME=\"AppName\"${NC}' when launching DAWs"
}

# ------------------------------------------------------------------------------
# Create Portable Deployment Package
# ------------------------------------------------------------------------------
package_bundle() {
    echo -e "${CYAN}==> Creating portable deployment package...${NC}"
    prepare_binaries

    BUNDLE_NAME="wineasio-deploy-$(date +%Y%m%d)"
    BUNDLE_DIR="/tmp/${BUNDLE_NAME}"
    TAR_FILE="${SCRIPT_DIR}/${BUNDLE_NAME}.tar.gz"

    rm -rf "$BUNDLE_DIR"
    mkdir -p "$BUNDLE_DIR/build_wine11" "$BUNDLE_DIR/gui"

    # Copy install & setup scripts
    cp "$SCRIPT_DIR/install.sh" "$BUNDLE_DIR/"
    chmod +x "$BUNDLE_DIR/install.sh"
    if [ -f "$SCRIPT_DIR/setup-pipewire-jack.sh" ]; then
        cp "$SCRIPT_DIR/setup-pipewire-jack.sh" "$BUNDLE_DIR/"
        chmod +x "$BUNDLE_DIR/setup-pipewire-jack.sh"
        ln -sf setup-pipewire-jack.sh "$BUNDLE_DIR/disable-jackdbus.sh"
    fi

    # Copy binaries
    cp "$DLL64" "$BUNDLE_DIR/build_wine11/wineasio64.dll"
    cp "$SO64"  "$BUNDLE_DIR/build_wine11/wineasio64.so"
    cp "$DLL32" "$BUNDLE_DIR/build_wine11/wineasio.dll"
    cp "$SO32"  "$BUNDLE_DIR/build_wine11/wineasio.so"

    # Copy GUI
    if [ -d "$SCRIPT_DIR/gui" ]; then
        cp -r "$SCRIPT_DIR/gui/"* "$BUNDLE_DIR/gui/" 2>/dev/null || true
        rm -rf "$BUNDLE_DIR/gui/__pycache__"
    fi

    # Copy documentation
    [ -f "$SCRIPT_DIR/README.md" ] && cp "$SCRIPT_DIR/README.md" "$BUNDLE_DIR/"

    # Create README in bundle
    cat > "$BUNDLE_DIR/QUICKSTART.md" << 'EOF'
# WineASIO Portable Deployment

To install and register WineASIO on this computer:

1. Open a terminal in this directory.
2. (Recommended) Configure PipeWire-JACK and disable conflicting jackdbus:
   ```bash
   sudo ./setup-pipewire-jack.sh
   ```
3. Install and register WineASIO:
   ```bash
   sudo ./install.sh
   ```
4. (Optional) If running 32-bit audio applications (e.g., OpenMPT 32-bit):
   ```bash
   sudo apt install pipewire-jack:i386
   ```
EOF

    tar -czf "$TAR_FILE" -C "/tmp" "$BUNDLE_NAME"
    rm -rf "$BUNDLE_DIR"

    echo -e "${GREEN}==> Deployment package created successfully!${NC}"
    echo -e "  Location: ${BOLD}${TAR_FILE}${NC}"
    echo -e "  To deploy on another PC:"
    echo -e "    1. Copy ${BOLD}${TAR_FILE}${NC} to the destination computer"
    echo -e "    2. Extract: ${BOLD}tar -xzvf ${BUNDLE_NAME}.tar.gz${NC}"
    echo -e "    3. Run:     ${BOLD}cd ${BUNDLE_NAME} && sudo ./install.sh${NC}"
}

# ------------------------------------------------------------------------------
# Main Dispatcher
# ------------------------------------------------------------------------------
case "$ACTION" in
    package)
        package_bundle
        ;;
    install)
        detect_wine
        check_dependencies
        prepare_binaries
        install_system
        ;;
    register)
        detect_wine
        prepare_binaries
        register_prefix
        verify_installation
        ;;
    unregister)
        detect_wine
        unregister_prefix
        ;;
    verify)
        detect_wine
        verify_installation
        ;;
    all)
        detect_wine
        check_dependencies
        prepare_binaries
        install_system
        register_prefix
        verify_installation
        ;;
esac
