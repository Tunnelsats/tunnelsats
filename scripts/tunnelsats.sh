#!/bin/bash
# TunnelSats Unified Setup Tool
# Consolidates install, pre-check, uninstall, and status commands
#
# Usage: sudo bash tunnelsats.sh [command] [options]

set -e  # Exit on error

# ---------------------------------------------------------------------------
# GLOBAL VARIABLES
# ---------------------------------------------------------------------------

VERSION="3.0beta"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
PLATFORM=""
LN_IMPL=""

# ---------------------------------------------------------------------------
# COLOR & FORMATTING FUNCTIONS
# ---------------------------------------------------------------------------

# ANSI Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color


print_line() {
    local char="${1:-━}"
    local count="${2:-42}"
    printf "%0.s${char}" $(seq 1 $count)
    echo ""
}

print_header() {
    local subtitle="$1"
    local title="Tunnel⚡Sats Setup Tool v${VERSION}"
    local width=42
    
    # Calculate padding for Title
    local title_len=${#title}
    local title_padding=$(( (width - title_len) / 2 ))
    local sub_padding=$(( (width - ${#subtitle}) / 2 ))
    
    echo -e "${BOLD}${BLUE}"
    printf "╔"; print_line "═" "$width" | tr -d '\n'; echo "╗"
    printf "║%*s%s%*s║\n" $title_padding "" "$title" $((width - title_padding - title_len)) ""
    printf "║%*s%s%*s║\n" $sub_padding "" "$subtitle" $((width - sub_padding - ${#subtitle})) ""
    printf "╚"; print_line "═" "$width" | tr -d '\n'; echo "╝"
    echo -e "${NC}"
}



print_success() {
    echo -e "${GREEN}✓${NC} $1" >&2
}

print_error() {
    echo -e "${RED}✗${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}⚠${NC}  $1" >&2
}

print_info() {
    echo -e "${BLUE}→${NC} $1" >&2
}

print_step() {
    echo -e "${BOLD}[$1/$2]${NC} $3" >&2
}

# ---------------------------------------------------------------------------
# COMMON UTILITY FUNCTIONS
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# CONFIG FILE DETECTION
# ---------------------------------------------------------------------------

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
    echo "" >&2
    print_info "Found ${#files[@]} WireGuard configuration file(s):"
    echo "" >&2
    
    for i in "${!files[@]}"; do
        echo "  $((i+1))) ${files[$i]##*/}" >&2
    done
    
    echo "" >&2
    # read -p prompts to stderr by default, but we need to ensure inputs don't clutter result
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
        echo "" >&2
        echo "Expected files:" >&2
        echo "  • tunnelsats_<server>.conf (e.g., tunnelsats_us-east.conf)" >&2
        echo "  • Any .conf file in the current directory" >&2
        echo "" >&2
        echo "Please place your config file here and try again." >&2
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

# ---------------------------------------------------------------------------
# COMMAND HANDLERS
# ---------------------------------------------------------------------------

cmd_help() {
    print_header "Usage Guide"
    
    cat << 'EOF'
Usage: sudo bash tunnelsats.sh [COMMAND] [OPTIONS]

Commands:
  install              Install WireGuard VPN configuration
  install --config <file>  Install with specific config file
  pre-check            Check system compatibility
  uninstall            Remove TunnelSats installation
  status               Show subscription and connection status
  restart              Restart the WireGuard tunnel interface
  help                 Show this help message

Examples:
  # Run compatibility check first
  sudo bash tunnelsats.sh pre-check
  
  # Install with auto-detection
  sudo bash tunnelsats.sh install
  
  # Install with specific config
  sudo bash tunnelsats.sh install --config tunnelsats_us-east.conf
  
  # Check status
  sudo bash tunnelsats.sh status
  
  # Restart WireGuard tunnel
  sudo bash tunnelsats.sh restart

  # Clean uninstall
  sudo bash tunnelsats.sh uninstall

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
    local kernelPatch=$(uname -r | cut -d '.' -f3 | cut -d '-' -f1 | tr -cd '0-9')
    
    # Defaults in case of parsing failure
    kernelMajor=${kernelMajor:-0}
    kernelMinor=${kernelMinor:-0}
    kernelPatch=${kernelPatch:-0}
    
    if [[ $kernelMajor -gt 5 ]] || \
       [[ $kernelMajor -ge 5 && ( ($kernelMinor -ge 10 && $kernelPatch -ge 102) || $kernelMinor -ge 11 ) ]]; then
        print_success "Kernel $(uname -r) is compatible"
        ((rating+=1))
    else
        print_error "Kernel 5.10.102+ required (found $(uname -r))"
    fi
    echo ""
    
    # Check nftables version (min 0.9.6+ required)
    print_step 2 3 "Checking nftables version..."
    local nftablesVersion=""
    if command -v nft &>/dev/null; then
        nftablesVersion=$(nft -v | awk '{print $2}' | cut -d 'v' -f2)
    elif command -v apt-cache &>/dev/null; then
        nftablesVersion=$(apt-cache policy nftables | grep Candidate | awk '{print $2}' | cut -d '-' -f1)
    else
        nftablesVersion="0.0.0"
    fi
    
    if [[ -z "$nftablesVersion" ]]; then nftablesVersion="0.0.0"; fi

    local nftMajor=$(echo "$nftablesVersion" | cut -d '.' -f1)
    local nftMinor=$(echo "$nftablesVersion" | cut -d '.' -f2)
    local nftPatch=$(echo "$nftablesVersion" | cut -d '.' -f3)
    
    nftMajor=${nftMajor:-0}
    nftMinor=${nftMinor:-0}
    nftPatch=${nftPatch:-0}
    
    if [[ $nftMajor -ge 1 ]] || \
       [[ $nftMajor -eq 0 && $nftMinor -ge 9 && $nftPatch -ge 6 ]] || \
       [[ $nftMajor -eq 0 && $nftMinor -ge 10 ]]; then
        print_success "nftables $nftablesVersion is compatible"
        ((rating+=1))
    else
        print_error "nftables 0.9.6+ required (found $nftablesVersion)"
    fi
    echo ""
    
    # Check for systemd services or docker
    print_step 3 3 "Looking for Lightning implementation..."
    if [[ -f /etc/systemd/system/lnd.service ]]; then
        print_success "Found lnd.service"
        ((rating+=1))
    elif [[ -f /etc/systemd/system/lightningd.service ]]; then
        print_success "Found lightningd.service"
        ((rating+=1))
    else
        print_info "Checking for Docker containers..."
        local dockerProcess=$(docker ps --format 'table {{.Image}} {{.Names}} {{.Ports}}' 2>/dev/null | grep -E "0.0.0.0:9735|0.0.0.0:9736" | awk '{print $2}' || echo "")
        if [[ ${dockerProcess} == *lnd* ]]; then
            print_success "Found LND container"
            ((rating+=1))
        elif [[ ${dockerProcess} == *clightning* ]]; then
            print_success "Found CLN container"
            ((rating+=1))
        else
            print_error "No suitable Lightning implementation found"
        fi
    fi
    echo ""
    
    # Display result
    print_line
    echo -e "${BOLD}Compatibility Rating: $rating/3${NC}"
    print_line
    echo ""
    
    if [[ $rating -eq 3 ]]; then
        print_success "Your system is fully compatible with TunnelSats!"
        echo ""
        echo "Ready to install? Run:"
        echo -e "  ${GREEN}sudo bash tunnelsats.sh install${NC}"
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
    config_path=$(detect_config_file "$CONFIG_FILE") || exit 1
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
    
    # Step 5: Setup DNS Resolver
    print_step 5 5 "Enabling services..."
    setup_dns_resolver "$WG_INTERFACE"
    enable_services
    echo ""
    
    # Step 8: Final verification
    print_step 8 8 "Verifying installation..."
    verify_installation
    echo ""
    
    # Success!
    print_line
    print_success "Installation completed successfully!"
    print_line
    echo ""
    
    # Get VPN details from config
    local vpnExternalDNS=$(grep "Endpoint" /etc/wireguard/tunnelsatsv2.conf | awk '{print $3}' | cut -d ':' -f1)
    local vpnExternalPort=$(grep "#VPNPort" /etc/wireguard/tunnelsatsv2.conf | awk '{print $3}' || echo "<port>")
    
    # Show configuration instructions based on implementation
    echo -e "${BOLD}IMPORTANT: Configure your Lightning node${NC}"
    print_line
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
    echo "What Lightning node package are you running?" >&2
    echo "  1) RaspiBlitz" >&2
    echo "  2) Umbrel" >&2
    echo "  3) myNode" >&2
    echo "  4) RaspiBolt / Bare Metal" >&2
    echo "" >&2
    read -p "Select [1-4]: " answer
    
    case $answer in
        1) echo "raspiblitz" ;;
        2) echo "umbrel" ;;
        3) echo "mynode" ;;
        4) echo "baremetal" ;;
        *) print_error "Invalid selection"; exit 1 ;;
    esac
}

detect_ln_implementation() {
    echo "Which Lightning implementation do you want to tunnel?" >&2
    echo "  1) LND" >&2
    echo "  2) CLN (Core Lightning)" >&2
    if [[ "$PLATFORM" == "baremetal" ]]; then
        echo "  3) LIT (integrated mode)" >&2
    fi
    echo "" >&2
    read -p "Select [1-3]: " choice
    
    case $choice in
        1) echo "lnd" ;;
        2) echo "cln" ;;
        3) 
            if [[ "$PLATFORM" == "baremetal" ]]; then
                echo "lit"
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
modprobe cls_cgroup || true
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
    
    if [ "$delrule1" -gt 0 ]; then
        for i in $(seq 1 "$delrule1"); do
            ip rule del from all table main suppress_prefixlength 0 2>/dev/null || true
        done
    fi
    
    if [ "$delrule2" -gt 0 ]; then
        for i in $(seq 1 "$delrule2"); do
            ip rule del from $dockersubnet table 51820 2>/dev/null || true
        done
    fi
    
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
    bash /etc/wireguard/tunnelsats-docker-network.sh &>/dev/null
    
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
    systemctl daemon-reload
    systemctl enable tunnelsats-docker-network.service &>/dev/null
    systemctl start tunnelsats-docker-network.service &>/dev/null
    systemctl enable tunnelsats-docker-network.timer &>/dev/null
    systemctl start tunnelsats-docker-network.timer &>/dev/null
    
    print_success "Docker network configured"
}

