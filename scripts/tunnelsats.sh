#!/bin/bash
# TunnelSats Unified Setup Tool
# Consolidates install, pre-check, uninstall, and status commands
#
# Usage: sudo ./tunnelsats.sh [command] [options]

set -e  # Exit on error

#═══════════════════════════════════════════════════════════════════════════
# GLOBAL VARIABLES
#═══════════════════════════════════════════════════════════════════════════

VERSION="3.0beta"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
PLATFORM=""
LN_IMPL=""

#═══════════════════════════════════════════════════════════════════════════
# COLOR & FORMATTING FUNCTIONS
#═══════════════════════════════════════════════════════════════════════════

# ANSI Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

print_header() {
    local subtitle="$1"
    local padding=$(( (42 - ${#subtitle}) / 2 ))
    
    echo -e "${BOLD}${BLUE}"
    echo "╔══════════════════════════════════════════╗"
    echo "║    Tunnel⚡Sats Setup Tool v${VERSION}    ║"
    printf "║%*s%s%*s║\n" $padding "" "$subtitle" $((42 - padding - ${#subtitle})) ""
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}⚠${NC}  $1"
}

print_info() {
    echo -e "${BLUE}→${NC} $1"
}

print_step() {
    echo -e "${BOLD}[$1/$2]${NC} $3"
}

#══════════════════════════════════════════════════════════════════════════
# COMMON UTILITY FUNCTIONS
#══════════════════════════════════════════════════════════════════════════

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        print_error "This script must be run as root"
        echo "Please run: sudo $0 $@"
        exit 1
    fi
}

valid_ipv4() {
    local ip=$1
    local stat=1
    
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && \
           ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

# Find active WireGuard config file
# Supports both old (tunnelsatsv2.conf) and new (tunnelsats-*.conf) formats
find_active_wg_config() {
    # Check for old format first
    if [[ -f /etc/wireguard/tunnelsatsv2.conf ]]; then
        echo "/etc/wireguard/tunnelsatsv2.conf"
        return 0
    fi
    
    # Look for new format
    local configs=($(find /etc/wireguard -name "tunnelsats-*.conf" -type f 2>/dev/null))
    if [[ ${#configs[@]} -eq 1 ]]; then
        echo "${configs[0]}"
        return 0
    elif [[ ${#configs[@]} -gt 1 ]]; then
        # Multiple configs found - use the first one
        echo "${configs[0]}"
        return 0
    fi
    
    # No config found
    return 1
}

# Parse metadata from config file (supports old and new formats)
# Usage: parse_config_metadata <config_file> <field>
# Fields: port, expiry, pubkey
parse_config_metadata() {
    local config_file="$1"
    local field="$2"
    
    if [[ ! -f "$config_file" ]]; then
        return 1
    fi
    
    case "$field" in
        port)
            # Old format: #VPNPort = 22632
            # New format: # Port Forwarding: 12345
            local port=$(grep -E "#VPNPort|# Port Forwarding:" "$config_file" | head -1 | awk '{print $NF}')
            echo "$port"
            ;;
        expiry)
            # Old format: #ValidUntil (UTC time) = 2025-06-29T08:18:33.839Z
            # New format: # Valid Until: 2026-01-07T...
            local expiry=$(grep -E "#ValidUntil|# Valid Until:" "$config_file" | head -1 | sed 's/.*[=:] *//')
            echo "$expiry"
            ;;
        pubkey)
            # Old format: #myPubKey = 6gTYyE8eFW7579zIOlvEgehrhGb01SrqC5dgQupxlAU=
            # New format: # myPubKey: <user's-public-key>
            local pubkey=$(grep -E "#myPubKey" "$config_file" | head -1 | sed 's/.*[=:] *//')
            echo "$pubkey"
            ;;
        *)
            return 1
            ;;
    esac
}

#══════════════════════════════════════════════════════════════════════════
# CONFIG FILE DETECTION
#══════════════════════════════════════════════════════════════════════════

find_config_files() {
    local search_dir="${1:-.}"
    local found_files=()
    
    # Priority 1: tunnelsats_*.conf files
    while IFS= read -r -d '' file; do
        found_files+=("$file")
    done < <(find "$search_dir" -maxdepth 1 -name "tunnelsats_*.conf" -type f -print0 2>/dev/null)
    
    # Priority 2: If none found, look for any .conf files
    if [[ ${#found_files[@]} -eq 0 ]]; then
        while IFS= read -r -d '' file; do
            # Exclude system config files
            if [[ ! "$file" =~ (nftables|sysctl|resolv)\\.conf$ ]]; then
                found_files+=("$file")
            fi
        done < <(find "$search_dir" -maxdepth 1 -name "*.conf" -type f -print0 2>/dev/null)
    fi
    
    # Return the array
    printf '%s\n' "${found_files[@]}"
}

select_config_interactive() {
    local files=("$@")
    echo ""
    print_info "Found ${#files[@]} WireGuard configuration file(s):"
    echo ""
    
    for i in "${!files[@]}"; do
        echo "  $((i+1))) ${files[$i]##*/}"
    done
    
    echo ""
    read -p "Select config [1-${#files[@]}]: " selection
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && \
       [[ "$selection" -ge 1 ]] && \
       [[ "$selection" -le "${#files[@]}" ]]; then
        echo "${files[$((selection-1))]}"
    else
        print_error "Invalid selection"
        exit 1
    fi
}

detect_config_file() {
    local config_arg="$1"
    
    # If --config provided, verify and use it
    if [[ -n "$config_arg" ]]; then
        if [[ -f "$config_arg" ]]; then
            print_success "Using specified config: ${config_arg##*/}"
            echo "$config_arg"
            return 0
        else
            print_error "Config file not found: $config_arg"
            exit 1
        fi
    fi
    
    # Auto-detect config files
    mapfile -t found_files < <(find_config_files "$SCRIPT_DIR")
    
    if [[ ${#found_files[@]} -eq 0 ]]; then
        print_error "No WireGuard config files found"
        echo ""
        echo "Expected files:"
        echo "  • tunnelsats_<server>.conf (e.g., tunnelsats_us-east.conf)"
        echo "  • Any .conf file in the current directory"
        echo ""
        echo "Please place your config file here and try again."
        exit 1
        
    elif [[ ${#found_files[@]} -eq 1 ]]; then
        print_success "Auto-detected config: ${found_files[0]##*/}"
        echo "${found_files[0]}"
        return 0
        
    else
        # Multiple configs - interactive selection
        local selected
        selected=$(select_config_interactive "${found_files[@]}")
        echo "$selected"
        return 0
    fi
}

#══════════════════════════════════════════════════════════════════════════
# COMMAND HANDLERS
#══════════════════════════════════════════════════════════════════════════

cmd_help() {
    print_header "Usage Guide"
    
    cat << 'EOF'
Usage: sudo ./tunnelsats.sh [COMMAND] [OPTIONS]

Commands:
  install              Install WireGuard VPN configuration
  install --config <file>  Install with specific config file
  pre-check            Check system compatibility
  uninstall            Remove TunnelSats installation
  status               Show subscription and connection status
  help                 Show this help message

Examples:
  # Run compatibility check first
  sudo ./tunnelsats.sh pre-check
  
  # Install with auto-detection
  sudo ./tunnelsats.sh install
  
  # Install with specific config
  sudo ./tunnelsats.sh install --config tunnelsats_us-east.conf
  
  # Check status
  sudo ./tunnelsats.sh status
  
  # Clean uninstall
  sudo ./tunnelsats.sh uninstall

For more information:
  Website: https://tunnelsats.com
  Guide: https://tunnelsats.com/guide
  Support: https://t.me/+xvjQdEObZ1Y4MjQy

EOF
}

cmd_pre_check() {
    print_header "Compatibility Check"
    
    echo "Checking system requirements..."
    echo ""
    
    local rating=0
    
    # Check kernel version (min 5.10.102+ required)
    print_step 1 3 "Checking kernel version..."
    local kernelMajor=$(uname -r | cut -d '.' -f1)
    local kernelMinor=$(uname -r | cut -d '.' -f2)
    local kernelPatch=$(uname -r | cut -d '.' -f3 | cut -d '-' -f1)
    
    if [[ $kernelMajor -gt 5 ]] || \
       [[ $kernelMajor -ge 5 && ( ($kernelMinor -ge 10 && $kernelPatch -ge 102) || $kernelMinor -ge 11 ) ]]; then
        print_success "Kernel $(uname -r) is compatible"
        ((rating++))
    else
        print_error "Kernel 5.10.102+ required (found $(uname -r))"
    fi
    echo ""
    
    # Check nftables version (min 0.9.6+ required)
    print_step 2 3 "Checking nftables version..."
    local nftablesVersion=""
    if command -v nft &>/dev/null; then
        nftablesVersion=$(nft -v | awk '{print $2}' | cut -d 'v' -f2)
    else
        nftablesVersion=$(apt search nftables 2>/dev/null | grep "^nftables" | awk '{print $2}' | cut -d '-' -f1 || echo "0.0.0")
    fi
    
    local nftMajor=$(echo "$nftablesVersion" | cut -d '.' -f1)
    local nftMinor=$(echo "$nftablesVersion" | cut -d '.' -f2)
    local nftPatch=$(echo "$nftablesVersion" | cut -d '.' -f3)
    
    if [[ $nftMajor -ge 1 ]] || \
       [[ $nftMinor -ge 9 && $nftPatch -ge 6 ]] || \
       [[ $nftMinor -ge 10 ]]; then
        print_success "nftables $nftablesVersion is compatible"
        ((rating++))
    else
        print_error "nftables 0.9.6+ required (found $nftablesVersion)"
    fi
    echo ""
    
    # Check for systemd services or docker
    print_step 3 3 "Looking for Lightning implementation..."
    if [[ -f /etc/systemd/system/lnd.service ]]; then
        print_success "Found lnd.service"
        ((rating++))
    elif [[ -f /etc/systemd/system/lightningd.service ]]; then
        print_success "Found lightningd.service"
        ((rating++))
    else
        print_info "Checking for Docker containers..."
        local dockerProcess=$(docker ps --format 'table {{.Image}} {{.Names}} {{.Ports}}' 2>/dev/null | grep -E "0.0.0.0:9735|0.0.0.0:9736" | awk '{print $2}' || echo "")
        if [[ ${dockerProcess} == *lnd* ]]; then
            print_success "Found LND container"
            ((rating++))
        elif [[ ${dockerProcess} == *clightning* ]]; then
            print_success "Found CLN container"
            ((rating++))
        else
            print_error "No suitable Lightning implementation found"
        fi
    fi
    echo ""
    
    # Display result
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${BOLD}Compatibility Rating: $rating/3${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    if [[ $rating -eq 3 ]]; then
        print_success "Your system is fully compatible with TunnelSats!"
        echo ""
        echo "Ready to install? Run:"
        echo -e "  ${GREEN}sudo ./tunnelsats.sh install${NC}"
    elif [[ $rating -gt 0 && $rating -lt 3 ]]; then
        print_warning "Your system is likely compatible, but some requirements are missing"
        echo "Review the checks above and install missing components"
    else
        print_error "Your system is not compatible with TunnelSats"
        echo "Please review the requirements at https://tunnelsats.com/guide"
    fi
    echo ""
}

cmd_install() {
    print_header "Installation Wizard"
    
    # Detect config file
    local config_path
    config_path=$(detect_config_file "$CONFIG_FILE")
    CONFIG_FILE="$config_path"
    
    echo ""
    print_info "Config file: ${CONFIG_FILE##*/}"
    echo ""
    
    # Confirm to proceed
    echo "This will install TunnelSats VPN on your system."
    echo "The process will:"
    echo "  • Install required dependencies (wireguard, nftables, cgroup-tools)"
    echo "  • Configure WireGuard tunnel"
    echo "  • Set up systemd services"
    echo "  • Configure your Lightning node"
    echo ""
    read -p "Continue with installation? (Y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Installation cancelled"
        exit 0
    fi
    echo ""
    
    # Step 1: Detect Platform
    print_step 1 8 "Detecting platform..."
    detect_platform
    echo ""
    
    # Step 2: Detect Lightning Implementation
    print_step 2 8 "Selecting Lightning implementation..."
    detect_ln_implementation
    echo ""
    
    # Step 3: Install dependencies
    print_step 3 8 "Installing dependencies..."
    install_dependencies
    echo ""
    
    # Step 4: Configure WireGuard
    print_step 4 8 "Configuring WireGuard..."
    configure_wireguard
    echo ""
    
    # Step 4.5: Setup Docker network (Umbrel only)
    if [[ "$PLATFORM" == "umbrel" ]]; then
        print_info "Setting up Docker network..."
        setup_docker_network
        echo ""
    fi
    
    # Step 5: Setup cgroups (non-Docker only)
    if [[ "$PLATFORM" != "umbrel" ]]; then
        print_step 5 8 "Setting up cgroups..."
        setup_cgroups
        echo ""
    else
        print_info "Skipping cgroups (Docker setup)"
        echo ""
    fi
    
    # Step 6: Configure Lightning node  
    print_step 6 8 "Configuring Lightning node..."
    configure_lightning
    echo ""
    
    # Step 7: Enable services
    print_step 7 8 "Enabling systemd services..."
    enable_services
    echo ""
    
    # Step 8: Final verification
    print_step 8 8 "Verifying installation..."
    verify_installation
    echo ""
    
    # Success!
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "Installation completed successfully!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Get VPN details from config
    local vpnExternalDNS=$(grep "Endpoint" /etc/wireguard/tunnelsatsv2.conf | awk '{print $3}' | cut -d ':' -f1)
    local vpnExternalPort=$(grep "#VPNPort" /etc/wireguard/tunnelsatsv2.conf | awk '{print $3}' || echo "<port>")
    
    # Show configuration instructions based on implementation
    echo -e "${BOLD}IMPORTANT: Configure your Lightning node${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    if [[ "$LN_IMPL" == "lnd" ]]; then
        if [[ "$PLATFORM" == "umbrel" ]]; then
            cat << EOF
LND on Umbrel 0.5+:

Make a backup and then edit ~/umbrel/app-data/lightning/data/lnd/lnd.conf 
to add or modify the below lines.

Important:
There are a few hybrid settings Umbrel's bringing to the UI, please do the following steps:
- in the Umbrel GUI, navigate to the LND advanced settings
- validate which of the below settings are activated already
- leave those activated as they are
- don't add those settings in your custom lnd.conf again to avoid duplication

Example: in case tor.streamisolation and tor.skip-proxy-for-clearnet-targets is already 
activated in the UI, skip the [Tor] section completely and only add externalhosts. 

#########################################
[Application Options]
externalhosts=${vpnExternalDNS}:${vpnExternalPort}
[Tor]
tor.streamisolation=false
tor.skip-proxy-for-clearnet-targets=true
#########################################
EOF
        else
            cat << EOF
LND:

Before editing, please create a backup of your current LND config file.
Then edit and add or modify the following lines. Please note that
settings could already be part of your configuration file 
and duplicated lines could lead to errors.

#########################################
[Application Options]
listen=0.0.0.0:9735
externalhosts=${vpnExternalDNS}:${vpnExternalPort}
[Tor]
tor.streamisolation=false
tor.skip-proxy-for-clearnet-targets=true
#########################################
EOF
        fi
    elif [[ "$LN_IMPL" == "cln" ]]; then
        if [[ "$PLATFORM" == "umbrel" ]]; then
            cat << EOF
CLN on Umbrel 0.5+:

Before editing, please create backups of your CLN config files.

###############################################################################
Create/edit CLN config file 'config':
  \$ sudo nano ~/umbrel/app-data/core-lightning/data/lightningd/bitcoin/config 
insert:
  bind-addr=0.0.0.0:9735
  announce-addr=${vpnExternalDNS}:${vpnExternalPort}
  always-use-proxy=false

Edit 'export.sh':
  \$ nano ~/umbrel/app-data/core-lightning/export.sh
change assigned port of APP_CORE_LIGHTNING_DAEMON_PORT from 9736 to 9735:
  export APP_CORE_LIGHTNING_DAEMON_PORT="9735"

Edit 'docker-compose.yml':
comment out 'bind-addr' parameter like so:
   command:
   ...
   #- --bind-addr=\${APP_CORE_LIGHTNING_DAEMON_IP}:9735  
###############################################################################
EOF
        else
            cat << EOF
CLN:

Before editing, please create a backup of your current CLN config file.
Then edit and add or modify the following lines.

###############################################################################
Native CLN installation (config file):

  # Tor
  addr=statictor:127.0.0.1:9051/torport=9735
  proxy=127.0.0.1:9050
  always-use-proxy=false

  # VPN
  bind-addr=0.0.0.0:9735
  announce-addr=${vpnExternalDNS}:${vpnExternalPort}
###############################################################################
EOF
        fi
    elif [[ "$LN_IMPL" == "lit" ]]; then
        cat << EOF
LIT:

Before editing, please create a backup of your current lit.conf config file.
Then edit and add or modify the following lines.

#########################################
[Application Options]
#listen=0.0.0.0:9735
externalhosts=${vpnExternalDNS}:${vpnExternalPort}
[Tor]
tor.streamisolation=false
tor.skip-proxy-for-clearnet-targets=true
#########################################
EOF
    fi
    
    echo ""
    echo "Please save this info in a file or write them down for later use."
    echo ""
    echo "A more detailed guide is available at: https://tunnelsats.com/guide"
    echo "Afterwards please restart your Lightning node for changes to take effect."
    echo ""
    echo "Welcome to Tunnel⚡Sats."
    echo "- Feel free to join the Amboss Community: https://amboss.space/community/29db5f25-24bb-407e-b752-be69f9431071"
    echo "- Check your clearnet connection functionality and speed: https://t.me/TunnelSatsBot"
    echo "- Join our Telegram Group: https://t.me/tunnelsats"
    echo "- Add a reminder on your subscription expiration date: https://t.me/TunnelSatsReminderBot"
    echo ""
    
    # Restart instructions
    echo -e "${BOLD}Restart your Lightning node:${NC}"
    if [[ "$PLATFORM" == "umbrel" ]]; then
        if [[ -f /etc/systemd/system/umbrel-startup.service ]]; then
            echo "  sudo ~/umbrel/scripts/stop"
            echo "  sudo ~/umbrel/scripts/start"
        elif [[ -f /etc/systemd/system/umbrel.service ]]; then
            echo "  sudo systemctl restart umbrel.service"
        fi
    else
        local service_name="${LN_IMPL}"
        if [[ "$LN_IMPL" == "cln" ]]; then
            service_name="lightningd"
        fi
        echo "  sudo systemctl restart ${service_name}.service"
    fi
    echo ""
}

# Helper functions for install command

detect_platform() {
    echo "What Lightning node package are you running?"
    echo "  1) RaspiBlitz"
    echo "  2) Umbrel"
    echo "  3) myNode"
    echo "  4) RaspiBolt / Bare Metal"
    echo ""
    read -p "Select [1-4]: " answer
    
    case $answer in
        1) PLATFORM="raspiblitz"; print_success "Platform: RaspiBlitz" ;;
        2) PLATFORM="umbrel"; print_success "Platform: Umbrel" ;;
        3) PLATFORM="mynode"; print_success "Platform: myNode" ;;
        4) PLATFORM="baremetal"; print_success "Platform: RaspiBolt/Bare Metal" ;;
        *) print_error "Invalid selection"; exit 1 ;;
    esac
}

detect_ln_implementation() {
    echo "Which Lightning implementation do you want to tunnel?"
    echo "  1) LND"
    echo "  2) CLN (Core Lightning)"
    if [[ "$PLATFORM" == "baremetal" ]]; then
        echo "  3) LIT (integrated mode)"
    fi
    echo ""
    read -p "Select [1-3]: " choice
    
    case $choice in
        1) LN_IMPL="lnd"; print_success "Lightning: LND" ;;
        2) LN_IMPL="cln"; print_success "Lightning: CLN" ;;
        3) 
            if [[ "$PLATFORM" == "baremetal" ]]; then
                LN_IMPL="lit"; print_success "Lightning: LIT"
            else
                print_error "LIT only available on bare metal"
                exit 1
            fi
            ;;
        *) print_error "Invalid selection"; exit 1 ;;
    esac
}

install_dependencies() {
    print_info "Updating package repositories..."
    apt-get update > /dev/null 2>&1
    
    # Install WireGuard
    if ! command -v wg &>/dev/null; then
        print_info "Installing WireGuard..."
        apt-get install -y wireguard > /dev/null 2>&1 && \
            print_success "WireGuard installed" || \
            { print_error "Failed to install WireGuard"; exit 1; }
    else
        print_success "WireGuard already installed"
    fi
    
    # Install nftables
    if ! command -v nft &>/dev/null; then
        print_info "Installing nftables..."
        apt-get install -y nftables > /dev/null 2>&1 && \
            print_success "nftables installed" || \
            { print_error "Failed to install nftables"; exit 1; }
    else
        print_success "nftables already installed"
    fi
    
    # Install cgroup-tools (non-Docker only)
    if [[ "$PLATFORM" != "umbrel" ]]; then
        if ! command -v cgcreate &>/dev/null; then
            print_info "Installing cgroup-tools..."
            apt-get install -y cgroup-tools > /dev/null 2>&1 && \
                print_success "cgroup-tools installed" || \
                { print_error "Failed to install cgroup-tools"; exit 1; }
        else
            print_success "cgroup-tools already installed"
        fi
    fi
    
    # Install resolvconf
    if ! command -v resolvconf &>/dev/null; then
        print_info "Installing resolvconf..."
        apt-get install -y resolvconf > /dev/null 2>&1 && \
            print_success "resolvconf installed" || \
            { print_error "Failed to install resolvconf"; exit 1; }
    else
        print_success "resolvconf already installed"
    fi
}

configure_wireguard() {
    print_info "Copying config to /etc/wireguard/..."
    
    # Determine target filename - preserve dynamic names or use tunnelsatsv2.conf as fallback
    local source_filename=$(basename "$CONFIG_FILE")
    local target_filename
    
    if [[ "$source_filename" == tunnelsats-*.conf ]]; then
        # New format with server name - preserve it
        target_filename="$source_filename"
    else
        # Old format or generic - use tunnelsatsv2.conf for backward compatibility
        target_filename="tunnelsatsv2.conf"
    fi
    
    local target_path="/etc/wireguard/$target_filename"
    
    # Copy config
    cp "$CONFIG_FILE" "$target_path" || \
        { print_error "Failed to copy config"; exit 1; }
    
    print_success "Config copied to $target_filename"
    
    # Store target path for use in service setup
    WG_CONFIG_PATH="$target_path"
    WG_INTERFACE=$(basename "$target_path" .conf)
    
    # Verify config has Endpoint
    if ! grep -q "Endpoint" "$target_path"; then
        print_error "Config missing Endpoint entry"
        exit 1
    fi
    
    # Fetch all local networks and exclude them from kill switch
    local localNetworks=$(ip route | awk '{print $1}' | grep -v default | sed -z 's/\n/, /g')
    if [ -z "$localNetworks" ]; then
        localNetworks="10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16"
    fi
    
    # Apply network rules based on platform
    if [[ "$PLATFORM" == "umbrel" ]]; then
        print_info "Applying Docker network rules..."
        
        local inputDocker="

#Tunnelsats-Setupv2-Docker

[Interface]
DNS = 8.8.8.8
Table = off


PostUp = while [ \$(ip rule | grep -c suppress_prefixlength) -gt 0 ]; do ip rule del from all table  main suppress_prefixlength 0;done
PostUp = while [ \$(ip rule | grep -c 0x1000000) -gt 0 ]; do ip rule del from all fwmark 0x1000000/0xff000000 table  51820;done
PostUp = if [ \$(ip route show table 51820 2>/dev/null | grep -c blackhole) -gt  0 ]; then echo \$?; ip route del blackhole default metric 3 table 51820; ip rule flush table 51820 ;fi


PostUp = ip rule add from \$(docker network inspect \"docker-tunnelsats\" | grep Subnet | awk '{print \$2}' | sed 's/[\",]//g') table 51820
PostUp = ip rule add from all table main suppress_prefixlength 0
PostUp = ip route add blackhole default metric 3 table 51820
PostUp = ip route add default dev %i metric 2 table 51820
PostUp = ip route add  10.9.0.0/24 dev %i  proto kernel scope link; ping -c1 10.9.0.1

PostUp = sysctl -w net.ipv4.conf.all.rp_filter=0
PostUp = sysctl -w net.ipv6.conf.all.disable_ipv6=1
PostUp = sysctl -w net.ipv6.conf.default.disable_ipv6=1

PostDown = ip rule del from \$(docker network inspect \"docker-tunnelsats\" | grep Subnet | awk '{print \$2}' | sed 's/[\",]//g') table 51820
PostDown = ip rule del from all table  main suppress_prefixlength 0
PostDown = ip route flush table 51820
PostDown = sysctl -w net.ipv4.conf.all.rp_filter=1
"
        echo -e "$inputDocker" >> "$target_path"
        
    else
        print_info "Applying non-Docker network rules..."
        
        local killswitchNonDocker=""
        if [[ "$PLATFORM" == "raspiblitz" ]]; then
            killswitchNonDocker="PostUp = nft insert rule ip %i nat skuid bitcoin fib  daddr type != local ip daddr != {$localNetworks}  meta oifname != %i  meta l4proto { tcp, udp } th dport != { 51820 } counter drop\n"
        fi
        
        local inputNonDocker="

#Tunnelsats-Setupv2-Non-Docker

[Interface]
FwMark = 0x2000000
Table = off


PostUp = while [ \$(ip rule | grep -c suppress_prefixlength) -gt 0 ]; do ip rule del from all table  main suppress_prefixlength 0;done
PostUp = while [ \$(ip rule | grep -c 0x1000000) -gt 0 ]; do ip rule del from all fwmark 0x1000000/0xff000000 table  51820;done

PostUp = ip rule add from all fwmark 0x1000000/0xff000000 table 51820;ip rule add from all table main suppress_prefixlength 0
PostUp = ip route add default dev %i table 51820;
PostUp = ip route add  10.9.0.0/24 dev %i  proto kernel scope link; ping -c1 10.9.0.1
PostUp = sysctl -w net.ipv4.conf.all.rp_filter=0
PostUp = sysctl -w net.ipv6.conf.all.disable_ipv6=1
PostUp = sysctl -w net.ipv6.conf.default.disable_ipv6=1

PostUp = nft add table ip %i
PostUp = nft add chain ip %i prerouting '{type filter hook prerouting priority mangle -1; policy accept;}'; nft add rule ip %i prerouting meta mark set ct mark
PostUp = nft add chain ip %i mangle '{type route hook output priority mangle -1; policy accept;}'; nft add rule ip %i mangle tcp sport != { 8080, 10009 } meta mark and 0xff000000 != 0x2000000 meta cgroup 1118498 meta mark set mark and 0x00ffffff xor 0x1000000
PostUp = nft add chain ip %i nat'{type nat hook postrouting priority srcnat -1; policy accept;}'; nft insert rule ip %i nat  fib daddr type != local  ip daddr != {$localNetworks} oifname != %i ct mark and 0xff000000 == 0x1000000 drop;nft add rule ip %i nat oifname %i ct mark and 0xff000000 == 0x1000000 masquerade
${killswitchNonDocker}PostUp = nft add chain ip %i postroutingmangle'{type filter hook postrouting priority mangle -1; policy accept;}'; nft add rule ip %i postroutingmangle meta mark and 0xff000000 == 0x1000000 ct mark set meta mark and 0x00ffffff xor 0x1000000 
PostUp = nft add chain ip %i input'{type filter hook input priority filter -1; policy accept;}'; nft add rule ip %i input iifname %i  ct state established,related counter accept; nft add rule ip %i input iifname %i tcp dport != 9735 counter drop; nft add rule ip %i input iifname %i udp dport != 9735 counter drop


PostDown = nft delete table ip %i
PostDown = ip rule del from all table  main suppress_prefixlength 0; ip rule del from all fwmark 0x1000000/0xff000000 table 51820
PostDown = ip route flush table 51820
PostDown = sysctl -w net.ipv4.conf.all.rp_filter=1
"
        echo -e "$inputNonDocker" >> "$target_path"
    fi
    
    # Verify rules were applied
    if grep -q "Tunnelsats-Setupv2" "$target_path"; then
        print_success "Network rules applied"
    else
        print_error "Network rules not applied"
        exit 1
    fi
}

setup_cgroups() {
    print_info "Creating cgroup for traffic splitting..."
    
    # Create cgroup script
    cat > /etc/wireguard/tunnelsats-create-cgroup.sh << 'EOF'
#!/bin/sh
set -e
dir_netcls="/sys/fs/cgroup/net_cls"
splitted_processes="/sys/fs/cgroup/net_cls/splitted_processes"

if [ ! -d "$dir_netcls" ]; then
    mkdir $dir_netcls
    mount -t cgroup -o net_cls none $dir_netcls
    echo "> Successfully added cgroup net_cls subsystem"
fi

if [ ! -d "$splitted_processes" ]; then
    mkdir /sys/fs/cgroup/net_cls/splitted_processes
    echo 1118498 > /sys/fs/cgroup/net_cls/splitted_processes/net_cls.classid
    chmod 666 /sys/fs/cgroup/net_cls/splitted_processes/tasks
    echo "> Successfully added Mark for net_cls subsystem"
else
    echo "> Mark for net_cls subsystem already present"
fi
EOF
    
    chmod +x /etc/wireguard/tunnelsats-create-cgroup.sh
    /etc/wireguard/tunnelsats-create-cgroup.sh
    
    # Create systemd service for cgroup
    cat > /etc/systemd/system/tunnelsats-create-cgroup.service << 'EOF'
[Unit]
Description=Creating cgroup for Splitting lightning traffic
StartLimitInterval=200
StartLimitBurst=5
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/wireguard/tunnelsats-create-cgroup.sh
[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable tunnelsats-create-cgroup.service
   systemctl start tunnelsats-create-cgroup.service
    
    print_success "Cgroups configured"
}

setup_docker_network() {
    print_info "Setting up Docker tunnelsats network..."
    
    # Create Docker network
    local dockersubnet="10.9.9.0/25"
    if ! docker network ls 2>/dev/null | grep -q "docker-tunnelsats"; then
        docker network create "docker-tunnelsats" --subnet $dockersubnet \
            -o "com.docker.network.driver.mtu"="1420" &>/dev/null && \
            print_success "Docker network created" || \
            { print_error "Failed to create Docker network"; exit 1; }
    else
        print_info "Docker network already exists"
    fi
    
    # Clean routing tables from prior failed starts
    local delrule1=$(ip rule | grep -c "from all lookup main suppress_prefixlength 0" || echo "0")
    local delrule2=$(ip rule | grep -c "from $dockersubnet lookup 51820" || echo "0")
    
    for i in $(seq 1 $delrule1); do
        ip rule del from all table main suppress_prefixlength 0 2>/dev/null || true
    done
    
    for i in $(seq 1 $delrule2); do
        ip rule del from $dockersubnet table 51820 2>/dev/null || true
    done
    
    ip route flush table 51820 &>/dev/null || true
    
    # Create Docker network monitor script
    cat > /etc/wireguard/tunnelsats-docker-network.sh <<'EOF'
#!/bin/sh
lightningcontainer=$(docker ps --format 'table {{.Image}} {{.Names}} {{.Ports}}' | grep 0.0.0.0:9735 | awk '{print $2}')
checkdockernetwork=$(docker network ls 2> /dev/null | grep -c "docker-tunnelsats")

if [ $checkdockernetwork -eq 0 ]; then
  if ! docker network create "docker-tunnelsats" --subnet "10.9.9.0/25" -o "com.docker.network.driver.mtu"="1420" > /dev/null; then
    exit 1
  fi
fi

if [ ! -z $lightningcontainer ]; then
  inspectlncontainer=$(docker inspect $lightningcontainer | grep -c "tunnelsats")
  if [ $inspectlncontainer -eq 0 ]; then
    if ! docker network connect --ip 10.9.9.9 docker-tunnelsats $lightningcontainer > /dev/null; then
      exit 1
    fi
  fi
fi
exit 0
EOF
    
    chmod +x /etc/wireguard/tunnelsats-docker-network.sh
    bash /etc/wireguard/tunnelsats-docker-network.sh
    
    # Create systemd service and timer
    cat > /etc/systemd/system/tunnelsats-docker-network.service <<'EOF'
[Unit]
Description=Adding Lightning Container to the tunnel
StartLimitInterval=200
StartLimitBurst=5
[Service]
Type=oneshot
ExecStart=/bin/bash /etc/wireguard/tunnelsats-docker-network.sh
[Install]
WantedBy=multi-user.target
EOF
    
    cat > /etc/systemd/system/tunnelsats-docker-network.timer <<'EOF'
[Unit]
Description=5min timer for tunnelsats-docker-network.service
[Timer]
OnBootSec=60
OnUnitActiveSec=60
Persistent=true
[Install]
WantedBy=timers.target
EOF
    
    systemctl daemon-reload
    systemctl enable tunnelsats-docker-network.service
    systemctl start tunnelsats-docker-network.service
    systemctl enable tunnelsats-docker-network.timer
    systemctl start tunnelsats-docker-network.timer
    
    print_success "Docker network configured"
}

configure_lightning() {
    print_info "Configuring ${LN_IMPL} for tunneling..."
    
    # Deactivate RaspiBlitz config checks if present
    if [[ "$LN_IMPL" == "lnd" ]] && [[ -f /home/admin/config.scripts/lnd.check.sh ]]; then
        mv /home/admin/config.scripts/lnd.check.sh /home/admin/config.scripts/lnd.check.bak
        print_info "RaspiBlitz lnd.check deactivated"
    elif [[ "$LN_IMPL" == "cln" ]] && [[ -f /home/admin/config.scripts/cl.check.sh ]]; then
        mv /home/admin/config.scripts/cl.check.sh /home/admin/config.scripts/cl.check.bak
        print_info "RaspiBlitz cl.check deactivated"
    fi
    
    # For non-Docker setups, modify systemd service to use cgexec
    if [[ "$PLATFORM" != "umbrel" ]]; then
        local service_file=""
        
        case "$LN_IMPL" in
            lnd)
                service_file="/etc/systemd/system/lnd.service"
                # Add cgroup dependency
                if [[ ! -d /etc/systemd/system/lnd.service.d ]]; then
                    mkdir -p /etc/systemd/system/lnd.service.d
                fi
                cat > /etc/systemd/system/lnd.service.d/tunnelsats-cgroup.conf << EOF
#Don't edit this file its generated by tunnelsats scripts
[Unit]
Description=lnd service - powered by tunnelsats
Requires=tunnelsats-create-cgroup.service
After=tunnelsats-create-cgroup.service
Requires=wg-quick@tunnelsatsv2.service
After=wg-quick@tunnelsatsv2.service
EOF
                ;;
            cln)
                service_file="/etc/systemd/system/lightningd.service"
                # Add cgroup dependency
                if [[ ! -d /etc/systemd/system/lightningd.service.d ]]; then
                    mkdir -p /etc/systemd/system/lightningd.service.d
                fi
                cat > /etc/systemd/system/lightningd.service.d/tunnelsats-cgroup.conf << EOF
#Don't edit this file its generated by tunnelsats scripts
[Unit]
Description=lightningd service - powered by tunnelsats
Requires=tunnelsats-create-cgroup.service
After=tunnelsats-create-cgroup.service
Requires=wg-quick@tunnelsatsv2.service
After=wg-quick@tunnelsatsv2.service
EOF
                ;;
            lit)
                service_file="/etc/systemd/system/lit.service"
                # Add cgroup dependency
                if [[ ! -d /etc/systemd/system/lit.service.d ]]; then
                    mkdir -p /etc/systemd/system/lit.service.d
                fi
                cat > /etc/systemd/system/lit.service.d/tunnelsats-cgroup.conf << EOF
#Don't edit this file its generated by tunnelsats scripts
[Unit]
Description=lit service - powered by tunnelsats
Requires=tunnelsats-create-cgroup.service
After=tunnelsats-create-cgroup.service
Requires=wg-quick@tunnelsatsv2.service
After=wg-quick@tunnelsatsv2.service
EOF
                ;;
        esac
        
        # Modify service to start with cgexec
        if [[ -f "$service_file" ]]; then
            if [[ ! -f "${service_file}.bak" ]]; then
                cp "$service_file" "${service_file}.bak"
            fi
            
            if ! grep -q "cgexec" "$service_file"; then
                sed -i 's/ExecStart=/ExecStart=\/usr\/bin\/cgexec -g net_cls:splitted_processes /g' "$service_file"
                print_success "${LN_IMPL} service updated to use cgroup"
            else
                print_info "${LN_IMPL} service already uses cgroup"
            fi
        fi
        
        systemctl daemon-reload
    fi
    
    # Don't auto-modify configs - too risky and platform-dependent
    # Instructions will be shown at the end of installation
    :
    
    # Create splitting processes script (non-Docker)
    if [[ "$PLATFORM" != "umbrel" ]]; then
        cat > /etc/wireguard/tunnelsats-splitting-processes.sh << 'EOF'
#!/bin/sh
# add Lightning pid(s) to cgroup
pgrep -x lnd | xargs -I % sh -c 'echo % >> /sys/fs/cgroup/net_cls/splitted_processes/tasks' &> /dev/null
pgrep -x lightningd | xargs -I % sh -c 'echo % >> /sys/fs/cgroup/net_cls/splitted_processes/tasks' &> /dev/null
count=$(cat /sys/fs/cgroup/net_cls/splitted_processes/tasks | wc -l)
if [ $count -eq 0 ];then
  echo "> no available lightning processes available for tunneling"
else
  echo "> ${count} Process(es) successfully excluded"
fi
EOF
        chmod +x /etc/wireguard/tunnelsats-splitting-processes.sh
        
        # Create systemd service for splitting processes
        cat > /etc/systemd/system/tunnelsats-splitting-processes.service << EOF
[Unit]
Description=Adding Lightning Process to the tunnel
[Service]
Type=oneshot
ExecStart=/bin/bash /etc/wireguard/tunnelsats-splitting-processes.sh
[Install]
WantedBy=multi-user.target
EOF
        
        # Create timer
        cat > /etc/systemd/system/tunnelsats-splitting-processes.timer << EOF
[Unit]
Description=1min timer for tunnelsats-splitting-processes.service
[Timer]
OnBootSec=10
OnUnitActiveSec=10
Persistent=true
[Install]
WantedBy=timers.target
EOF
        
        systemctl daemon-reload
        systemctl enable tunnelsats-splitting-processes.service
        systemctl start tunnelsats-splitting-processes.service
        systemctl enable tunnelsats-splitting-processes.timer
        systemctl start tunnelsats-splitting-processes.timer
        
        print_success "Splitting processes service configured"
    fi
    
    # RaspiBlitz blitzapi dependency
    if [[ -f /etc/systemd/system/blitzapi.service ]]; then
        if [[ ! -d /etc/systemd/system/blitzapi.service.d ]]; then
            mkdir -p /etc/systemd/system/blitzapi.service.d
        fi
        cat > /etc/systemd/system/blitzapi.service.d/tunnelsats-wg.conf << EOF
#Don't edit this file its generated by tunnelsats scripts
[Unit]
Description=blitzapi needs the wg service before it can start successfully
Requires=wg-quick@tunnelsatsv2.service
After=wg-quick@tunnelsatsv2.service
EOF
        systemctl daemon-reload
    fi
    
    print_success "${LN_IMPL} configured for tunneling"
}



enable_services() {
    print_info "Enabling WireGuard service..."
    
    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable wg-quick@${WG_INTERFACE} > /dev/null 2>&1 && \
        print_success "WireGuard service enabled" || \
        { print_error "Failed to enable service"; exit 1; }
    
    print_info "Starting WireGuard..."
    systemctl start wg-quick@${WG_INTERFACE} > /dev/null 2>&1 && \
        print_success "WireGuard service started" || \
        { print_error "Failed to start service"; exit 1; }
}

verify_installation() {
    if systemctl is-active --quiet wg-quick@${WG_INTERFACE}; then
        print_success "WireGuard service is running"
    else
        print_error "WireGuard service is not running"
        exit 1
    fi
    
    if wg show ${WG_INTERFACE} &>/dev/null; then
        print_success "WireGuard tunnel is active"
    else
        print_warning "WireGuard tunnel not detected (may be starting)"
    fi
}

cmd_uninstall() {
    print_header "Uninstall Wizard"
    
    echo ""
    print_warning "This will STOP your Lightning node and remove TunnelSats!"
    echo ""
    echo "This uninstaller will:"
    echo "  • Stop Lightning services"
    echo "  • Remove TunnelSats configurations"
    echo "  • Restore backup files"
    echo "  • Clean up systemd services"
    echo "  • Restore hybrid mode to Tor-only"
    echo ""
    
    # Triple confirmation
    read -p "Do you really want to proceed? Type 'UNINSTALL' to confirm: " -r
    echo ""
    if [[ "$REPLY" != "UNINSTALL" ]]; then
        print_info "Uninstall cancelled"
        exit 0
    fi
    
    # Detect platform
    echo "What platform are you running?"
    echo "  1) RaspiBlitz"
    echo "  2) Umbrel"
    echo "  3) myNode"
    echo "  4) RaspiBolt / Bare Metal"
    read -p "Select [1-4]: " platform_choice
    
    case $platform_choice in
        1) PLATFORM="raspiblitz" ;;
        2) PLATFORM="umbrel" ;;
        3) PLATFORM="mynode" ;;
        4) PLATFORM="baremetal" ;;
        *) print_error "Invalid selection"; exit 1 ;;
    esac
    
    # Detect Lightning implementation
    echo ""
    echo "Which Lightning implementation was tunneled?"
    echo "  1) LND"
    echo "  2) CLN"
    read -p "Select [1-2]: " ln_choice
    
    case $ln_choice in
        1) LN_IMPL="lnd" ;;
        2) LN_IMPL="cln" ;;
        *) print_error "Invalid selection"; exit 1 ;;
    esac
    
    echo ""
    print_step 1 7 "Stopping Lightning services..."
    stop_lightning_services
    echo ""
    
    print_step 2 7 "Restoring hybrid mode configuration..."
    restore_hybrid_mode
    echo ""
    
    print_step 3 7 "Removing splitting services..."
    remove_splitting_services
    echo ""
    
    print_step 4 7 "Removing WireGuard service..."
    remove_wireguard_service
    echo ""
    
    print_step 5 7 "Cleaning up systemd dependencies..."
    cleanup_systemd_dependencies
    echo ""
    
    print_step 6 7 "Removing Docker network (if applicable)..."
    remove_docker_network
    echo ""
    
    print_step 7 7 "Restoring Lightning service files..."
    restore_lightning_services
    echo ""
    
    # Optional package removal
    echo ""
    if [[ "$PLATFORM" == "umbrel" ]]; then
        read -p "Uninstall nftables and wireguard packages? (Y/N) " -n 1 -r
    else
        read -p "Uninstall cgroup-tools, nftables and wireguard packages? (Y/N) " -n 1 -r
    fi
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [[ "$PLATFORM" == "umbrel" ]]; then
            apt-get remove -yqq nftables wireguard-tools &>/dev/null && \
                print_success "Packages removed"
        else
            apt-get remove -yqq cgroup-tools nftables wireguard-tools &>/dev/null && \
                print_success "Packages removed"
        fi
    else
        print_info "Keeping packages installed"
    fi
    
    # Success
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "TunnelSats uninstalled successfully!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Double check hybrid mode in your Lightning config:"
    if [[ "$LN_IMPL" == "lnd" ]]; then
        echo "   LND: tor.skip-proxy-for-clearnet-targets=false"
    else
        echo "   CLN: always-use-proxy=true"
    fi
    echo ""
    echo "2. Restart your Lightning node:"
    if [[ "$PLATFORM" == "umbrel" ]]; then
        echo "   sudo systemctl restart umbrel.service"
    else
        local service_name="${LN_IMPL}"
        [[ "$LN_IMPL" == "cln" ]] && service_name="lightningd"
        echo "   sudo systemctl restart ${service_name}.service"
    fi
    echo ""
}

# Uninstall helper functions

stop_lightning_services() {
    if [[ "$PLATFORM" == "umbrel" ]]; then
        local container=$(docker ps --format 'table {{.Image}} {{.Names}} {{.Ports}}' | grep 9735 | awk '{print $2}')
        if [[ -n "$container" ]]; then
            docker stop "$container" &>/dev/null && \
                docker network disconnect docker-tunnelsats "$container" &>/dev/null
            docker rm "$container" &>/dev/null
            print_success "Stopped and removed Lightning container"
        else
            print_info "No active Lightning container found"
        fi
    else
        local service_name="${LN_IMPL}"
        [[ "$LN_IMPL" == "cln" ]] && service_name="lightningd"
        
        if systemctl is-active --quiet ${service_name}.service; then
            systemctl stop ${service_name}.service &>/dev/null && \
                print_success "Stopped ${service_name}.service"
        else
            print_info "${service_name}.service not running"
        fi
    fi
}

restore_hybrid_mode() {
    if [[ "$LN_IMPL" == "lnd" ]]; then
        # Find and restore LND config
        for conf in /mnt/hdd/lnd/lnd.conf /data/lnd/lnd.conf /mnt/hdd/mynode/lnd/lnd.conf ~/umbrel/app-data/lightning/data/lnd/lnd.conf; do
            if [[ -f "$conf" ]]; then
                if grep -q "tor.skip-proxy-for-clearnet-targets" "$conf"; then
                    sed -i "/tor.skip-proxy-for-clearnet-targets/d" "$conf"
                    print_success "Disabled LND hybrid mode in $conf"
                fi
            fi
        done
    elif [[ "$LN_IMPL" == "cln" ]]; then
        # Find and restore CLN config
        for conf in /mnt/hdd/app-data/.lightning/config /data/lightningd/config ~/umbrel/app-data/core-lightning/data/lightningd/bitcoin/config; do
            if [[ -f "$conf" ]]; then
                if grep -q "always-use-proxy=false" "$conf"; then
                    sed -i 's/always-use-proxy=false/always-use-proxy=true/g' "$conf"
                    sed -i 's/always-use-proxy=0/always-use-proxy=1/g' "$conf"
                    print_success "Restored CLN Tor-only mode in $conf"
                fi
                
                # Umbrel CLN specific cleanup
                if [[ "$conf" == *"umbrel"* ]]; then
                    sed -i '/^bind-addr=/d' "$conf" 2>/dev/null
                    sed -i '/^announce-addr=/d' "$conf" 2>/dev/null
                fi
            fi
        done
        
        # Restore Umbrel CLN port
        if [[ -f ~/umbrel/app-data/core-lightning/exports.sh ]]; then
            sed -i 's/APP_CORE_LIGHTNING_DAEMON_PORT="9735"/APP_CORE_LIGHTNING_DAEMON_PORT="9736"/g' \
                ~/umbrel/app-data/core-lightning/exports.sh
        fi
    fi
    
    # Restore RaspiBlitz config checks
    if [[ -f /home/admin/config.scripts/lnd.check.bak ]]; then
        mv /home/admin/config.scripts/lnd.check.bak /home/admin/config.scripts/lnd.check.sh
        print_info "Restored RaspiBlitz lnd.check"
    fi
    if [[ -f /home/admin/config.scripts/cl.check.bak ]]; then
        mv /home/admin/config.scripts/cl.check.bak /home/admin/config.scripts/cl.check.sh
        print_info "Restored RaspiBlitz cl.check"
    fi
}

remove_splitting_services() {
    if [[ "$PLATFORM" != "umbrel" ]]; then
        # Remove splitting processes timer and service
        for service in tunnelsats-splitting-processes.timer tunnelsats-splitting-processes.service; do
            if [[ -f /etc/systemd/system/$service ]]; then
                systemctl stop $service &>/dev/null
                systemctl disable $service &>/dev/null
                rm /etc/systemd/system/$service
            fi
        done
        
        # Remove cgroup service
        if [[ -f /etc/systemd/system/tunnelsats-create-cgroup.service ]]; then
            systemctl stop tunnelsats-create-cgroup.service &>/dev/null
            systemctl disable tunnelsats-create-cgroup.service &>/dev/null
            rm /etc/systemd/system/tunnelsats-create-cgroup.service
        fi
        
        # Remove cgroup
        if [[ -d /sys/fs/cgroup/net_cls/splitted_processes ]]; then
            cgdelete net_cls:/splitted_processes 2>/dev/null
        fi
        
        print_success "Removed splitting services"
    else
        # Docker: Remove network services
        for service in tunnelsats-docker-network.timer tunnelsats-docker-network.service; do
            if [[ -f /etc/systemd/system/$service ]]; then
                systemctl stop $service &>/dev/null
                systemctl disable $service &>/dev/null
                rm /etc/systemd/system/$service
            fi
        done
        
        # Remove killswitch configs
        if [[ -f /etc/systemd/system/umbrel.service.d/tunnelsats_killswitch.conf ]]; then
            rm /etc/systemd/system/umbrel.service.d/tunnelsats_killswitch.conf
        fi
        if [[ -f /etc/systemd/system/umbrel-startup.service.d/tunnelsats_killswitch.conf ]]; then
            rm /etc/systemd/system/umbrel-startup.service.d/tunnelsats_killswitch.conf
        fi
        
        print_success "Removed Docker network services"
    fi
}

remove_wireguard_service() {
    # Stop and disable WireGuard
    systemctl stop wg-quick@tunnelsatsv2 &>/dev/null
    systemctl disable wg-quick@tunnelsatsv2 &>/dev/null
    
    # Remove DNS resolver service
    if [[ -f /etc/systemd/system/tunnelsats-resolve-dns-wg.service ]]; then
        systemctl stop tunnelsats-resolve-dns-wg.service &>/dev/null
        systemctl disable tunnelsats-resolve-dns-wg.service &>/dev/null
        rm /etc/systemd/system/tunnelsats-resolve-dns-wg.service
    fi
    if [[ -f /etc/systemd/system/tunnelsats-resolve-dns-wg.timer ]]; then
        systemctl stop tunnelsats-resolve-dns-wg.timer &>/dev/null
        systemctl disable tunnelsats-resolve-dns-wg.timer &>/dev/null
        rm /etc/systemd/system/tunnelsats-resolve-dns-wg.timer
    fi
    
    # Remove WireGuard config override directory
    if [[ -d /etc/systemd/system/wg-quick@tunnelsatsv2.service.d ]]; then
        rm -r /etc/systemd/system/wg-quick@tunnelsatsv2.service.d
    fi
    
    print_success "Removed WireGuard services"
}

cleanup_systemd_dependencies() {
    # Remove Lightning service dependencies
    for dir in /etc/systemd/system/lnd.service.d \
               /etc/systemd/system/lightningd.service.d \
               /etc/systemd/system/lit.service.d \
               /etc/systemd/system/blitzapi.service.d; do
        if [[ -f $dir/tunnelsats-cgroup.conf ]]; then
            rm $dir/tunnelsats-cgroup.conf
        fi
        if [[ -f $dir/tunnelsats-wg.conf ]]; then
            rm $dir/tunnelsats-wg.conf
        fi
    done
    
    systemctl daemon-reload
    print_success "Cleaned up systemd dependencies"
}

remove_docker_network() {
    if [[ "$PLATFORM" == "umbrel" ]]; then
        # Flush routing tables
        ip route flush table 51820 &>/dev/null
        
        # Disconnect containers from docker-tunnelsats network
        if docker network inspect docker-tunnelsats &>/dev/null; then
            docker inspect docker-tunnelsats | jq '.[].Containers' | grep Name | \
                sed 's/[",]//g' | awk '{print $2}' | \
                xargs -I % sh -c 'docker network disconnect docker-tunnelsats % 2>/dev/null'
        fi
        
        # Remove network
        if docker network ls 2>/dev/null | grep -q "docker-tunnelsats"; then
            docker network rm docker-tunnelsats &>/dev/null && \
                print_success "Removed docker-tunnelsats network"
        fi
        
        # Restore nftables
        if [[ -f /etc/nftablespriortunnelsats.backup ]]; then
            mv /etc/nftablespriortunnelsats.backup /etc/nftables.conf
            print_info "Restored prior nftables.conf"
        fi
        
        # Remove TunnelSats nftables
        nft delete table ip tunnelsatsv2 &>/dev/null
        nft delete table inet tunnelsatsv2 &>/dev/null
        
        # Restart Docker
        systemctl daemon-reload
        systemctl restart docker &>/dev/null
        print_success "Docker services restarted"
    else
        print_info "Skipping Docker cleanup (non-Docker setup)"
    fi
}

restore_lightning_services() {
    if [[ "$PLATFORM" != "umbrel" ]]; then
        # Restore LND service
        if [[ -f /etc/systemd/system/lnd.service.bak ]] && [[ "$LN_IMPL" == "lnd" ]]; then
            mv /etc/systemd/system/lnd.service.bak /etc/systemd/system/lnd.service
            print_success "Restored lnd.service from backup"
        fi
        
        # Restore CLN service
        if [[ -f /etc/systemd/system/lightningd.service.bak ]] && [[ "$LN_IMPL" == "cln" ]]; then
            mv /etc/systemd/system/lightningd.service.bak /etc/systemd/system/lightningd.service
            print_success "Restored lightningd.service from backup"
        fi
        
        # Restore LIT service
        if [[ -f /etc/systemd/system/lit.service.bak ]]; then
            mv /etc/systemd/system/lit.service.bak /etc/systemd/system/lit.service
            print_success "Restored lit.service from backup"
        fi
        
        systemctl daemon-reload
    fi
}

cmd_status() {
    print_header "Subscription Status"
    
    echo ""
    
    # Find active config file (supports old and new formats)
    local config_file
    config_file=$(find_active_wg_config)
    if [[ $? -ne 0 ]] || [[ -z "$config_file" ]]; then
        print_error "No TunnelSats configuration found"
        echo ""
        echo "Expected locations:"
        echo "  • /etc/wireguard/tunnelsatsv2.conf (old format)"
        echo "  • /etc/wireguard/tunnelsats-*.conf (new format)"
        exit 1
    fi
    
    # Extract interface name from config filename
    local interface_name=$(basename "$config_file" .conf)
    
    # Check if WireGuard is running
    if ! systemctl is-active --quiet wg-quick@${interface_name}; then
        print_error "WireGuard service is not running"
        echo ""
        echo "Start it with: sudo systemctl start wg-quick@${interface_name}"
        exit 1
    fi
    
    # Get WireGuard details
    local wg_info=$(wg show ${interface_name} 2>/dev/null)
    if [[ -z "$wg_info" ]]; then
        print_error "WireGuard tunnel '${interface_name}' not found"
        exit 1
    fi
    
    # Parse WireGuard info
    local public_key=$(echo "$wg_info" | grep "public key" | awk '{print $3}')
    local endpoint=$(echo "$wg_info" | grep "endpoint" | awk '{print $2}')
    local latest_handshake=$(echo "$wg_info" | grep "latest handshake" | sed 's/latest handshake: //')
    local transfer=$(echo "$wg_info" | grep "transfer")
    local transfer_rx=$(echo "$transfer" | awk '{print $2, $3}')
    local transfer_tx=$(echo "$transfer" | awk '{print $5, $6}')
    
    # Display tunnel info
    echo -e "${BOLD}WireGuard Tunnel${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Config: $(basename "$config_file")"
    echo "  Public Key: ${public_key:0:20}...${public_key: -20}"
    echo "  Endpoint: $endpoint"
    echo "  Last Handshake: $latest_handshake"
    echo "  Transfer: ↓ $transfer_rx / ↑ $transfer_tx"
    
    # Check handshake freshness
    if [[ "$latest_handshake" == *"minute"* ]] || [[ "$latest_handshake" == *"second"* ]]; then
        print_success "Tunnel is active"
    elif [[ "$latest_handshake" == *"hour"* ]] || [[ "$latest_handshake" == *"day"* ]]; then
        print_warning "Tunnel may be stale (old handshake)"
    else
        print_error "No recent handshake"
    fi
    echo ""
    
    # Get VPN port from config (supports both old and new formats)
    local vpn_port=$(parse_config_metadata "$config_file" "port")
    if [[ -z "$vpn_port" ]]; then
        vpn_port="<unknown>"
    fi
    
    # Display subscription info
    echo -e "${BOLD}Subscription Details${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  VPN Port: $vpn_port"
    
    # Try to get subscription end date (supports both formats)
    local sub_end=$(parse_config_metadata "$config_file" "expiry")
    if [[ -n "$sub_end" ]]; then
        echo "  Expires: $sub_end"
    fi
    
    # Show user's public key if available
    local user_pubkey=$(parse_config_metadata "$config_file" "pubkey")
    if [[ -n "$user_pubkey" ]] && [[ "$user_pubkey" != "<user's-public-key>" ]]; then
        echo "  My PubKey: ${user_pubkey:0:20}...${user_pubkey: -20}"
    fi
    echo ""
    
    # Outbound connectivity check
    echo -e "${BOLD}Outbound Connectivity${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Detect if Docker or non-Docker
    local is_docker=0
    if docker ps &>/dev/null && docker ps | grep -q "9735"; then
        is_docker=1
    fi
    
    if [[ $is_docker -eq 1 ]]; then
        # Docker setup - test from inside container
        local container=$(docker ps --format 'table {{.Image}} {{.Names}} {{.Ports}}' | grep 9735 | awk '{print $2}')
        if [[ -n "$container" ]]; then
            local outbound_ip=$(docker exec "$container" curl -s --connect-timeout 5 ifconfig.me 2>/dev/null)
            if [[ -n "$outbound_ip" ]] && valid_ipv4 "$outbound_ip"; then
                print_success "Container: $outbound_ip"
            else
                print_error "Container: Failed to get IP"
            fi
        fi
    else
        # Non-Docker - test with cgexec
        local outbound_ip=$(cgexec -g net_cls:splitted_processes curl -s --connect-timeout 5 ifconfig.me 2>/dev/null)
        if [[ -n "$outbound_ip" ]] && valid_ipv4 "$outbound_ip"; then
            print_success "cgexec: $outbound_ip"
        else
            print_error "cgexec: Failed to get IP"
        fi
    fi
    echo ""
    
    # Inbound connectivity check
    echo -e "${BOLD}Inbound Connectivity${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [[ -n "$outbound_ip" ]] && valid_ipv4 "$outbound_ip" && [[ -n "$vpn_port" ]] && [[ "$vpn_port" != "<unknown>" ]]; then
        # Test if port is open
        local port_check=$(timeout 5 bash -c "echo >/dev/tcp/$outbound_ip/$vpn_port" 2>&1)
        if [[ $? -eq 0 ]]; then
            print_success "Port $vpn_port is reachable"
        else
            print_warning "Port $vpn_port test inconclusive"
            echo "  (This doesn't necessarily mean there's a problem)"
        fi
    else
        print_info "Skipping inbound test (missing IP or port)"
    fi
    echo ""
    
    # Lightning node info
    echo -e "${BOLD}Lightning Node${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Try to get node pubkey
    local node_pubkey=""
    if command -v lncli &>/dev/null; then
        node_pubkey=$(lncli getinfo 2>/dev/null | grep "identity_pubkey" | awk '{print $2}' | tr -d '",')
    elif command -v lightning-cli &>/dev/null; then
        node_pubkey=$(lightning-cli getinfo 2>/dev/null | grep "\"id\"" | awk '{print $2}' | tr -d '",')
    fi
    
    if [[ -n "$node_pubkey" ]] && [[ -n "$outbound_ip" ]] && [[ "$vpn_port" != "<unknown>" ]]; then
        local node_address="${node_pubkey}@${outbound_ip}:${vpn_port}"
        echo "  Address: $node_address"
        print_success "Ready to announce"
    elif [[ -n "$node_pubkey" ]]; then
        echo "  Pubkey: ${node_pubkey:0:20}...${node_pubkey: -20}"
        print_warning "Missing VPN connection details"
    else
        print_info "Unable to retrieve node info (LND/CLN not accessible)"
    fi
    echo ""
    
    # Overall status
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [[ "$latest_handshake" == *"minute"* ]] || [[ "$latest_handshake" == *"second"* ]]; then
        if [[ -n "$outbound_ip" ]] && valid_ipv4 "$outbound_ip"; then
            print_success "All systems operational!"
            echo ""
            echo "Your node is tunneled through TunnelSats ⚡"
        else
            print_warning "Tunnel active but connectivity issues detected"
            echo ""
            echo "Troubleshooting:"
            echo "  • Check Lightning node is running"
            echo "  • Verify cgroups/Docker network configuration"
        fi
    else
        print_error "Tunnel connection issues detected"
        echo ""
        echo "Troubleshooting:"
        echo "  • Check endpoint is reachable"
        echo "  • Verify WireGuard config is correct"
        echo "  • Restart: sudo systemctl restart wg-quick@tunnelsatsv2"
    fi
    echo ""
    
    # Helpful links
    echo "Resources:"
    echo "  • Guide: https://tunnelsats.com/guide"
    echo "  • Test Bot: https://t.me/TunnelSatsBot"
    echo "  • Support: https://t.me/tunnelsats"
    echo ""
}

#══════════════════════════════════════════════════════════════════════════
# ARGUMENT PARSING
#══════════════════════════════════════════════════════════════════════════

parse_args() {
    local command=""
    
    # Parse command
    if [[ $# -eq 0 ]]; then
        cmd_help
        exit 0
    fi
    
    command="$1"
    shift
    
    # Parse options for install command
    if [[ "$command" == "install" ]]; then
        while [[ $# -gt 0 ]]; do
            case $1 in
                --config)
                    CONFIG_FILE="$2"
                    shift 2
                    ;;
                *)
                    print_error "Unknown option: $1"
                    cmd_help
                    exit 1
                    ;;
            esac
        done
    fi
    
    # Dispatch command
    case "$command" in
        install)
            check_root "$@"
            cmd_install
            ;;
        pre-check|precheck|check)
            check_root "$@"
            cmd_pre_check
            ;;
        uninstall|remove)
            check_root "$@"
            cmd_uninstall
            ;;
        status)
            check_root "$@"
            cmd_status
            ;;
        help|-h|--help)
            cmd_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

#══════════════════════════════════════════════════════════════════════════
# MAIN ENTRY POINT
#══════════════════════════════════════════════════════════════════════════

main() {
    parse_args "$@"
}

# Run the script
main "$@"