setup_dns_resolver() {
    local interface="$1"
    print_info "Configuring DNS resolver watchdog for ${interface}..."
    
    # Create resolver script
    cat > /etc/wireguard/tunnelsats-resolve-dns-wg.sh << 'EOF'
#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2015-2020 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
set -e
shopt -s nocasematch
shopt -s extglob
export LC_ALL=C

CONFIG_FILE="$1"
[[ $CONFIG_FILE =~ ^[a-zA-Z0-9_=+.-]{1,15}$ ]] && CONFIG_FILE="/etc/wireguard/$CONFIG_FILE.conf"
[[ $CONFIG_FILE =~ /?([a-zA-Z0-9_=+.-]{1,15})\.conf$ ]]
INTERFACE="${BASH_REMATCH[1]}"

process_peer() {
    [[ $PEER_SECTION -ne 1 || -z $PUBLIC_KEY || -z $ENDPOINT ]] && return 0
    [[ $(wg show "$INTERFACE" latest-handshakes) =~ ${PUBLIC_KEY//+/\\+}\	([0-9]+) ]] || return 0
    (( ($EPOCHSECONDS - ${BASH_REMATCH[1]}) > 135 )) || return 0
    wg set "$INTERFACE" peer "$PUBLIC_KEY" endpoint "$ENDPOINT"
    reset_peer_section
}

reset_peer_section() {
    PEER_SECTION=0
    PUBLIC_KEY=""
    ENDPOINT=""
}

reset_peer_section
while read -r line || [[ -n $line ]]; do
    stripped="${line%%\#*}"
    key="${stripped%%=*}"; key="${key##*([[:space:]])}"; key="${key%%*([[:space:]])}"
    value="${stripped#*=}"; value="${value##*([[:space:]])}"; value="${value%%*([[:space:]])}"
    [[ $key == "["* ]] && { process_peer; reset_peer_section; }
    [[ $key == "[Peer]" ]] && PEER_SECTION=1
    if [[ $PEER_SECTION -eq 1 ]]; then
        case "$key" in
        PublicKey) PUBLIC_KEY="$value"; continue ;;
        Endpoint) ENDPOINT="$value"; continue ;;
        esac
    fi
done < "$CONFIG_FILE"
process_peer
EOF
    
    chmod +x /etc/wireguard/tunnelsats-resolve-dns-wg.sh
    
    # Create systemd service
    cat > /etc/systemd/system/tunnelsats-resolve-dns-wg.service << EOF
[Unit]
Description=tunnelsats-resolve-dns-wg: Trigger Resolve DNS in case Handshake is older than 2 minutes
[Service]
Type=oneshot
ExecStart=/bin/bash /etc/wireguard/tunnelsats-resolve-dns-wg.sh ${interface}
[Install]
WantedBy=multi-user.target
EOF

    # Create timer
    cat > /etc/systemd/system/tunnelsats-resolve-dns-wg.timer << EOF
[Unit]
Description=30sec timer for tunnelsats-resolve-dns-wg.service
[Timer]
OnBootSec=30
OnUnitActiveSec=30
Persistent=true
[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable tunnelsats-resolve-dns-wg.service &>/dev/null || true
    systemctl enable tunnelsats-resolve-dns-wg.timer &>/dev/null || true
    systemctl start tunnelsats-resolve-dns-wg.timer &>/dev/null || true
    
    print_success "DNS resolver watchdog configured"
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
        setup_cgroups
        local service_file=""
        local service_dir=""
        
        case "$LN_IMPL" in
            lnd)
                service_file="/etc/systemd/system/lnd.service"
                service_dir="/etc/systemd/system/lnd.service.d"
                ;;
            cln)
                service_file="/etc/systemd/system/lightningd.service"
                service_dir="/etc/systemd/system/lightningd.service.d"
                ;;
            lit)
                service_file="/etc/systemd/system/lit.service"
                service_dir="/etc/systemd/system/lit.service.d"
                ;;
        esac

        # 1. Create Drop-in Dependency
        if [[ -n "$service_dir" ]]; then
            if [[ ! -d "$service_dir" ]]; then mkdir -p "$service_dir"; fi
            
            cat > "${service_dir}/tunnelsats-cgroup.conf" << EOF
#Don't edit this file its generated by tunnelsats scripts
[Unit]
Description=${LN_IMPL} service - powered by tunnelsats
Requires=tunnelsats-create-cgroup.service
After=tunnelsats-create-cgroup.service
Requires=wg-quick@${WG_INTERFACE}.service
After=wg-quick@${WG_INTERFACE}.service
EOF
        fi
        
        # 2. Modify ExecStart to use cgexec
        if [[ -f "$service_file" ]]; then
            if [[ ! -f "${service_file}.bak" ]]; then
                cp "$service_file" "${service_file}.bak"
            fi
            
            if ! grep -q "cgexec" "$service_file"; then
                sed -i 's|ExecStart=|ExecStart=/usr/bin/cgexec -g net_cls:splitted_processes |g' "$service_file"
                print_success "${LN_IMPL} service updated to use cgroup"
            else
                print_info "${LN_IMPL} service already uses cgroup"
            fi
        fi
        
        # 3. Handle RaspiBlitz API (blitzapi) dependency if present
        if [[ -f /etc/systemd/system/blitzapi.service ]]; then
            if [[ ! -d /etc/systemd/system/blitzapi.service.d ]]; then
                mkdir -p /etc/systemd/system/blitzapi.service.d
            fi
            cat > /etc/systemd/system/blitzapi.service.d/tunnelsats-wg.conf << EOF
#Don't edit this file its generated by tunnelsats scripts
[Unit]
Description=blitzapi needs the wg service before it can start successfully
Requires=wg-quick@${WG_INTERFACE}.service
After=wg-quick@${WG_INTERFACE}.service
EOF
             print_success "Added blitzapi dependency"
        fi

        systemctl daemon-reload
    fi
    
    # Create splitting processes script (non-Docker)
    if [[ "$PLATFORM" != "umbrel" ]]; then
        cat > /etc/wireguard/tunnelsats-splitting-processes.sh << 'EOF'
#!/bin/sh
# add Lightning pid(s) to cgroup
pgrep -x lnd | xargs -I % sh -c 'echo % >> /sys/fs/cgroup/net_cls/splitted_processes/tasks' &> /dev/null
pgrep -x lightningd | xargs -I % sh -c 'echo % >> /sys/fs/cgroup/net_cls/splitted_processes/tasks' &> /dev/null
pgrep -x litd | xargs -I % sh -c 'echo % >> /sys/fs/cgroup/net_cls/splitted_processes/tasks' &> /dev/null
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
    
    print_success "${LN_IMPL} configured for tunneling"
}



enable_services() {
    if [[ -z "$WG_INTERFACE" ]]; then
        print_error "WireGuard interface not determined"
        exit 1
    fi

    print_info "Enabling WireGuard service (${WG_INTERFACE})..."
    
    systemctl daemon-reload > /dev/null 2>&1
    
    local out
    if out=$(systemctl enable wg-quick@${WG_INTERFACE} 2>&1); then
        print_success "WireGuard service enabled"
    else
        print_error "Failed to enable service:"
        echo "$out"
        exit 1
    fi
    
    print_info "Starting WireGuard..."
    if out=$(systemctl start wg-quick@${WG_INTERFACE} 2>&1); then
        print_success "WireGuard service started"
    else
        print_error "Failed to start service:"
        echo "$out"
        
        # Help user troubleshoot
        echo ""
        print_info "Checking status..."
        systemctl status wg-quick@${WG_INTERFACE} --no-pager -l || true
        exit 1
    fi
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
    echo "  • Restore backup files (LND/CLN configs)"
    echo "  • Clean up systemd services"
    echo "  • Restore hybrid mode to Tor-only"
    echo ""
    
    # Triple confirmation
    while true; do
        read -p "CAUTION! Uninstalling TunnelSats will force your lightning process to stop. Do you really want to proceed? (Y/N) " answer
        case $answer in
            [yY]*) echo "> OK, proceeding..."; echo; break ;;
            [nN]*) echo "> Exiting process."; exit 1 ;;
            *) echo "Just enter Y or N, please." ;;
        esac
    done
    
    # 1. Detect Platform & Implementation for Cleanup
    local is_docker=0
    PLATFORM=""
    local home_dir=""
    local umbrel_user=${SUDO_USER:-${USER}}

    echo "What Lightning node package are you running?"
    echo "  1) RaspiBlitz"
    echo "  2) Umbrel"
    echo "  3) myNode"
    echo "  4) RaspiBolt / Bare Metal"
    read -p "Select [1-4]: " platform_choice
    
    case $platform_choice in
        1) PLATFORM="raspiblitz"; is_docker=0 ;;
        2) PLATFORM="umbrel"; is_docker=1; home_dir="/home/$umbrel_user" ;;
        3) PLATFORM="mynode"; is_docker=0 ;;
        4) PLATFORM="baremetal"; is_docker=0 ;;
        *) print_error "Invalid selection"; exit 1 ;;
    esac
    
    local ln_impl=""
    echo ""
    echo "Which Lightning implementation was tunneled?"
    echo "  1) LND"
    echo "  2) CLN"
    read -p "Select [1-2]: " ln_choice
    
    case $ln_choice in
        1) ln_impl="lnd" ;;
        2) ln_impl="cln" ;;
        *) print_error "Invalid selection"; exit 1 ;;
    esac

    # 2. Stop Services & Clean Dependencies
    print_step 1 6 "Stopping Lightning services..."
    
    if [[ "$ln_impl" == "lnd" ]]; then
        echo "Ensure lnd lightning process is stopped..."
        if [[ $is_docker -eq 1 ]]; then
             local container=$(docker ps --format 'table {{.Image}} {{.Names}} {{.Ports}}' | grep 9735 | awk '{print $2}')
             if [[ -n "$container" ]]; then
                 docker stop "$container" &>/dev/null
                 docker network disconnect docker-tunnelsats "$container" &>/dev/null
                 docker rm "$container" &>/dev/null
                 print_success "Stopped $container docker container"
             else
                 print_info "No lightning container active"
             fi
        elif [[ -f /etc/systemd/system/lnd.service ]]; then
             if systemctl is-active lnd.service &>/dev/null; then
                 systemctl stop lnd.service &>/dev/null && print_success "Stopped lnd.service"
             fi
        fi
        
        # Remove dependencies
        if [[ -f /etc/systemd/system/lnd.service.d/tunnelsats-cgroup.conf ]]; then
             rm /etc/systemd/system/lnd.service.d/tunnelsats-cgroup.conf &>/dev/null
             systemctl daemon-reload &>/dev/null
             print_success "Removed lnd.service dependency"
        fi
        
        # Restore RaspiBlitz lnd.check
        if [[ -f /home/admin/config.scripts/lnd.check.bak ]]; then
             mv /home/admin/config.scripts/lnd.check.bak /home/admin/config.scripts/lnd.check.sh
             print_success "Restored RaspiBlitz lnd.check.sh"
        fi

    elif [[ "$ln_impl" == "cln" ]]; then
        echo "Ensure clightning process is stopped..."
        if [[ $is_docker -eq 1 ]]; then
             local container=$(docker ps --format 'table {{.Image}} {{.Names}} {{.Ports}}' | grep 9735 | awk '{print $2}')
             if [[ -n "$container" ]]; then
                 docker stop "$container" &>/dev/null
                 docker network disconnect docker-tunnelsats "$container" &>/dev/null
                 docker rm "$container" &>/dev/null
                 print_success "Stopped $container docker container"
             else
                 print_info "No lightning container active"
             fi
        elif [[ -f /etc/systemd/system/lightningd.service ]]; then
             if systemctl is-active lightningd.service &>/dev/null; then
                 systemctl stop lightningd.service &>/dev/null && print_success "Stopped lightningd.service"
             fi
        fi

        # Remove dependencies
        if [[ -f /etc/systemd/system/lightningd.service.d/tunnelsats-cgroup.conf ]]; then
             rm /etc/systemd/system/lightningd.service.d/tunnelsats-cgroup.conf &>/dev/null
             systemctl daemon-reload &>/dev/null
             print_success "Removed lightningd.service dependency"
        fi
        
        # Restore RaspiBlitz cl.check
        if [[ -f /home/admin/config.scripts/cl.check.bak ]]; then
             mv /home/admin/config.scripts/cl.check.bak /home/admin/config.scripts/cl.check.sh
             print_success "Restored RaspiBlitz cl.check.sh"
        fi
    fi
    echo ""

    # 3. Restore Hybrid Mode Configuration
    print_step 2 6 "Restoring configuration files..."
    
    if [[ "$ln_impl" == "lnd" ]]; then
        local paths=(
            "/mnt/hdd/lnd/lnd.conf"
            "$home_dir/umbrel/lnd/lnd.conf"
            "$home_dir/umbrel/app-data/lightning/data/lnd/lnd.conf"
            "/data/lnd/lnd.conf"
            "/mnt/hdd/mynode/lnd/lnd.conf"
        )
        for path in "${paths[@]}"; do
            if [[ -f "$path" ]]; then 
                if grep -q "tor.skip-proxy-for-clearnet-targets" "$path"; then
                    sed -i "/tor.skip-proxy-for-clearnet-targets/d" "$path"
                    print_success "Disabled hybrid mode in $path"
                fi
            fi
        done
        
    elif [[ "$ln_impl" == "cln" ]]; then
        local paths=(
            "/mnt/hdd/app-data/.lightning/config"
            "$home_dir/umbrel/app-data/core-lightning/data/lightningd/bitcoin/config"
            "/data/lightningd/config"
        )
        for path in "${paths[@]}"; do
            if [[ -f "$path" ]]; then
                if grep -q "always-use-proxy=false" "$path"; then
                    sed -i "s/always-use-proxy=false/always-use-proxy=true/g" "$path"
                    sed -i "s/always-use-proxy=0/always-use-proxy=1/g" "$path"
                    print_success "Restored Tor-only mode in $path"
                fi
                
                # Umbrel specific cleanups
                if [[ "$path" == *"$home_dir/umbrel"* ]]; then
                     sed -i '/^bind-addr=/d' "$path" 2>/dev/null
                     sed -i '/^announce-addr=/d' "$path" 2>/dev/null
                fi
            fi
        done
        
        # Umbrel exports.sh
        if [[ -f "$home_dir/umbrel/app-data/core-lightning/exports.sh" ]]; then
             sed -i 's/APP_CORE_LIGHTNING_DAEMON_PORT="9735"/APP_CORE_LIGHTNING_DAEMON_PORT="9736"/g' "$home_dir/umbrel/app-data/core-lightning/exports.sh"
             print_success "Restored Umbrel exports.sh port"
        fi
        
         if [[ -f "$home_dir/umbrel/app-data/core-lightning/docker-compose.yml" ]]; then
             # Handle potential spaces after # (e.g., # - --bind-addr or #- --bind-addr)
             sed -i "s/^#\s*- --bind-addr/- --bind-addr/g" "$home_dir/umbrel/app-data/core-lightning/docker-compose.yml" &>/dev/null
             print_success "Restored Umbrel docker-compose binding"
         fi
    fi
    echo ""

    # 4. Remove Splitting Services
    print_step 3 6 "Removing helper services..."
    if [[ $is_docker -eq 0 ]]; then
        # Check timers/services
        for svc in tunnelsats-splitting-processes.timer tunnelsats-splitting-processes.service tunnelsats-create-cgroup.service; do
             if [[ -f /etc/systemd/system/$svc ]]; then
                 systemctl stop $svc &>/dev/null || true
                 systemctl disable $svc &>/dev/null || true
                 rm -f /etc/systemd/system/$svc &>/dev/null
                 print_success "Removed $svc"
             fi
        done
        
        # Remove cgroups
        if [[ -d /sys/fs/cgroup/net_cls/tor_splitting ]]; then cgdelete net_cls:/tor_splitting 2>/dev/null; fi
        if [[ -d /sys/fs/cgroup/net_cls/splitted_processes ]]; then cgdelete net_cls:/splitted_processes 2>/dev/null; fi
        
    else
        # Docker cleanup
         for svc in tunnelsats-docker-network.timer tunnelsats-docker-network.service; do
             if [[ -f /etc/systemd/system/$svc ]]; then
                 systemctl stop $svc &>/dev/null || true
                 systemctl disable $svc &>/dev/null || true
                 rm -f /etc/systemd/system/$svc &>/dev/null
                 print_success "Removed $svc"
             fi
        done
        
        # Umbrel Killswitch
        rm -f /etc/systemd/system/umbrel.service.d/tunnelsats_killswitch.conf &>/dev/null
        rm -f /etc/systemd/system/umbrel-startup.service.d/tunnelsats_killswitch.conf &>/dev/null
        print_success "Removed Umbrel killswitch"
    fi
    echo ""

    # 5. Remove WireGuard Services
    print_step 4 6 "Removing WireGuard configuration..."
    
    # Find any active TunnelSats interface to stop
    local target_interface=$(find_active_wg_config | xargs basename 2>/dev/null | sed 's/\.conf//')
    if [[ -z "$target_interface" ]]; then target_interface="tunnelsatsv2"; fi

    systemctl stop wg-quick@${target_interface} &>/dev/null || true
    systemctl disable wg-quick@${target_interface} &>/dev/null || true
    
    if [[ -f /etc/systemd/system/multi-user.target.wants/wg-quick@tunnelsats.service ]]; then
         systemctl stop wg-quick@tunnelsats &>/dev/null || true
         systemctl disable wg-quick@tunnelsats &>/dev/null || true
    fi
    
    # Remove DNS resolver
    if [[ -f /etc/systemd/system/tunnelsats-resolve-dns-wg.service ]]; then
         systemctl stop tunnelsats-resolve-dns-wg.service &>/dev/null
         systemctl disable tunnelsats-resolve-dns-wg.service &>/dev/null
         rm -f /etc/systemd/system/tunnelsats-resolve-dns-wg.service
    fi
    if [[ -f /etc/systemd/system/tunnelsats-resolve-dns-wg.timer ]]; then
         systemctl stop tunnelsats-resolve-dns-wg.timer &>/dev/null
         systemctl disable tunnelsats-resolve-dns-wg.timer &>/dev/null
         rm -f /etc/systemd/system/tunnelsats-resolve-dns-wg.timer
    fi

    rm -rf /etc/systemd/system/wg-quick@${target_interface}.service.d &>/dev/null
    print_success "WireGuard services removed"
    echo ""

    # 6. Docker Network Cleanup
    if [[ $is_docker -eq 1 ]]; then
        print_step 5 6 "Cleaning Docker network..."
        ip route flush table 51820 &>/dev/null
        
        # Disconnect containers from network
        docker inspect docker-tunnelsats 2>/dev/null | jq '.[].Containers' | grep Name | sed 's/[",]//g' | awk '{print $2}' | xargs -I % sh -c 'docker network disconnect docker-tunnelsats % 2>/dev/null'
        
        if docker network rm docker-tunnelsats &>/dev/null; then
            print_success "Removed docker-tunnelsats network"
        fi
        
        # Restore nftables
        nft delete table ip ${target_interface} &>/dev/null || true
        nft delete table inet ${target_interface} &>/dev/null || true
        nft delete table ip tunnelsatsv2 &>/dev/null || true
        nft delete table inet tunnelsatsv2 &>/dev/null || true
        if [[ -f /etc/nftablespriortunnelsats.backup ]]; then
             mv /etc/nftablespriortunnelsats.backup /etc/nftables.conf
             print_success "Restored original nftables.conf"
        fi
        
        systemctl daemon-reload || true
        systemctl restart docker &>/dev/null || true
        print_success "Docker restarted"
        echo ""
    fi
    
    # 7. Restore Original Service Files
    if [[ $is_docker -eq 0 ]]; then
        print_step 6 6 "Restoring systemd service files..."
        if [[ "$ln_impl" == "lnd" && -f /etc/systemd/system/lnd.service.bak ]]; then
             mv /etc/systemd/system/lnd.service.bak /etc/systemd/system/lnd.service
             print_success "Restored lnd.service backup"
        fi
        if [[ "$ln_impl" == "cln" && -f /etc/systemd/system/lightningd.service.bak ]]; then
             mv /etc/systemd/system/lightningd.service.bak /etc/systemd/system/lightningd.service
             print_success "Restored lightningd.service backup"
        fi
        systemctl daemon-reload
        echo ""
    fi
    
    # Optional Package Removal
    echo "Do you want to uninstall system packages?"
    if [[ $is_docker -eq 1 ]]; then
        read -p "Remove nftables and wireguard-tools? (Y/N) " answer
    else
        read -p "Remove cgroup-tools, nftables and wireguard-tools? (Y/N) " answer
    fi
    
    if [[ "$answer" =~ ^[Yy] ]]; then
         if [[ $is_docker -eq 1 ]]; then
             apt-get remove -yqq nftables wireguard-tools &>/dev/null
         else
             apt-get remove -yqq cgroup-tools nftables wireguard-tools &>/dev/null
         fi
         print_success "Packages removed"
    else
         print_info "Packages kept"
    fi

    echo ""
    print_line
    print_success "TunnelSats uninstalled successfully!"
    print_line
    echo ""
    
    echo -e "${BOLD}MANUAL CLEANUP REQUIRED:${NC}"
    echo "Please check your lightning configuration files and remove any leftover"
    echo "TunnelSats settings if they were not automatically restored:"
    echo "  - externalhosts"
    echo "  - announce-addr"
    echo "  - tor.skip-proxy-for-clearnet-targets"
    echo ""
    
    echo "Next: Restart your node for changes to take effect."
    echo "      (Highly recommended to clear firewall and network rules)"
    echo ""
    echo "   sudo reboot"
    
    if [[ "$PLATFORM" == "umbrel" ]]; then
        echo "   (Or restart via Umbrel Dashboard)"
    fi
    echo ""
}

cmd_install() {
    check_root
    print_header "TunnelSats Installation"

    # Step 1: Detect Configuration (Fail fast if missing)
    print_step 1 6 "Detecting configuration..."
    local config_path
    config_path=$(detect_config_file "$CONFIG_FILE") || exit 1
    CONFIG_FILE="$config_path"
    echo ""
    
    # Step 2: Detect Environment
    print_step 2 6 "Analyzing environment..."
    PLATFORM=$(detect_platform)
    LN_IMPL=$(detect_ln_implementation)
    
    local is_docker=0
    [[ "$PLATFORM" == "umbrel" ]] && is_docker=1
    [[ "$PLATFORM" == "mynode" ]] && is_docker=0 # myNode nodal part is bare metal
    
    print_info "Platform: ${PLATFORM}, Lightning: ${LN_IMPL}"
    echo ""

    # Step 3: Check dependencies
    print_step 3 6 "Checking dependencies..."
    if ! command -v wg &>/dev/null; then
        print_info "Installing wireguard-tools..."
        if ! apt-get update -qq &>/dev/null || ! apt-get install -yqq wireguard-tools &>/dev/null; then
            # try Debian 10 Buster workaround / myNode
            local codename=$(lsb_release -c 2>/dev/null | awk '{print $2}')
            if [[ "$codename" == "buster" && "$PLATFORM" != "umbrel" ]]; then
                print_info "Attempting Debian 10 Buster workaround..."
                apt-get install -yqq -t buster-backports wireguard-tools &>/dev/null
            fi
        fi
    fi
    if ! command -v nft &>/dev/null; then
        print_info "Installing nftables..."
        apt-get install -yqq nftables &>/dev/null
    fi
    if ! command -v resolvconf &>/dev/null; then
        print_info "Installing resolvconf..."
        apt-get install -yqq resolvconf &>/dev/null
    fi
    
    # Only install cgroup-tools for non-Docker platforms (Umbrel uses Docker networking)
    if [[ "$PLATFORM" != "umbrel" ]]; then
         if ! command -v cgexec &>/dev/null; then
            print_info "Installing cgroup-tools..."
            apt-get install -yqq cgroup-tools &>/dev/null
        fi
    fi
    echo ""

    # Step 4: Configure Lightning
    print_step 4 6 "Configuring Lightning..."
    configure_lightning
    echo ""

    # Step 5: Configure WireGuard
    print_step 5 6 "Configuring WireGuard..."
    configure_wireguard
    
    # Configure DNS Resolver Watchdog
    setup_dns_resolver
    
    # Configure Docker Network (Umbrel/Docker only)
    if [[ $is_docker -eq 1 ]]; then
        setup_docker_network
    fi
    echo ""

    # Step 6: Enable services
    print_step 6 6 "Enabling services..."
    enable_services
    
    # Verify installation
    verify_installation
    echo ""

    # Post-Install Health Check
    print_info "Performing post-install connectivity check..."
    if ping -c 1 -W 2 10.9.0.1 &>/dev/null; then
        print_success "VPN Gateway (10.9.0.1) is reachable!"
    else
        print_warning "Could not ping VPN Gateway (10.9.0.1)."
        print_warning "This is common after first install. A reboot usually fixes it."
    fi
    echo ""
    
    # Display success message
    print_line
    print_success "TunnelSats installed successfully!"
    print_line
    echo ""
    
    # Extract details for manual config
    local vpn_dns=$(grep "^Endpoint" "$CONFIG_FILE" | awk '{print $3}' | cut -d ':' -f 1)
    local vpn_port=$(grep -E "#VPNPort|# Port Forwarding:" "$CONFIG_FILE" | head -1 | awk '{print $NF}' | sed 's/.*: //')
    
    echo -e "${BOLD}CRITICAL: You must update your node configuration!${NC}"
    echo "Please copy the following settings into your configuration file."
    echo ""

    if [[ "$LN_IMPL" == "lnd" ]]; then
        if [[ "$PLATFORM" == "umbrel" ]]; then
             echo "Edit: ~/umbrel/app-data/lightning/data/lnd/lnd.conf"
             echo "Note: If 'tor.streamisolation' or 'tor.skip-proxy...' are already enabled in UI,"
             echo "      do NOT duplicate them."
             echo ""
             echo "#########################################"
             echo -e "${BOLD}[Application Options]${NC}"
             echo -e "${BOLD}externalhosts=${vpn_dns}:${vpn_port}${NC}"
             echo ""
             echo -e "${BOLD}[Tor]${NC}"
             echo -e "${BOLD}tor.streamisolation=false${NC}"
             echo -e "${BOLD}tor.skip-proxy-for-clearnet-targets=true${NC}"
             echo "#########################################"
        else
             echo "Edit: lnd.conf"
             echo ""
             echo "#########################################"
             echo -e "${BOLD}[Application Options]${NC}"
             echo -e "${BOLD}listen=0.0.0.0:9735${NC}"
             echo -e "${BOLD}externalhosts=${vpn_dns}:${vpn_port}${NC}"
             echo ""
             echo -e "${BOLD}[Tor]${NC}"
             echo -e "${BOLD}tor.streamisolation=false${NC}"
             echo -e "${BOLD}tor.skip-proxy-for-clearnet-targets=true${NC}"
             echo "#########################################"
        fi
        
    elif [[ "$LN_IMPL" == "cln" ]]; then
        if [[ "$PLATFORM" == "umbrel" ]]; then
             echo "1. Edit: sudo nano ~/umbrel/app-data/core-lightning/data/lightningd/bitcoin/config"
             echo "#########################################"
             echo -e "${BOLD}bind-addr=0.0.0.0:9735${NC}"
             echo -e "${BOLD}announce-addr=${vpn_dns}:${vpn_port}${NC}"
             echo -e "${BOLD}always-use-proxy=false${NC}"
             echo "#########################################"
             echo ""
             echo "2. Edit: nano ~/umbrel/app-data/core-lightning/exports.sh"
             echo "#########################################"
             echo -e "${BOLD}export APP_CORE_LIGHTNING_DAEMON_PORT=\"9735\"${NC}"
             echo "#########################################"
             echo ""
             echo "3. Edit: ~/umbrel/app-data/core-lightning/docker-compose.yml"
             echo "   Comment out '--bind-addr' if present."
        else
             echo "Edit: config"
             echo ""
             echo "#########################################"
             echo -e "${BOLD}bind-addr=0.0.0.0:9735${NC}"
             echo -e "${BOLD}announce-addr=${vpn_dns}:${vpn_port}${NC}"
             echo -e "${BOLD}always-use-proxy=false${NC}"
             echo "#########################################"
        fi
        
    elif [[ "$LN_IMPL" == "lit" ]]; then
         echo "Edit: lit.conf"
         echo ""
         echo "#########################################"
         echo -e "${BOLD}[Application Options]${NC}"
         echo -e "${BOLD}externalhosts=${vpn_dns}:${vpn_port}${NC}"
         echo ""
         echo -e "${BOLD}[Tor]${NC}"
         echo -e "${BOLD}tor.streamisolation=false${NC}"
         echo -e "${BOLD}tor.skip-proxy-for-clearnet-targets=true${NC}"
         echo "#########################################"
    fi

    echo ""
    echo "Then, restart your node:"
    if [[ "$PLATFORM" == "umbrel" ]]; then
        echo "   sudo reboot"
        echo "   (Or restart the Lightning app via Umbrel Dashboard: Right-click -> Restart)"
    else
        local svc="${LN_IMPL}"
        [[ "$LN_IMPL" == "cln" ]] && svc="lightningd"
        echo "   sudo systemctl restart ${svc}.service"
    fi
    echo ""
}

auto_detect_environment() {
    # Auto-detect platform
    if [[ -z "$PLATFORM" ]]; then
        if [[ -d /home/admin/config.scripts ]]; then
            PLATFORM="raspiblitz"
        elif [[ -d /home/umbrel/umbrel ]] || [[ -d /umbrel ]] || [[ -f /usr/bin/umbrel ]]; then
            PLATFORM="umbrel"
        elif [[ -d /usr/share/mynode ]]; then
            PLATFORM="mynode"
        else
            PLATFORM="baremetal"
        fi
    fi
    
    # Auto-detect implementation
    if [[ -z "$LN_IMPL" ]]; then
        if [[ "$PLATFORM" == "umbrel" ]]; then
            if docker ps --filter name=core-lightning -q | grep -q .; then
                LN_IMPL="cln"
            elif docker ps --filter name=lnd -q | grep -q .; then
                LN_IMPL="lnd"
            fi
        else
            if systemctl is-active --quiet lnd; then
                LN_IMPL="lnd"
            elif systemctl is-active --quiet lightningd; then
                LN_IMPL="cln"
            elif systemctl is-active --quiet litd || systemctl is-active --quiet lit; then
                LN_IMPL="lit"
            fi
        fi
    fi
}

cmd_status() {
    print_header "Subscription Status"
    
    echo ""
    
    # 0. Auto-detect environment if not set
    auto_detect_environment
    
    # 1. Active Config & WireGuard Status Check
    local config_file
    config_file=$(find_active_wg_config)
    
    # If standard find fails, try explicit check
    if [[ $? -ne 0 ]] || [[ -z "$config_file" ]]; then
       # Derive interface from any active wg interface if possible
       local active_interface=$(sudo wg show | grep "interface:" | head -n 1 | awk '{print $2}')
       if [[ -n "$active_interface" ]]; then
            config_file="/etc/wireguard/${active_interface}.conf"
       fi
       
       if [[ ! -f "$config_file" ]]; then
             print_error "No TunnelSats configuration or active interface found."
             echo "Expected locations:"
             echo "  • /etc/wireguard/tunnelsatsv2.conf"
             echo "  • /etc/wireguard/tunnelsats-*.conf"
             exit 1
       fi
    fi

    # Extract interface name
    local interface_name=$(basename "$config_file" .conf)
    
    # Get WireGuard details
    local wg_output=$(wg show ${interface_name} 2>/dev/null)
    local is_tunnel_active=0
    if [[ -n "$wg_output" ]]; then
        is_tunnel_active=1
    fi
    
    # Parse WireGuard info
    local public_key=$(echo "$wg_output" | grep "public key" | awk '{print $3}')
    local endpoint=$(echo "$wg_output" | grep "endpoint" | awk '{print $2}')
    local latest_handshake=$(echo "$wg_output" | grep "latest handshake" | sed 's/latest handshake: //')
    local transfer=$(echo "$wg_output" | grep "transfer")
    local transfer_rx=$(echo "$transfer" | awk '{print $2, $3}')
    local transfer_tx=$(echo "$transfer" | awk '{print $5, $6}')
    
    # Parse Config File Metadata
    local vpn_port=$(grep '#VPNPort\|# Port Forwarding:' "$config_file" | head -1 | awk '{print $NF}' | sed 's/.*: //')
    local sub_end=$(grep -E '#ValidUntil|# Valid Until:' "$config_file" | head -1 | awk -F '[=:]' '{print $2}' | xargs)
    # If endpoint missing from wg_output (tunnel down), try config
    if [[ -z "$endpoint" ]]; then
         endpoint=$(grep '^Endpoint' "$config_file" | awk '{print $3}' | cut -d ':' -f 1)
    fi

    local status_msg=""
    if [[ $is_tunnel_active -eq 1 ]]; then
         # Check handshake freshness
        if [[ "$latest_handshake" == *"minute"* ]] || [[ "$latest_handshake" == *"second"* ]]; then
             status_msg="${GREEN}Active${NC}"
        else
             status_msg="${YELLOW}Stale (Old Handshake)${NC}"
        fi
    else
        status_msg="${RED}Offline${NC}"
        latest_handshake="N/A"
        transfer_rx="0"
        transfer_tx="0"
    fi

    # Display Summary
    echo -e "${BOLD}WireGuard Tunnel Status${NC}"
    print_line
    echo -e "  Interface:      ${interface_name}"
    echo -e "  Status:         ${status_msg}"
    echo -e "  Public Key:     ${BLUE}${public_key}${NC}"
    echo -e "  Last Handshake: ${latest_handshake}"
    echo -e "  Transfer:       ↓ ${transfer_rx} / ↑ ${transfer_tx}"
    echo -e "  VPN Endpoint:   ${endpoint}"
    echo -e "  VPN Port:       ${vpn_port}"
    if [[ -n "$sub_end" ]]; then
        echo -e "  Expires:        ${sub_end}" 
    fi
    echo ""

    # ---------------------------------------------------------
    # Node & Connectivity Checks (Ported from tunnelsats-sub-details.sh)
    # ---------------------------------------------------------

    # 1. Docker Setup Check
    check_docker_setup_status() {
       if systemctl is-active --quiet docker; then
         if docker ps --filter name=core-lightning -q | grep -q . || docker ps --filter name=lnd -q | grep -q .; then
          if docker ps --filter name=core-lightning -q | grep -q .; then
            echo "docker-core-lightning"
            return 0
          elif docker ps --filter name=lnd -q | grep -q .; then
            echo "docker-lnd"
            return 0
          fi
         fi
       fi
       echo "manual"
       return 1
    }

    # 2. Outbound Check
    perform_outbound_check_status() {
      local setup_type=$1
      local ip_address=""
      local cmd_exit_code=0
    
      if [[ "$setup_type" == "docker-lnd" || "$setup_type" == "docker-core-lightning" ]]; then
        if ! docker network inspect docker-tunnelsats > /dev/null 2>&1; then
            ip_address="Error: Docker network missing"
        else
            ip_address=$(timeout 20s docker run --rm --net=docker-tunnelsats curlimages/curl -s https://api.ipify.org)
            cmd_exit_code=$?
            if [ $cmd_exit_code -ne 0 ] || [[ -z "$ip_address" ]]; then
                 ip_address="Error: Check failed or timed out"
            fi
        fi
      else
        # Manual
        if command -v cgexec &> /dev/null; then
          ip_address=$(timeout 20s cgexec -g net_cls:splitted_processes curl --silent https://api.ipify.org)
        else
          # Fallback
          ip_address=$(timeout 20s curl --silent https://api.ipify.org)
        fi
      fi
      echo "$ip_address"
    }
    
    # 3. Inbound Check
    perform_inbound_check_status() {
      local target_endpoint=$1
      local target_port=$2
      local result_url=""
      local status="failed"
      
      # Clean endpoint
      local clean_endpoint=$(echo $target_endpoint | cut -d ':' -f 1)
      
      local curl_output=$(timeout 3s curl -sv telnet://"${clean_endpoint}":"${target_port}" 2>&1 | head -n 2)
      
      if [[ "$curl_output" == *"Connected to"* ]]; then
        result_url=$(echo "$curl_output" | grep "Connected to" | grep -oP 'Connected to [^ ]+ \(\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
        if [[ -n "$result_url" ]]; then
           status="success"
        else
           result_url="Unknown (Success)"
           status="success_no_ip"
        fi
      else
        result_url="Error: Connection failed"
      fi
      echo "$status $result_url"
    }

    # 4. Get Node Address
    get_node_ext_addr_status() {
        local setup_type=$1
        local ext_addr="N/A"
        local docker_name=""
        local node_type=""

        case "$setup_type" in
            "docker-lnd")
                docker_name=$(docker ps --filter name=lnd --format "{{.Names}}" | head -n 1) # Safer fetch
                if [[ -z "$docker_name" ]]; then docker_name="lightning_lnd_1"; fi # Fallback
                node_type="LND (Docker)"
                if command -v jq &> /dev/null; then
                    # Try direct exec
                    local info=$(docker exec "$docker_name" lncli getinfo 2>/dev/null)
                    ext_addr=$(echo "$info" | jq -r '.uris[]' | grep -v "\.onion" | head -n 1)
                fi
                ;;
            "docker-core-lightning")
                # Filter specifically for the main lightningd container, avoiding proxies/apps
                docker_name=$(docker ps --filter name=core-lightning --format "{{.Names}}" | grep "lightningd" | head -n 1)
                
                # Fallback if grep failed but generic name exists
                if [[ -z "$docker_name" ]]; then 
                     docker_name=$(docker ps --filter name=lightningd --format "{{.Names}}" | head -n 1)
                fi
                if [[ -z "$docker_name" ]]; then docker_name="core-lightning_lightningd_1"; fi
                
                node_type="CLN (Docker)"
                if command -v jq &> /dev/null; then
                     local info=$(docker exec "$docker_name" lightning-cli getinfo 2>/dev/null)
                     local pk=$(echo "$info" | jq -r '.id')
                     local ip=$(echo "$info" | jq -r '.address[] | select(.type == "ipv4") | .address' | head -n 1)
                     local port=$(echo "$info" | jq -r '.address[] | select(.type == "ipv4") | .port' | head -n 1)
                     if [[ -n "$pk" && -n "$ip" ]]; then ext_addr="${pk}@${ip}:${port}"; fi
                fi
                ;;
            "manual")
                # Attempt to guess
                local original_user="${SUDO_USER:-$(whoami)}"
                
                 if systemctl is-active --quiet lnd; then
                    node_type="LND (Systemd)"
                    if command -v lncli &> /dev/null; then
                         local info
                         # Try as sudo user first (RaspiBlitz standard)
                         info=$(sudo -u "$original_user" lncli getinfo 2>/dev/null)
                         
                         # Fallback to root execution if user attempt empty
                         if [[ -z "$info" ]]; then
                             info=$(lncli getinfo 2>/dev/null)
                         fi
                         
                         ext_addr=$(echo "$info" | jq -r '.uris[]' | grep -v "\.onion" | head -n 1)
                    fi
                 elif systemctl is-active --quiet lightningd; then
                    node_type="CLN (Systemd)"
                     if command -v lightning-cli &> /dev/null; then
                         local info
                         info=$(sudo -u "$original_user" lightning-cli getinfo 2>/dev/null)
                         
                         if [[ -z "$info" ]]; then
                             info=$(lightning-cli getinfo 2>/dev/null)
                         fi
                         
                         local pk=$(echo "$info" | jq -r '.id')
                         local ip=$(echo "$info" | jq -r '.address[] | select(.type == "ipv4") | .address' | head -n 1)
                         local port=$(echo "$info" | jq -r '.address[] | select(.type == "ipv4") | .port' | head -n 1)
                         if [[ -n "$pk" && -n "$ip" ]]; then ext_addr="${pk}@${ip}:${port}"; fi
                    fi
                 else
                    node_type="Unknown/Manual"
                 fi
                ;;
        esac
        echo "$node_type|$ext_addr"
    }

    # Execute Checks
    local setup_method=$(check_docker_setup_status)
    local outbound_ip="N/A"
    local inbound_status="N/A" 
    local inbound_ip="N/A"
    
    # Only run if config is valid
    if [[ -n "$endpoint" && -n "$vpn_port" ]]; then
         outbound_ip=$(perform_outbound_check_status "$setup_method")
         read -r inbound_status inbound_ip <<< "$(perform_inbound_check_status "$endpoint" "$vpn_port")"
    fi

    local node_data=$(get_node_ext_addr_status "$setup_method")
    local node_type=$(echo "$node_data" | cut -d '|' -f 1)
    local node_addr=$(echo "$node_data" | cut -d '|' -f 2)

    echo -e "${BOLD}Node Configuration${NC}"
    print_line
    echo -e "  Type:           $node_type"
    echo -e "  Public Address: $node_addr"
    echo ""
    
    echo -e "${BOLD}Connectivity Check${NC}"
    print_line
    echo -e "  Outbound IP:    $outbound_ip"
    echo -e "  Inbound Check:  $inbound_status ($inbound_ip)"
    echo ""
    
    # Final Verdict
    local outbound_ok=false
    local inbound_ok=false
    
    if [[ "$outbound_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then outbound_ok=true; fi
    if [[ "$inbound_status" == "success" || "$inbound_status" == "success_no_ip" ]]; then inbound_ok=true; fi
    
    if $outbound_ok && $inbound_ok; then
         print_success "Connectivity Verified"
    elif ! $outbound_ok && ! $inbound_ok; then
         print_error "Connectivity Check Failed (Both directions)"
    elif ! $outbound_ok; then
         print_warning "Outbound Check Failed (Inbound OK)"
    elif ! $inbound_ok; then
         print_warning "Inbound Check Failed (Outbound OK)"
    fi
    echo ""

    # Iterative Feedback Support: Debug Summary (Simplified for Telegram)
    echo -e "${BOLD}Debug Summary (Copy for Telegram)${NC}"
    print_line
    local os_info=$(cat /etc/os-release | grep -E "^PRETTY_NAME=" | cut -d= -f2 | tr -d '"')
    local status_plain=$(echo -e "${status_msg}" | sed 's/\x1b\[[0-9;]*m//g')
    
    echo -e "Platform: ${PLATFORM} | Lightning: ${LN_IMPL} | Node: ${node_type}"
    echo -e "OS: ${os_info}"
    echo -e "Tunnel: ${status_plain} | Handshake: ${latest_handshake}"
    echo -e "Inbound: ${inbound_status} | Outbound: ${outbound_ip}"
    echo ""
}

# ---------------------------------------------------------------------------
# RESTART COMMAND
# ---------------------------------------------------------------------------
cmd_restart() {
    print_header "Restarting TunnelSats"
    
    # 0. Auto-detect environment
    auto_detect_environment
    
    # 1. Find Config/Interface
    local config_file
    config_file=$(find_active_wg_config)
    
    # Fallback logic if find fails but tunnel might be up
    if [[ -z "$config_file" ]]; then
       local active_interface=$(sudo wg show | grep "interface:" | head -n 1 | awk '{print $2}')
       if [[ -n "$active_interface" ]]; then
            config_file="/etc/wireguard/${active_interface}.conf"
       else
            print_error "No active TunnelSats configuration or interface found."
            exit 1
       fi
    fi
    
    local interface_name=$(basename "$config_file" .conf)
    local stopped_containers=""
    
    echo ""
    print_info "Platform: ${PLATFORM:-unknown}, Lightning: ${LN_IMPL:-unknown}"
    print_info "Interface: ${interface_name}"
    echo ""

    # 2. Umbrel Specific: Stop App for safety (Privacy first)
    if [[ "$PLATFORM" == "umbrel" ]] && [[ -n "$LN_IMPL" ]]; then
        local filter_name="lnd"
        [[ "$LN_IMPL" == "cln" ]] && filter_name="core-lightning"
        
        print_info "Umbrel detected: Stopping ${LN_IMPL} app for safe restart..."
        stopped_containers=$(docker ps --filter "name=${filter_name}" --format "{{.ID}}")
        
        if [[ -n "$stopped_containers" ]]; then
            docker stop ${stopped_containers} &>/dev/null
            print_success "${LN_IMPL} app stopped (Leak-proof mode)"
        fi
    fi

    # 3. Restart WireGuard Service
    print_info "Stopping WireGuard interface..."
    if systemctl stop "wg-quick@${interface_name}"; then
        print_success "Interface stopped"
    else
        print_warning "Failed to stop interface (might not be running)"
    fi
    
    sleep 1
    
    print_info "Starting WireGuard interface..."
    if systemctl start "wg-quick@${interface_name}"; then
        print_success "Interface started successfully"
    else
        print_error "Failed to start interface"
        journalctl -n 10 -u "wg-quick@${interface_name}" --no-pager
        exit 1
    fi
    
    # 4. Umbrel Specific: Restart App
    if [[ "$PLATFORM" == "umbrel" ]] && [[ -n "$stopped_containers" ]]; then
        print_info "Restarting ${LN_IMPL} app containers..."
        docker start ${stopped_containers} &>/dev/null
        print_success "${LN_IMPL} app restarted"
    fi

    # 5. Verify
    echo ""
    print_info "Verifying status..."
    sleep 2
    if [[ -n "$(wg show ${interface_name} 2>/dev/null)" ]]; then
        print_success "Tunnel Interface is UP"
        echo ""
        cmd_status
    else
        print_error "Tunnel Interface did not come up"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# ARGUMENT PARSING
# ---------------------------------------------------------------------------

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
        restart)
            check_root "$@"
            cmd_restart
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

# ---------------------------------------------------------------------------
# MAIN ENTRY POINT
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"
}

# Run the script
main "$@"
