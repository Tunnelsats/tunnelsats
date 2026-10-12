#!/bin/bash
# TunnelSats Unified Setup Tool - [Verification Entry]
# Consolidates install, pre-check, uninstall, and status commands
#
# Usage: sudo bash tunnelsats.sh [command] [options]

set -e  # Exit on error

# ---------------------------------------------------------------------------
# GLOBAL VARIABLES
# ---------------------------------------------------------------------------

VERSION="3.2"
# Version of the machine-readable CLI contract (--json documents, exit codes, error codes).
# Bumped only for incompatible changes; platforms such as RaspiBlitz pin it.
TS_CONTRACT=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS_SCRIPT_PATH="${SCRIPT_DIR}/${BASH_SOURCE[0]##*/}"
CONFIG_FILE=""
PLATFORM=""
LN_IMPL=""
node_user=""
restarted_systemd_service=""
stopped_docker_containers=""
stopped_wireguard_interface=""
# Lightning daemon container selected by setup_docker_network to own the tunnel IP (may be stopped)
tunnel_target_container=""
WG_CONFIG_BACKUP=""

# Command line state (set by ts_parse_cli)
TS_COMMAND=""
TS_JSON=0
TS_NONINTERACTIVE=0
TS_OPT_YES=0
TS_OPT_PLATFORM=""
TS_OPT_IMPL=""
TS_OPT_PACKAGES=""
TS_WANT_HELP=0
TS_USAGE_ERROR=""
TS_OPTS_GIVEN=()
TS_ARGV=()
# Identifiers accepted by --platform and --impl (the values used internally for PLATFORM and LN_IMPL)
TS_PLATFORMS="raspiblitz umbrel mynode baremetal"
TS_IMPLS="lnd cln lit"
# JSON output: the document goes to TS_OUT_FD (the original stdout, saved before logs move to stderr)
TS_OUT_FD=1
TS_JSON_EMITTED=0

# Injection points for external commands and for the filesystem root of detection reads.
# Defaults are the plain command names and the real root; tests point them at stubs and fixture trees.
WG_BIN="${WG_BIN:-wg}"
WG_QUICK_BIN="${WG_QUICK_BIN:-wg-quick}"
NFT_BIN="${NFT_BIN:-nft}"
IP_BIN="${IP_BIN:-ip}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
TS_FS_ROOT="${TS_FS_ROOT:-}"

# Shared Lightning daemon container resolvers (used by the installer and the generated network monitor)
LND_CONTAINER_REGEX='(^|[[:space:]]|[-_])(lightning[-_])?lnd([-._]lnd)?([-._][0-9]+)?$'
CLN_CONTAINER_REGEX='(core-lightning.*lightningd|lightning.*cln|lightningd|(^|[[:space:]])(core-lightning|clightning)([-._][0-9]+)?$)'
LN_CONTAINER_EXCLUDE_REGEX='[-_](app|web|ui)([-_]|$)'
TUNNEL_CONTAINER_IP="10.9.9.9"
# Prints "attached <static-ip> <live-ip>" when attached to docker-tunnelsats, empty otherwise.
# Static IPAM config is included because stopped containers report an empty live IPAddress.
TUNNEL_NET_INSPECT_FMT='{{with index .NetworkSettings.Networks "docker-tunnelsats"}}attached {{if .IPAMConfig}}{{.IPAMConfig.IPv4Address}}{{end}} {{.IPAddress}}{{end}}'

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
    
    # Calculate visible length (⚡ counts as 2 columns but 1 character)
    local title_len=${#title}
    if [[ "$title" == *"⚡"* ]]; then
        title_len=$((title_len + 1))
    fi
    
    local title_padding=$(( (width - title_len) / 2 ))
    local sub_padding=$(( (width - ${#subtitle}) / 2 ))
    
    echo -e "${BOLD}${BLUE}"
    printf "╔"; printf '═%.0s' $(seq 1 $width); echo "╗"
printf "║%*s%s%*s║\n" "$title_padding" "" "$title" $((width - title_padding - title_len)) ""
printf "║%*s%s%*s║\n" "$sub_padding" "" "$subtitle" $((width - sub_padding - ${#subtitle})) ""
    printf "╚"; printf '═%.0s' $(seq 1 $width); echo "╝"
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

# No ANSI colours when NO_COLOR is set (https://no-color.org), in --json mode, or when stdout or
# stderr is not a terminal. Called once by parse_args before anything is printed.
ts_init_colors() {
    if [[ -n "${NO_COLOR:-}" ]] || [[ "$TS_JSON" -eq 1 ]] || [[ ! -t 1 ]] || [[ ! -t 2 ]]; then
        RED=''
        GREEN=''
        YELLOW=''
        BLUE=''
        BOLD=''
        NC=''
    fi
}

# ---------------------------------------------------------------------------
# CLI CONTRACT 1: NON-INTERACTIVE MODE, JSON OUTPUT AND ERROR CODES
# --json prints exactly one JSON document on stdout; every human log goes to stderr.
# Exit codes: 0 success, 1 failure, 2 usage error or interaction required.
# Error codes: E_USAGE, E_JSON_UNSUPPORTED, E_INTERACTION_REQUIRED (exit 2),
#              E_SHA256_UNAVAILABLE, E_INTERNAL (exit 1).
# ---------------------------------------------------------------------------

# Prints a UTF-8 locale bash can switch to (C.UTF-8 on Debian 12), or C if none is available.
ts_json_utf8_locale() {
    local loc
    for loc in C.UTF-8 C.utf8 en_US.UTF-8; do
        if ( LC_ALL="$loc"; s=$'\xc3\xa4'; [[ ${#s} -eq 1 ]] ) 2>/dev/null; then
            echo "$loc"
            return 0
        fi
    done
    echo "C"
}

# Stores the byte length of $1 in TS_BYTE_LEN (no subshell).
ts_byte_len() {
    local LC_ALL=C
    TS_BYTE_LEN=${#1}
}

# Escapes $1 for use inside a JSON string literal and stores the result in TS_JSON_ESCAPED.
# Works character-wise in a UTF-8 locale: quote and backslash are escaped, control characters
# become \b \f \n \r \t or \u00XX, valid UTF-8 characters pass through unchanged (JSON allows raw
# UTF-8), and every byte that is not valid UTF-8 becomes \ufffd, so the document is always valid
# JSON, even for hostile input. Without a UTF-8 locale every non-ASCII byte becomes \ufffd (pure
# ASCII output). Needs no external tool (no jq, no python).
ts_json_escape() {
    local LC_ALL
    case "${TS_JSON_LOCALE:-}" in
        C|C.UTF-8|C.utf8|en_US.UTF-8) ;;
        *) TS_JSON_LOCALE=$(ts_json_utf8_locale) ;;
    esac
    LC_ALL="$TS_JSON_LOCALE"
    local s="$1" out="" ch code i
    if [[ "$s" != *[![:print:]]* ]] && [[ "$s" != *[\"\\]* ]]; then
        TS_JSON_ESCAPED="$s"
        return 0
    fi
    for ((i = 0; i < ${#s}; i++)); do
        ch="${s:i:1}"
        case "$ch" in
            '"') out+='\"' ;;
            '\') out+='\\' ;;
            $'\n') out+='\n' ;;
            $'\r') out+='\r' ;;
            $'\t') out+='\t' ;;
            $'\b') out+='\b' ;;
            $'\f') out+='\f' ;;
            *)
                ts_byte_len "$ch"
                if [[ "$TS_BYTE_LEN" -gt 1 ]]; then
                    # A whole multibyte character: valid UTF-8 (an invalid byte is always single)
                    out+="$ch"
                elif [[ "$ch" == [[:print:]] ]]; then
                    out+="$ch"
                elif [[ "$ch" == [[:cntrl:]] ]]; then
                    printf -v code '%04x' "'$ch"
                    out+="\\u${code}"
                else
                    out+='\ufffd'
                fi
                ;;
        esac
    done
    TS_JSON_ESCAPED="$out"
}

# JSON value builders. Each one stores a JSON literal in TS_R (no subshells).
ts_j_str() {
    ts_json_escape "$1"
    TS_R="\"${TS_JSON_ESCAPED}\""
}

ts_j_str_or_null() {
    if [[ -n "$1" ]]; then
        ts_j_str "$1"
    else
        TS_R="null"
    fi
}

ts_j_int_or_null() {
    if [[ "$1" =~ ^[0-9]{1,15}$ ]]; then
        TS_R="$((10#$1))"
    else
        TS_R="null"
    fi
}

ts_j_bool_or_null() {
    case "$1" in
        true|1) TS_R="true" ;;
        false|0) TS_R="false" ;;
        *) TS_R="null" ;;
    esac
}

# Array of JSON literals: ts_j_arr "$lit1" "$lit2" ...
ts_j_arr() {
    local IFS=","
    TS_R="[$*]"
}

# Object from pairs "<type>:<key>" "<value>". Types: s string, sn string (null if empty),
# i integer (null if not a number), b boolean (null if unknown), r raw JSON literal.
ts_j_obj() {
    local out="" sep="" spec val
    while [[ $# -ge 2 ]]; do
        spec="$1"
        val="$2"
        shift 2
        case "${spec%%:*}" in
            s) ts_j_str "$val" ;;
            sn) ts_j_str_or_null "$val" ;;
            i) ts_j_int_or_null "$val" ;;
            b) ts_j_bool_or_null "$val" ;;
            *) TS_R="$val" ;;
        esac
        out+="${sep}\"${spec#*:}\":${TS_R}"
        sep=","
    done
    TS_R="{${out}}"
}

# Error object: $1 = code, $2 = class, $3 = message, $4 = optional flag that answers a prompt.
ts_j_error() {
    if [[ -n "${4:-}" ]]; then
        ts_j_obj s:code "$1" s:class "$2" s:message "$3" s:flag "$4"
    else
        ts_j_obj s:code "$1" s:class "$2" s:message "$3"
    fi
}

# Prints the contract-1 document: $1 = exit code, $2 = errors array literal, $3 = extra members
# (raw '"key":value' pairs, may be empty). Must run in the main shell: a document printed from a
# subshell is not recorded, and the exit guard would then print a second one.
ts_json_document() {
    local rc="$1" errors="${2:-[]}" extra="${3:-}" ok="false" cmd ver doc
    if [[ "$rc" -eq 0 ]]; then
        ok="true"
    fi
    ts_j_str_or_null "$TS_COMMAND"
    cmd="$TS_R"
    ts_j_str "$VERSION"
    ver="$TS_R"
    doc="{\"contract\":${TS_CONTRACT},\"command\":${cmd},\"tool_version\":${ver},\"ok\":${ok},\"exit_code\":${rc},\"errors\":${errors}"
    if [[ -n "$extra" ]]; then
        doc+=",${extra}"
    fi
    doc+="}"
    printf '%s\n' "$doc" >&"$TS_OUT_FD"
    TS_JSON_EMITTED=1
}

# EXIT trap in --json mode: guarantees exactly one document even if a command aborts early.
ts_json_exit_guard() {
    local rc=$?
    trap - EXIT
    if [[ "$TS_JSON_EMITTED" -ne 1 ]]; then
        if [[ "$rc" -eq 0 ]]; then
            rc=1
        fi
        ts_j_error E_INTERNAL internal "'${TS_COMMAND}' ended without a result (exit code ${rc})"
        ts_json_document "$rc" "[${TS_R}]"
    fi
    exit "$rc"
}

# Reports an error on stderr (and as the JSON document in --json mode) and exits.
# $1 = exit code, $2 = error code, $3 = class, $4 = message, $5 = optional flag, $6 = optional hint.
ts_fail() {
    local rc="$1" code="$2" class="$3" message="$4" flag="${5:-}" hint="${6:-}" shown
    # print_error uses echo -e: neutralise backslashes and control characters from user input
    shown="${message//\\/\\\\}"
    shown="${shown//[[:cntrl:]]/?}"
    print_error "${shown} [${code}]"
    if [[ -n "$hint" ]]; then
        echo "$hint" >&2
    fi
    if [[ "$TS_JSON" -eq 1 ]]; then
        ts_j_error "$code" "$class" "$message" "$flag"
        ts_json_document "$rc" "[${TS_R}]"
    fi
    exit "$rc"
}

ts_usage_error() {
    ts_fail 2 E_USAGE usage "$1" "" "Run 'tunnelsats.sh help' for usage."
}

# Fails with E_INTERACTION_REQUIRED (exit 2): $1 = flag (with a value placeholder) that answers
# the prompt, $2 = prompt text, $3 = optional reason.
ts_interaction_required() {
    local flag="$1" prompt="$2" reason="${3:-non-interactive mode never prompts}"
    while [[ "$prompt" == *[[:space:]] ]]; do
        prompt="${prompt%?}"
    done
    ts_fail 2 E_INTERACTION_REQUIRED interaction "Cannot answer \"${prompt}\": ${reason}. Pass ${flag}." "${flag%% *}"
}

# Fails in non-interactive mode before a selection menu is printed. $1 = flag, $2 = prompt.
ts_require_interaction() {
    if [[ "$TS_NONINTERACTIVE" -eq 1 ]]; then
        ts_interaction_required "$1" "$2"
    fi
    return 0
}

# Reads the answer to an interactive prompt into the variable named $1.
#   $2 = flag that answers the prompt without interaction (named in the error)
#   $3 = prompt, shown exactly as before (read -p shows it only when stdin is a terminal)
#   $4 = optional answer to use at end of input. Without it, end of input fails like a missing
#        answer in non-interactive mode instead of silently aborting through set -e.
# Non-interactive mode never reads: it fails with E_INTERACTION_REQUIRED (exit 2).
# Piped answers keep working: a non-TTY stdin does not imply non-interactive mode.
ts_ask() {
    local __ts_var="$1" __ts_flag="$2" __ts_prompt="$3" __ts_reply=""
    ts_require_interaction "$__ts_flag" "$__ts_prompt"
    if ! read -r -p "$__ts_prompt" __ts_reply && [[ -z "$__ts_reply" ]]; then
        if [[ $# -ge 4 ]]; then
            print_warning "No answer received (end of input); using '${4}'"
            __ts_reply="$4"
        else
            ts_interaction_required "$__ts_flag" "$__ts_prompt" "no answer received (end of input)"
        fi
    fi
    printf -v "$__ts_var" '%s' "$__ts_reply"
}

# Yes/no confirmation answered by --yes: sets the variable named $1 to "y" when --yes was given,
# otherwise asks $2 like ts_ask (and fails in non-interactive mode).
ts_confirm() {
    if [[ "$TS_OPT_YES" -eq 1 ]]; then
        printf -v "$1" '%s' "y"
        return 0
    fi
    ts_ask "$1" "--yes" "$2"
}

# Succeeds if word $1 is in the space-separated list $2.
ts_in_list() {
    local item
    # $2 is split into words on purpose
    # shellcheck disable=SC2086
    for item in $2; do
        if [[ "$item" == "$1" ]]; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# NODE CONFIGURATION INSTRUCTIONS HELPER
# Used by cmd_install (post-install) and cmd_status (troubleshooting)
# ---------------------------------------------------------------------------

print_node_config_instructions() {
    local vpn_dns="$1"
    local vpn_port="$2"
    local context="${3:-install}"  # 'install' or 'status'
    
    if [[ "$LN_IMPL" == "lnd" ]]; then
        if [[ "$PLATFORM" == "umbrel" ]]; then
             echo -e "Edit: ${BOLD}${BLUE}~/umbrel/app-data/lightning/data/lnd/lnd.conf${NC}"
             if [[ "$context" == "install" ]]; then
                 echo -e "${YELLOW}Note: If 'tor.streamisolation' or 'tor.skip-proxy...' are already enabled in UI,${NC}"
                 echo -e "${YELLOW}      do NOT duplicate them.${NC}"
             fi
             echo ""
             echo "#########################################"
             echo -e "${BOLD}${BLUE}[Application Options]${NC}"
             echo -e "${YELLOW}externalhosts=${vpn_dns}:${vpn_port}${NC}"
             echo ""
             echo -e "${BOLD}${BLUE}[Tor]${NC}"
             echo -e "${YELLOW}tor.streamisolation=false${NC}"
             echo -e "${YELLOW}tor.skip-proxy-for-clearnet-targets=true${NC}"
             echo "#########################################"
        else
             local lnd_user="${node_user:-bitcoin}"
             local lnd_path="/home/$lnd_user/.lnd/lnd.conf"
             
             # Forensic path guessing for Bare Metal
             [[ ! -f "$lnd_path" ]] && [[ -f "/home/bitcoin/.lnd/lnd.conf" ]] && lnd_path="/home/bitcoin/.lnd/lnd.conf"
             [[ ! -f "$lnd_path" ]] && [[ -f "/home/lnd/.lnd/lnd.conf" ]] && lnd_path="/home/lnd/.lnd/lnd.conf"
             [[ ! -f "$lnd_path" ]] && [[ -f "/data/lnd/lnd.conf" ]] && lnd_path="/data/lnd/lnd.conf"
             [[ ! -f "$lnd_path" ]] && [[ -f "/mnt/hdd/lnd/lnd.conf" ]] && lnd_path="/mnt/hdd/lnd/lnd.conf"
             
             echo -e "Edit: ${BOLD}${BLUE}sudo nano $lnd_path${NC}"
             if [[ "$context" == "install" ]]; then
                 echo -e "${YELLOW}Note: Place settings in their respective sections. Do NOT duplicate categories.${NC}"
             fi
             echo ""
             echo "#########################################"
             echo -e "${BOLD}${BLUE}[Application Options]${NC}"
             echo -e "${YELLOW}listen=0.0.0.0:9735${NC}"
             echo -e "${YELLOW}externalhosts=${vpn_dns}:${vpn_port}${NC}"
             echo ""
             echo -e "${BOLD}${BLUE}[Tor]${NC}"
             echo -e "${YELLOW}tor.streamisolation=false${NC}"
             echo -e "${YELLOW}tor.skip-proxy-for-clearnet-targets=true${NC}"
             echo "#########################################"
        fi
        
    elif [[ "$LN_IMPL" == "cln" ]]; then
        if [[ "$PLATFORM" == "umbrel" ]]; then
             echo -e "1. Edit: ${BOLD}${BLUE}sudo nano ~/umbrel/app-data/core-lightning/data/lightningd/bitcoin/config${NC}"
             echo "#########################################"
             echo -e "${YELLOW}bind-addr=0.0.0.0:9735${NC}"
             echo -e "${YELLOW}announce-addr=${vpn_dns}:${vpn_port}${NC}"
             echo -e "${YELLOW}always-use-proxy=false${NC}"
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
             echo -e "Edit: ${BOLD}${BLUE}config${NC}"
             echo ""
             echo "#########################################"
             echo -e "${YELLOW}bind-addr=0.0.0.0:9735${NC}"
             echo -e "${YELLOW}announce-addr=${vpn_dns}:${vpn_port}${NC}"
             echo -e "${YELLOW}always-use-proxy=false${NC}"
             echo "#########################################"
        fi
        
    elif [[ "$LN_IMPL" == "lit" ]]; then
         local lit_path="$HOME/.lit/lit.conf"
         # Check both lit.service and litd.service for config path
         local lit_service_file=""
         [[ -f "/etc/systemd/system/litd.service" ]] && lit_service_file="/etc/systemd/system/litd.service"
         [[ -f "/etc/systemd/system/lit.service" ]] && lit_service_file="/etc/systemd/system/lit.service"
         if [[ -n "$lit_service_file" ]]; then
             local extracted_path=$(grep "LIT_CONFIG_FILE" "$lit_service_file" | sed 's/.*LIT_CONFIG_FILE=//' | tr -d '"' | tr -d "'" | xargs)
             [[ -n "$extracted_path" ]] && lit_path="$extracted_path"
         fi
         echo -e "Edit: ${BOLD}${BLUE}$lit_path${NC}"
         echo ""
         echo "#########################################"
         echo -e "${BOLD}${BLUE}[Application Options]${NC}"
         echo -e "${YELLOW}externalhosts=${vpn_dns}:${vpn_port}${NC}"
         echo ""
         echo -e "${BOLD}${BLUE}[Tor]${NC}"
         echo -e "${YELLOW}tor.streamisolation=false${NC}"
         echo -e "${YELLOW}tor.skip-proxy-for-clearnet-targets=true${NC}"
         echo "#########################################"
    fi
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

ufw_rule_marker_file() {
    local interface="$1"
    local safe_interface="${interface//[^[:alnum:]_.-]/_}"
    echo "/etc/wireguard/.tunnelsats-ufw-9735-${safe_interface}.created"
}

is_port_allowed_in_ufw() {
    local interface="$1"
    local port="$2"
    local ufw_status_out="$3"
    
    if [[ -z "$ufw_status_out" ]]; then
        if ! command -v ufw >/dev/null 2>&1; then
            return 1
        fi
        ufw_status_out=$(ufw status 2>/dev/null)
    fi
    
    if ! echo "$ufw_status_out" | grep -q "Status: active"; then
        return 0 # If UFW is not active, the port is allowed/unfiltered
    fi
    
    local ufw_rules
    ufw_rules=$(echo "$ufw_status_out" | grep -Ei "(^|[[:space:]])${port}(/|[[:space:]]|$)" || true)
    if [[ -z "$ufw_rules" ]]; then
        return 1
    fi
    
    while IFS= read -r line; do
        if [[ ! "$line" =~ "ALLOW" ]]; then
            continue
        fi

        if [[ "$line" =~ ALLOW[[:space:]]+OUT ]]; then
            continue
        fi
        
        if [[ "$line" =~ "on " ]]; then
            if [[ "$line" =~ [[:space:]]on[[:space:]]+([^[:space:]]+) ]]; then
                local rule_interface="${BASH_REMATCH[1]}"
                if [[ "$rule_interface" == "$interface" ]]; then
                    return 0
                fi
            fi
        else
            # Global rule
            return 0
        fi
    done <<< "$ufw_rules"
    
    return 1
}

check_ufw_configuration() {
    local interface="$1"
    
    # Check if ufw command exists
    if ! command -v ufw >/dev/null 2>&1; then
        return 0
    fi
    
    local ufw_status_out
    ufw_status_out=$(ufw status 2>/dev/null)
    # Check if ufw is active
    if ! echo "$ufw_status_out" | grep -q "Status: active"; then
        print_info "UFW is installed but inactive (not filtering traffic)."
        return 0
    fi
    
    if is_port_allowed_in_ufw "$interface" "9735" "$ufw_status_out"; then
        print_success "UFW is active and inbound traffic on port 9735 is allowed."
        return 0
    else
        print_info "UFW is active but port 9735 is not allowed on $interface. Adding rule..."
        if ufw allow in on "$interface" to any port 9735 proto tcp comment "TunnelSats" &>/dev/null; then
            touch "$(ufw_rule_marker_file "$interface")" 2>/dev/null || true
            print_success "Added UFW rule: allow inbound TCP 9735 on $interface"
            return 0
        else
            print_error "Failed to add UFW rule for port 9735 on $interface"
            return 0 # Return 0 so it doesn't trigger set -e abort
        fi
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

# Succeeds if file name $1 is an installed TunnelSats WireGuard config that wg-quick can load:
# tunnelsatsv2.conf or tunnelsats-<name>.conf, with an interface name of at most 15 characters.
ts_valid_installed_config_name() {
    local name="$1" iface="${1%.conf}"
    [[ "$name" =~ ^tunnelsats(v2|-[A-Za-z0-9_=+.-]+)\.conf$ ]] && [[ ${#iface} -le 15 ]]
}

# Installed TunnelSats WireGuard configs and the one in use. One rule for detect, status, restart
# and uninstall, so they never pick different tunnels:
#   1. an explicit config (--config) wins
#   2. else <dir>/tunnelsatsv2.conf (the canonical name)
#   3. else the only <dir>/tunnelsats-*.conf
#   4. else nothing is picked: "ambiguous" (several candidates) or "none"
# $1 = explicit config or "", $2 = filesystem root prefix (detect passes TS_FS_ROOT), $3 = WireGuard
# directory below the root (default /etc/wireguard). Sets TS_WG_SELECTION (explicit, canonical,
# single, ambiguous, none, permission_denied), TS_WG_SELECTED (path below the root, empty unless a
# config is picked) and TS_WG_CANDIDATES (every TunnelSats config found, sorted byte-wise).
ts_select_wg_config() {
    local LC_ALL=C
    local explicit="$1" root="${2:-}" wg_dir="${3:-/etc/wireguard}" entry name unreadable=0 parent
    local dir="${root}${wg_dir}"
    TS_WG_SELECTION="none"
    TS_WG_SELECTED=""
    TS_WG_CANDIDATES=()
    if [[ -e "$dir" ]]; then
        if [[ ! -r "$dir" ]] || [[ ! -x "$dir" ]]; then
            unreadable=1
        fi
    else
        # Absent, or hidden behind a parent directory that may not be searched: then nobody can
        # tell whether a config exists, so this is permission_denied, not none
        parent="$dir"
        while [[ "$parent" == */* ]]; do
            parent="${parent%/*}"
            if [[ -z "$parent" ]]; then
                break
            fi
            if [[ -e "$parent" ]]; then
                if [[ -d "$parent" ]] && [[ ! -x "$parent" ]]; then
                    unreadable=1
                fi
                break
            fi
        done
    fi
    # Glob results are sorted (byte-wise with LC_ALL=C); names must be valid interface names
    for entry in "$dir"/tunnelsats-*.conf "$dir"/tunnelsatsv2.conf; do
        name="${entry##*/}"
        if [[ -f "$entry" ]] && ts_valid_installed_config_name "$name"; then
            TS_WG_CANDIDATES+=("${wg_dir}/${name}")
        fi
    done
    if [[ -n "$explicit" ]]; then
        TS_WG_SELECTION="explicit"
        TS_WG_SELECTED="$explicit"
    elif [[ -f "${dir}/tunnelsatsv2.conf" ]]; then
        TS_WG_SELECTION="canonical"
        TS_WG_SELECTED="${wg_dir}/tunnelsatsv2.conf"
    elif [[ "$unreadable" -eq 1 ]]; then
        TS_WG_SELECTION="permission_denied"
    elif [[ ${#TS_WG_CANDIDATES[@]} -eq 1 ]]; then
        TS_WG_SELECTION="single"
        TS_WG_SELECTED="${TS_WG_CANDIDATES[0]}"
    elif [[ ${#TS_WG_CANDIDATES[@]} -gt 1 ]]; then
        TS_WG_SELECTION="ambiguous"
    fi
    return 0
}

# The installed config used by status and restart (ts_select_wg_config on ${WG_DIR:-/etc/wireguard}).
# Several candidates are a question: it is asked like the install config selection and answered
# by --config, so non-interactive mode fails with E_INTERACTION_REQUIRED before anything changes
# and no command ever picks one of several tunnels on its own.
# Sets TS_WG_RESOLVED; returns 1 if no TunnelSats config is installed.
ts_resolve_wg_config() {
    local selected=""
    TS_WG_RESOLVED=""
    ts_select_wg_config "$CONFIG_FILE" "" "${WG_DIR:-/etc/wireguard}"
    case "$TS_WG_SELECTION" in
        explicit|canonical|single)
            TS_WG_RESOLVED="$TS_WG_SELECTED"
            ;;
        ambiguous)
            print_warning "Several TunnelSats configs are installed and none is named tunnelsatsv2.conf."
            selected=$(select_config_interactive "${TS_WG_CANDIDATES[@]}") || exit $?
            TS_WG_RESOLVED="$selected"
            ;;
        *)
            return 1
            ;;
    esac
    return 0
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
            # Old format: #VPNPort = 48049; website: # Port Forwarding: 24556; StartOS: # VPNPort: 31337
            # The whole number after the label is returned, never truncated, and callers check the
            # range 1-65535 (ts_normalize_port). A value that does not start with a digit is returned
            # as written, so that it is reported as invalid instead of looking like a missing port.
            local port=$(sed -nE 's/^[[:space:]]*#[[:space:]]*(VPNPort|Port Forwarding)[[:space:]]*[:=]?[[:space:]]*//Ip' "$config_file" | head -1 | sed -E 's/^([0-9]+)([^0-9.,].*)?$/\1/; s/[[:space:]]+$//')
            echo "$port"
            ;;
        expiry)
            # Old format: #ValidUntil (UTC time) = 2025-06-29T08:18:33.839Z
            # Website, API and StartOS format: # Valid Until: 2026-01-07T08:18:33.839Z
            # The label is matched explicitly, so the colons inside the timestamp are kept.
            local expiry=$(sed -nE 's|^[[:space:]]*#[[:space:]]*Valid[[:space:]]*Until([[:space:]]*\(UTC time\))?[[:space:]]*[:=][[:space:]]*||Ip' "$config_file" | head -1 | sed -E 's/[[:space:]]+$//')
            echo "$expiry"
            ;;
        pubkey)
            # Old format: #myPubKey = 6gTYyE8eFW7579zIOlvEgehrhGb01SrqC5dgQupxlAU=
            # New format: # myPubKey: <user's-public-key>
            # A hint only: the key in use is derived from PrivateKey (ts_derive_wg_pubkey).
            local pubkey=$(sed -nE 's|^[[:space:]]*#[[:space:]]*myPubKey[[:space:]]*[:=][[:space:]]*([A-Za-z0-9+/]{43}=).*|\1|Ip' "$config_file" | head -1)
            echo "$pubkey"
            ;;
        *)
            return 1
            ;;
    esac
}

# Prints port $1 as a plain decimal number if it is a valid port (1-65535); fails otherwise.
# Leading zeros are accepted. Long digit strings are rejected before any arithmetic, so a huge
# value cannot wrap around into the valid range.
ts_normalize_port() {
    if [[ "$1" =~ ^0*([1-9][0-9]{0,4})$ ]] && (( 10#${BASH_REMATCH[1]} <= 65535 )); then
        echo "$((10#${BASH_REMATCH[1]}))"
        return 0
    fi
    return 1
}

# Forwarded VPN port of config $1 for the installer: prints the port (1-65535), or nothing if the
# config has no port comment. An invalid value is never truncated or used: it is reported with a
# warning on stderr and treated like a missing comment.
ts_config_vpn_port() {
    local raw="" port="" shown=""
    raw=$(parse_config_metadata "$1" port) || raw=""
    if [[ -z "$raw" ]]; then
        return 0
    fi
    if port=$(ts_normalize_port "$raw"); then
        echo "$port"
        return 0
    fi
    # print_warning uses echo -e: neutralise backslashes and control characters from the file
    shown="${raw:0:32}"
    shown="${shown//\\/\\\\}"
    shown="${shown//[[:cntrl:]]/?}"
    print_warning "Ignoring invalid forwarded port '${shown}' in ${1##*/} (expected 1-65535)"
    return 0
}

# ---------------------------------------------------------------------------
# CONFIG FILE DETECTION
# ---------------------------------------------------------------------------

find_config_files() {
    local search_dir="${1:-.}"
    local found_files=()
    
    # Priority 1: tunnelsats_*.conf files (sorted, so the selection menu is stable)
    while IFS= read -r -d '' file; do
        found_files+=("$file")
    done < <(find "$search_dir" -maxdepth 1 -name "tunnelsats_*.conf" -type f -print0 2>/dev/null | LC_ALL=C sort -z)
    
    # Priority 2: If none found, look for any .conf files
    if [[ ${#found_files[@]} -eq 0 ]]; then
        while IFS= read -r -d '' file; do
            # Exclude system config files
            if [[ ! "$file" =~ /(nftables|sysctl|resolv)\.conf$ ]]; then
                found_files+=("$file")
            fi
        done < <(find "$search_dir" -maxdepth 1 -name "*.conf" -type f -print0 2>/dev/null | LC_ALL=C sort -z)
    fi
    
    # Return the array
    [[ ${#found_files[@]} -gt 0 ]] && printf '%s\n' "${found_files[@]}"
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
    ts_ask selection "--config <file>" "Select config [1-${#files[@]}]: "
    
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
    
    # Priority 1: If --config explicitly provided via argument, verify and use it
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
    
    # Priority 2: Auto-detect config files in current directory
    mapfile -t found_files < <(find_config_files "$SCRIPT_DIR")
    
    if [[ ${#found_files[@]} -eq 0 ]]; then
        print_error "No WireGuard config files found"
        echo "" >&2
        echo "Expected files:" >&2
        echo "  • tunnelsats_<server>.conf (e.g., tunnelsats_us-east.conf)" >&2
        echo "  • Any .conf file in the current directory" >&2
        echo "  • Or specify a config path with --config <file>" >&2
        echo "" >&2
        echo "Please specify your config file and try again." >&2
        exit 1
        
    elif [[ ${#found_files[@]} -eq 1 ]]; then
        print_success "Auto-detected config: ${found_files[0]##*/}"
        echo "${found_files[0]}"
        return 0
        
    else
        # Multiple configs - interactive selection (--config answers it). A failed selection
        # (invalid answer, end of input, non-interactive mode) must stop here: this function runs
        # in a command substitution, where set -e is not inherited.
        local selected
        selected=$(select_config_interactive "${found_files[@]}") || exit $?
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
  install                   Install WireGuard VPN configuration
  install --config <file>   Install with specific config file
  pre-check                 Check system compatibility
  uninstall                 Remove TunnelSats installation
  status                    Show subscription and connection status
  restart                   Restart the WireGuard tunnel interface
  detect                    Read-only report: platform, Lightning units, existing
                            install, config, capabilities, conflicts (no root needed)
  version                   Show version, CLI contract and script sha256
  help                      Show this help message

Options (accepted before or after the command):
  --config <file>           WireGuard config to use (install, status, restart)
  --platform <id>           raspiblitz, umbrel, mynode or baremetal
                            (install, uninstall, status, restart)
  --impl <id>               lnd, cln or lit (install, uninstall, status, restart)
  --yes                     Answer yes to confirmation prompts
  --remove-packages         uninstall: also remove nftables and wireguard-tools
                            (and cgroup-tools)
  --keep-packages           uninstall: keep system packages without asking
  --non-interactive         Never prompt: a question that no option answers fails
                            with exit code 2 before any change is made
  --json                    One JSON document on stdout, logs on stderr
                            (version, detect); implies --non-interactive

Exit codes: 0 success, 1 failure, 2 usage error or interaction required

Examples:
  # Run compatibility check first
  sudo bash tunnelsats.sh pre-check
  
  # Install with auto-detection
  sudo bash tunnelsats.sh install
  
  # Install with specific config
  sudo bash tunnelsats.sh install --config tunnelsats_us-east.conf
  
  # Install without prompts (for scripts and node platforms)
  sudo bash tunnelsats.sh install --non-interactive --config tunnelsats_us-east.conf --platform raspiblitz --impl lnd
  
  # Check status
  sudo bash tunnelsats.sh status
  
  # Restart WireGuard tunnel
  sudo bash tunnelsats.sh restart

  # Clean uninstall
  sudo bash tunnelsats.sh uninstall

  # Inspect the node without changing anything
  bash tunnelsats.sh detect --json

For more information:
  Website: https://tunnelsats.com
  Guide: https://tunnelsats.com/guide
  Support: https://tunnelsats.com/join-telegram

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
        elif [[ ${dockerProcess} == *clightning* ]] || [[ ${dockerProcess} == *core-lightning* ]]; then
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

# Helper functions for install command

check_umbrel_version() {
    local version_file="${UMBREL_VERSION_FILE:-/opt/umbreld/package.json}"
    if [[ -f "$version_file" ]]; then
        local version
        if command -v jq &>/dev/null; then
            version=$(jq -r '.version // empty' "$version_file" 2>/dev/null || true)
        else
            version=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$version_file" 2>/dev/null | head -n 1 || true)
        fi
        if [[ -z "$version" ]]; then
            echo "Warning: could not determine Umbrel OS version from $version_file" >&2
            return 0
        fi
        if [[ -n "$version" ]]; then
            local major
            local minor
            major=$(echo "$version" | cut -d. -f1 | sed 's/^[^0-9]*//; s/[^0-9].*$//')
            minor=$(echo "$version" | cut -d. -f2 | sed 's/^[^0-9]*//; s/[^0-9].*$//')
            
            major=${major:-0}
            minor=${minor:-0}
            
            if (( 10#$major > 1 || (10#$major == 1 && 10#$minor >= 6) )); then
                echo "" >&2
                print_error "TunnelSats CLI setup is discontinued for Umbrel OS versions 1.6 and above."
                echo -e "Please install TunnelSats natively through the Umbrel Community App Store:" >&2
                echo -e "  ${BLUE}URL: https://github.com/Tunnelsats/ts-umbrel-app${NC}" >&2
                echo -e "  ${YELLOW}(Umbrel > App Store > Settings > Add App Store)${NC}" >&2
                echo -e "More details: https://github.com/Tunnelsats/tunnelsats/discussions/193" >&2
                echo "" >&2
                exit 1
            fi
        fi
    fi
}

# Platform markers in detection order: "<platform> <d|f> <path>" (directory or file).
TS_PLATFORM_MARKERS=(
    "raspiblitz d /home/admin/config.scripts"
    "umbrel d /home/umbrel/umbrel"
    "umbrel d /umbrel"
    "umbrel f /usr/bin/umbrel"
    "mynode d /usr/share/mynode"
)

# Prints the platform suggested by the first matching marker (nothing if none matches).
# $1 = optional filesystem root prefix (detect passes TS_FS_ROOT).
ts_guess_platform() {
    local root="${1:-}" marker platform rest kind path
    for marker in "${TS_PLATFORM_MARKERS[@]}"; do
        platform="${marker%% *}"
        rest="${marker#* }"
        kind="${rest%% *}"
        path="${rest#* }"
        if { [[ "$kind" == "d" ]] && [[ -d "${root}${path}" ]]; } || { [[ "$kind" == "f" ]] && [[ -f "${root}${path}" ]]; }; then
            echo "$platform"
            return 0
        fi
    done
    return 0
}

detect_platform() {
    local guess=""
    guess=$(ts_guess_platform)

    # --platform answers both questions below without interaction
    if [[ -n "$TS_OPT_PLATFORM" ]]; then
        if [[ -n "$guess" ]] && [[ "$guess" != "$TS_OPT_PLATFORM" ]]; then
            print_warning "Using --platform ${TS_OPT_PLATFORM} (detected: ${guess})"
        fi
        PLATFORM="$TS_OPT_PLATFORM"
        return 0
    fi

    if [[ -n "$guess" ]]; then
        ts_ask use_guess "--platform <id>" "Detected Platform: ${guess}. Correct? [Y/n]: "
        if [[ "$use_guess" =~ ^[Yy]$ ]] || [[ -z "$use_guess" ]]; then
            PLATFORM="$guess"
            return 0
        fi
    fi

    ts_require_interaction "--platform <id>" "Select [1-4]: "
    echo "What Lightning node package are you running?" >&2
    echo "  1) RaspiBlitz" >&2
    echo "  2) Umbrel" >&2
    echo "  3) myNode" >&2
    echo "  4) RaspiBolt / Bare Metal" >&2
    echo "" >&2
    ts_ask answer "--platform <id>" "Select [1-4]: "
    
    case $answer in
        1) PLATFORM="raspiblitz" ;;
        2) 
            PLATFORM="umbrel"
            ;;
        3) PLATFORM="mynode" ;;
        4) PLATFORM="baremetal" ;;
        *) print_error "Invalid selection"; exit 1 ;;
    esac
    return 0
}

get_lightning_docker_containers() {
    # Returns container IDs matching the lightning daemon for $LN_IMPL
    # $1 (optional): extra flags for docker ps (e.g. "-a" to list stopped containers as well)
    local extra_flags="${1:-}"
    if ! command -v docker >/dev/null 2>&1; then
        return 0
    fi
    local regex
    if [[ "$LN_IMPL" == "cln" ]]; then
        regex="$CLN_CONTAINER_REGEX"
    elif [[ "$LN_IMPL" == "lnd" ]]; then
        regex="$LND_CONTAINER_REGEX"
    else
        # If LN_IMPL is not set, match either implementation
        regex="${LND_CONTAINER_REGEX}|${CLN_CONTAINER_REGEX}"
    fi
    docker ps $extra_flags --format "{{.ID}} {{.Names}}" 2>/dev/null | \
        grep -Ei "$regex" | \
        grep -Eiv "$LN_CONTAINER_EXCLUDE_REGEX" | \
        awk '{print $1}'
}

# Selects exactly one Lightning daemon container to own the static tunnel IP (10.9.9.9).
# Preference: the daemon stopped for this restart > running daemons > newest stopped daemon.
# Fails (return 1) if multiple candidates would compete for the same static IP.
select_tunnel_target_container() {
    local candidates=""
    if [[ -n "$stopped_docker_containers" ]]; then
        candidates="$stopped_docker_containers"
    else
        candidates=$(get_lightning_docker_containers)
    fi
    if [[ -z "$candidates" ]]; then
        # No daemon running: keep the stopped container that already owns the tunnel IP (sticky owner),
        # otherwise fall back to the newest one (docker ps -a lists newest first).
        local c
        for c in $(get_lightning_docker_containers "-a"); do
            if [[ " $(docker inspect -f "$TUNNEL_NET_INSPECT_FMT" "$c" 2>/dev/null || true) " == *" ${TUNNEL_CONTAINER_IP} "* ]]; then
                candidates="$c"
                break
            fi
        done
        [[ -z "$candidates" ]] && candidates=$(get_lightning_docker_containers "-a" | head -n 1)
    fi
    local count
    count=$(printf '%s\n' $candidates | grep -c . || true)
    if [[ "$count" -gt 1 ]]; then
        print_error "Multiple running ${LN_IMPL} daemon containers found ($(echo $candidates)). Only one can own the tunnel IP ${TUNNEL_CONTAINER_IP}."
        return 1
    fi
    echo "$candidates"
}

# Ensures exactly the given container holds 10.9.9.9 on docker-tunnelsats.
# Reattaches it if attached with another address and releases the static IP from stale (stopped) containers.
attach_container_to_tunnel_network() {
    local cid="$1"
    local state
    state=$(docker inspect -f "$TUNNEL_NET_INSPECT_FMT" "$cid" 2>/dev/null || true)
    if [[ " $state " == *" ${TUNNEL_CONTAINER_IP} "* ]]; then
        return 0
    fi

    if [[ -n "$state" ]]; then
        print_info "Container ($cid) is attached to docker-tunnelsats with a different address; reattaching with ${TUNNEL_CONTAINER_IP}..."
        if ! docker network disconnect -f docker-tunnelsats "$cid" >/dev/null 2>&1; then
            print_error "Failed to detach container ($cid) from docker-tunnelsats"
            return 1
        fi
    fi

    local other other_state
    for other in $(get_lightning_docker_containers "-a"); do
        [[ "$other" == "$cid" ]] && continue
        other_state=$(docker inspect -f "$TUNNEL_NET_INSPECT_FMT" "$other" 2>/dev/null || true)
        [[ " $other_state " == *" ${TUNNEL_CONTAINER_IP} "* ]] || continue
        if [[ "$(docker inspect -f '{{.State.Running}}' "$other" 2>/dev/null)" == "true" ]]; then
            print_error "Running container ($other) already holds ${TUNNEL_CONTAINER_IP} on docker-tunnelsats. Refusing to evict it."
            return 1
        fi
        print_info "Releasing ${TUNNEL_CONTAINER_IP} from stale stopped container ($other)..."
        if ! docker network disconnect -f docker-tunnelsats "$other" >/dev/null 2>&1; then
            print_error "Failed to detach stale container ($other) from docker-tunnelsats"
            return 1
        fi
    done

    print_info "Connecting container ($cid) to docker-tunnelsats network (${TUNNEL_CONTAINER_IP})..."
    if ! docker network connect --ip "$TUNNEL_CONTAINER_IP" docker-tunnelsats "$cid" >/dev/null 2>&1; then
        print_error "Failed to connect container ($cid) to docker-tunnelsats network"
        return 1
    fi
    return 0
}


# Succeeds if LIT runs in integrated mode (it manages its own LND).
# $1 = optional filesystem root prefix (detect passes TS_FS_ROOT).
ts_lit_integrated_mode() {
    local root="${1:-}"
    local s_file="${root}/etc/systemd/system/litd.service"
    [[ ! -f "$s_file" ]] && s_file="${root}/etc/systemd/system/lit.service"
    grep -qi "lnd-mode=integrated" "$s_file" 2>/dev/null || grep -qi "lnd-mode.*integrated" "${root}/etc/lit/lit.conf" 2>/dev/null || grep -qi "lnd-mode.*integrated" "${root}${HOME}/.lit/lit.conf" 2>/dev/null
}

# Prints the Lightning implementation suggested by systemd units (lnd, cln, lit or nothing).
# $1 = optional filesystem root prefix (detect passes TS_FS_ROOT).
ts_guess_ln_impl_systemd() {
    local root="${1:-}"
    local sd="${root}/etc/systemd/system"
    if [[ -f "$sd/lnd.service" ]] || "$SYSTEMCTL_BIN" is-active --quiet lnd 2>/dev/null; then
        echo "lnd"
    elif [[ -f "$sd/lightningd.service" ]] || "$SYSTEMCTL_BIN" is-active --quiet lightningd 2>/dev/null; then
        echo "cln"
    elif [[ -f "$sd/litd.service" ]] || [[ -f "$sd/lit.service" ]] || "$SYSTEMCTL_BIN" is-active --quiet litd 2>/dev/null || "$SYSTEMCTL_BIN" is-active --quiet lit 2>/dev/null; then
        # Verify if Integrated Mode
        if ts_lit_integrated_mode "$root"; then
            echo "lit"
        fi
    fi
    return 0
}

detect_ln_implementation() {
    local guess=""
    if [[ "$PLATFORM" == "umbrel" ]]; then
        local lnd_containers
        lnd_containers=$(LN_IMPL=lnd get_lightning_docker_containers)
        local cln_containers
        cln_containers=$(LN_IMPL=cln get_lightning_docker_containers)
        if [[ -n "$lnd_containers" ]]; then
            guess="lnd"
        elif [[ -n "$cln_containers" ]]; then
            guess="cln"
        fi
    else
        guess=$(ts_guess_ln_impl_systemd)
    fi

    if [[ -n "$guess" ]]; then
        if [[ -n "$TS_OPT_IMPL" ]]; then
            # --impl answers the confirmation: yes if it names the detected implementation
            if [[ "$TS_OPT_IMPL" == "$guess" ]]; then
                use_guess="Y"
            else
                use_guess="n"
            fi
        else
            ts_ask use_guess "--impl <id>" "Detected Implementation: ${guess^^}. Correct? [Y/n]: "
        fi
        if [[ "$use_guess" =~ ^[Yy]$ ]] || [[ -z "$use_guess" ]]; then
            LN_IMPL="$guess"
            # Detect node user for non-Docker
            if [[ "$PLATFORM" != "umbrel" ]]; then
                local s_file=""
                [[ "$LN_IMPL" == "lnd" ]] && s_file="/etc/systemd/system/lnd.service"
                [[ "$LN_IMPL" == "cln" ]] && s_file="/etc/systemd/system/lightningd.service"
                if [[ "$LN_IMPL" == "lit" ]]; then
                    s_file="/etc/systemd/system/litd.service"
                    [[ ! -f "$s_file" ]] && s_file="/etc/systemd/system/lit.service"
                fi
                if [[ -f "$s_file" ]]; then
                    node_user=$(grep "^User=" "$s_file" | cut -d'=' -f2 | xargs)
                fi
                [[ -z "$node_user" ]] && [[ "$PLATFORM" == "raspiblitz" ]] && node_user="bitcoin"
                [[ -z "$node_user" ]] && node_user=$(whoami)
            fi
            return 0
        fi
    fi

    local range="1-2"
    if [[ "$PLATFORM" == "baremetal" ]]; then
        range="1-3"
    fi
    if [[ -n "$TS_OPT_IMPL" ]]; then
        # --impl answers the selection exactly like the matching menu entry
        if [[ -n "$guess" ]]; then
            print_warning "Using --impl ${TS_OPT_IMPL} (detected: ${guess})"
        fi
        case "$TS_OPT_IMPL" in
            lnd) choice="1" ;;
            cln) choice="2" ;;
            lit)
                if [[ "$PLATFORM" != "baremetal" ]]; then
                    ts_usage_error "--impl lit is only available on platform baremetal (platform: ${PLATFORM})"
                fi
                choice="3"
                ;;
        esac
    else
        ts_require_interaction "--impl <id>" "Select [$range]: "
        echo "Which Lightning implementation do you want to tunnel?" >&2
        echo "  1) LND" >&2
        echo "  2) CLN (Core Lightning)" >&2
        if [[ "$PLATFORM" == "baremetal" ]]; then
            echo "  3) LIT (integrated mode)" >&2
        fi
        echo "" >&2
        ts_ask choice "--impl <id>" "Select [$range]: "
    fi
    
    case $choice in
        1) 
            LN_IMPL="lnd"
            [[ -z "$node_user" ]] && node_user="bitcoin"
            ;;
        2) 
            LN_IMPL="cln"
            [[ -z "$node_user" ]] && node_user="bitcoin"
            ;;
        3) 
            if [[ "$PLATFORM" == "baremetal" ]]; then
                LN_IMPL="lit"
                
                # Verify Integrated Mode or warn
                if ! ts_lit_integrated_mode; then
                    print_warning "LIT Integrated mode not detected in config."
                    ts_confirm lit_confirm "Are you sure LIT is managing its own LND? [y/N]: "
                    if [[ ! "$lit_confirm" =~ ^[Yy]$ ]]; then
                        print_info "Please restart and select LND instead."
                        exit 0
                    fi
                fi
                local s_file="/etc/systemd/system/litd.service"
                [[ ! -f "$s_file" ]] && s_file="/etc/systemd/system/lit.service"
                node_user=$(grep "^User=" "$s_file" 2>/dev/null | cut -d'=' -f2 | xargs)
                [[ -z "$node_user" ]] && node_user="bitcoin"
            else
                print_error "LIT only available on bare metal"
                exit 1
            fi
            ;;
        *) print_error "Invalid selection"; exit 1 ;;
    esac
    return 0
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

# Sanitize WireGuard config by stripping any prior TunnelSats setup hooks,
# duplicate [Interface] sections, or stale routing directives.
# Preserves only the canonical base config (keys, endpoint, addresses, and comments).
sanitize_wireguard_config() {
    local input_file="$1"
    local output_file="$2"
    
    if [[ ! -f "$input_file" ]]; then
        print_error "Input config file does not exist: $input_file"
        return 1
    fi

    # Backup existing destination if present
    if [[ -f "$output_file" ]]; then
        local backup_file
        if ! backup_file=$(mktemp "${output_file}.bak.XXXXXX"); then
            print_error "Failed to create backup file for: $output_file"
            return 1
        fi
        if ! cp "$output_file" "$backup_file"; then
            print_error "Failed to backup existing config to: $backup_file"
            rm -f "$backup_file"
            return 1
        fi
        WG_CONFIG_BACKUP="$backup_file"
    fi

    # Extract base config:
    # 1. Stop processing at any TunnelSats marker (#Tunnelsats-Setup)
    # 2. Drop any secondary [Interface] blocks that appear after [Peer]
    # 3. Strip any PreUp, PostUp, PreDown, PostDown, FwMark, or Table directives (tolerant of indentation and casing)
    local clean_content
    clean_content=$(awk '
        BEGIN { in_peer=0; found_marker=0; in_secondary=0 }
        {
            raw = $0
            lower = tolower(raw)
            trimmed = lower
            sub(/^[[:space:]]+/, "", trimmed)
        }
        trimmed ~ /^#tunnelsats-setup/ { found_marker=1 }
        found_marker { next }
        trimmed ~ /^\[peer\]/ { in_peer=1; in_secondary=0 }
        in_peer && (trimmed ~ /^\[interface\]/) { in_secondary=1; next }
        in_secondary && (trimmed ~ /^\[/) { in_secondary=0 }
        in_secondary { next }
        trimmed ~ /^(preup|postup|predown|postdown|fwmark|table)[[:space:]]*=/ { next }
        { print raw }
    ' "$input_file")

    # Safety validation: PrivateKey and Endpoint must exist
    if ! echo "$clean_content" | grep -qiE "^[[:space:]]*PrivateKey[[:space:]]*="; then
        print_error "Config sanitization failed: PrivateKey missing from config"
        return 1
    fi
    if ! echo "$clean_content" | grep -qiE "^[[:space:]]*Endpoint[[:space:]]*="; then
        print_error "Config sanitization failed: Endpoint missing from config"
        return 1
    fi

    # Ensure PersistentKeepalive is set to maintain NAT state across firewalls/routers
    if ! echo "$clean_content" | grep -qiE "^[[:space:]]*PersistentKeepalive[[:space:]]*="; then
        print_info "PersistentKeepalive not found; ensuring PersistentKeepalive = 25 under [Peer]..."
        clean_content=$(printf '%s\nPersistentKeepalive = 25\n' "$clean_content")
    elif echo "$clean_content" | grep -qiE "^[[:space:]]*PersistentKeepalive[[:space:]]*=[[:space:]]*0\b"; then
        print_warning "PersistentKeepalive is set to 0. Updating to 25 to prevent NAT state drops..."
        clean_content=$(echo "$clean_content" | sed -E 's/^[[:space:]]*[Pp][Ee][Rr][Ss][Ii][Ss][Tt][Ee][Nn][Tt][Kk][Ee][Ee][Pp][Aa][Ll][Ii][Vv][Ee][[:space:]]*=[[:space:]]*0\b/PersistentKeepalive = 25/')
    fi

    # Trim trailing blank lines
    clean_content=$(echo "$clean_content" | sed -e :a -e '/^\n*$/{$d;N;};/\n$/ba')

    # Write sanitized content safely via temporary file
    local temp_out
    if ! temp_out=$(mktemp); then
        print_error "Failed to create temporary file for sanitized config"
        return 1
    fi
    if ! printf '%s\n' "$clean_content" > "$temp_out"; then
        print_error "Failed to write sanitized config to temporary file"
        rm -f "$temp_out"
        return 1
    fi
    if ! mv "$temp_out" "$output_file"; then
        print_error "Failed to move sanitized config to destination: $output_file"
        rm -f "$temp_out"
        return 1
    fi
    return 0
}

resolve_wg_target_path() {
    # Determine target filename - preserve dynamic names or use tunnelsatsv2.conf as fallback
    local source_filename
    source_filename=$(basename "$CONFIG_FILE")
    if [[ "$source_filename" == tunnelsats-*.conf ]]; then
        # New format with server name - preserve it
        echo "/etc/wireguard/$source_filename"
    else
        # Old format or generic - use tunnelsatsv2.conf for backward compatibility
        echo "/etc/wireguard/tunnelsatsv2.conf"
    fi
}

configure_wireguard() {
    print_info "Copying config to /etc/wireguard/..."
    
    local target_path
    target_path=$(resolve_wg_target_path)
    local target_filename
    target_filename=$(basename "$target_path")
    
    # Store target path for use in service setup (and for rollback of the config backup)
    WG_CONFIG_PATH="$target_path"
    WG_INTERFACE=$(basename "$target_path" .conf)
    
    # Sanitize and copy config, stripping any previous routing/hook residue
    print_info "Sanitizing WireGuard configuration..."
    if ! sanitize_wireguard_config "$CONFIG_FILE" "$target_path"; then
        print_error "Failed to sanitize WireGuard configuration"
        exit 1
    fi
    
    print_success "Config sanitized and copied to $target_filename"
    
    # Verify config has Endpoint
    if ! grep -q "Endpoint" "$target_path"; then
        print_error "Config missing Endpoint entry"
        exit 1
    fi

    # Check if IPv6 is disabled on the host (check procfs and sysctl)
    local ipv6_disabled=0
    if [ ! -f /proc/net/if_inet6 ]; then
        ipv6_disabled=1
    elif [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" == "1" ]; then
        ipv6_disabled=1
    fi

    if [ "$ipv6_disabled" -eq 1 ]; then
        print_warning "IPv6 appears to be disabled on this host."
        if grep -q "::/0" "$target_path"; then
            print_info "Stripping IPv6 (::/0) from AllowedIPs to prevent wg-quick failure..."
            # Strip ::/0, handles cases like "0.0.0.0/0, ::/0" or "::/0, 0.0.0.0/0"
            sed -i 's/,\s*::\/0//g' "$target_path"
            sed -i 's/::\/0,\s*//g' "$target_path"
            # If the line is ONLY AllowedIPs = ::/0, removing it might leave an invalid config.
            # We'll comment it out if it would otherwise be empty, though unlikely in Tunnelsats.
            sed -i 's/^AllowedIPs\s*=\s*::\/0/#AllowedIPs = ::\/0 (removed: ipv6 disabled)/g' "$target_path"
        fi
    fi
    
    # Fetch all local networks and exclude them from kill switch
    local localNetworks=$(ip route | grep -v default | awk '{print $1}' | grep -v "$WG_INTERFACE" | grep -v "10.9.0" | tr '\n' ',' | sed 's/,$//')
    if [ -z "$localNetworks" ]; then
        localNetworks="10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16"
    fi
    
    # Ownership-scoped table 51820 guard executed by the PostUp/PostDown hooks below
    local route_guard
    route_guard=$(route_guard_path)
    if ! write_route_guard_script; then
        print_error "Failed to write routing guard: ${route_guard}"
        exit 1
    fi

    # Apply network rules based on platform
    if [[ "$PLATFORM" == "umbrel" ]]; then
        print_info "Applying Docker network rules..."
        
        # Pre-resolve subnet to avoid command failure in PostUp
        # Pre-resolve subnet and bridge_id to avoid command failure in PostUp
        local dockersubnet=""
        local bridge_id=""
        local inspect_output

        if inspect_output=$(docker network inspect "docker-tunnelsats" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}} {{.Id}}' 2>/dev/null); then
            local bridge_id_full
            read -r dockersubnet bridge_id_full <<< "$inspect_output"
            bridge_id=${bridge_id_full:0:12}
        fi

        [[ -z "$dockersubnet" ]] && dockersubnet="10.9.9.0/25" # Fallback to standard

        # Dynamically determine the bridge interface for the tunnelsats network
        local bridge_name
        [[ -z "$bridge_id" ]] && bridge_name="br-6c3d330ad9f5" || bridge_name="br-$bridge_id"
        
        local vpn_port=$(ts_config_vpn_port "$target_path")
        [[ -z "$vpn_port" ]] && vpn_port=9735 # fallback (no valid port comment)

        local inputDocker="

#Tunnelsats-Setupv2-Docker

[Interface]
DNS = 8.8.8.8
Table = off

PostUp = $route_guard check %i $dockersubnet
PostUp = for n in 1 2 3 4 5 6 7 8 9 10; do ip rule del priority 21820 from all table main suppress_prefixlength 0 2>/dev/null || break; done
PostUp = for n in 1 2 3 4 5 6 7 8 9 10; do ip rule del priority 21821 from $dockersubnet table 51820 2>/dev/null || break; done
PostUp = $route_guard clean %i

PostUp = ip route add blackhole default metric 3 table 51820
PostUp = ip route add default dev %i metric 2 table 51820
PostUp = ip rule add from all table main suppress_prefixlength 0 priority 21820
PostUp = ip rule add from $dockersubnet table 51820 priority 21821
PostUp = ip route add 10.9.0.0/24 dev %i proto kernel scope link; ping -c1 10.9.0.1

PostUp = iptables -t nat -I PREROUTING -i %i -p tcp --dport $vpn_port -j DNAT --to-destination 10.9.9.9:9735
PostUp = iptables -I FORWARD -i %i -o $bridge_name -j ACCEPT
PostUp = iptables -I FORWARD -i $bridge_name -o %i -j ACCEPT

PostUp = sysctl -w net.ipv4.conf.all.rp_filter=0
PostUp = sysctl -w net.ipv6.conf.all.disable_ipv6=1
PostUp = sysctl -w net.ipv6.conf.default.disable_ipv6=1
PostUp = $route_guard release $dockersubnet

PostDown = iptables -t nat -D PREROUTING -i %i -p tcp --dport $vpn_port -j DNAT --to-destination 10.9.9.9:9735
PostDown = iptables -D FORWARD -i %i -o $bridge_name -j ACCEPT
PostDown = iptables -D FORWARD -i $bridge_name -o %i -j ACCEPT

PostDown = ip rule del priority 21820 from all table main suppress_prefixlength 0 2>/dev/null || true
PostDown = ip rule del priority 21821 from $dockersubnet table 51820 2>/dev/null || true
PostDown = $route_guard clean %i || true
PostDown = sysctl -w net.ipv4.conf.all.rp_filter=1
"
        echo -e "$inputDocker" >> "$target_path"
        
    else
        print_info "Applying non-Docker network rules..."
        
        local killswitchNonDocker=""
        # Node uid for the guard's blackhole ip rule fallback (emergency block without nft)
        local failclosed_host_uid
        failclosed_host_uid=$(resolve_failclosed_host_uid)
        # Enable cgroup-aware killswitch for all non-Docker systemd platforms
        if [[ "$PLATFORM" == "raspiblitz" || "$PLATFORM" == "baremetal" || "$PLATFORM" == "mynode" ]]; then
            # Cgroup-aware killswitch: Only drop if user is node_user AND packet is in the tunnelsats cgroup (1118498)
            # This allows other services (like bitcoind) sharing the same user to reach clearnet/tor normally
            killswitchNonDocker="PostUp = nft \"insert rule ip %i nat skuid ${node_user} meta cgroup 1118498 fib daddr type != local ip daddr != { $localNetworks } meta oifname != %i counter drop\"\n"
        fi
        
        local inputNonDocker="

#Tunnelsats-Setupv2-Non-Docker

[Interface]
FwMark = 0x2000000
Table = off


PostUp = $route_guard check %i 10.9.9.0/25 $failclosed_host_uid
PostUp = for n in 1 2 3 4 5 6 7 8 9 10; do ip rule del priority 21820 from all table main suppress_prefixlength 0 2>/dev/null || break; done
PostUp = for n in 1 2 3 4 5 6 7 8 9 10; do ip rule del priority 21821 from all fwmark 0x1000000/0xff000000 table 51820 2>/dev/null || break; done
PostUp = $route_guard clean %i

PostUp = ip route add default dev %i table 51820;
PostUp = ip rule add from all table main suppress_prefixlength 0 priority 21820
PostUp = ip rule add from all fwmark 0x1000000/0xff000000 table 51820 priority 21821
PostUp = ip route add  10.9.0.0/24 dev %i  proto kernel scope link; ping -c1 10.9.0.1
PostUp = sysctl -w net.ipv4.conf.all.rp_filter=0
PostUp = sysctl -w net.ipv6.conf.all.disable_ipv6=1
PostUp = sysctl -w net.ipv6.conf.default.disable_ipv6=1

PostUp = nft add table ip %i
PostUp = nft add chain ip %i prerouting '{ type filter hook prerouting priority mangle -1; policy accept; }'; nft add rule ip %i prerouting meta mark set ct mark
PostUp = nft add chain ip %i mangle '{ type route hook output priority mangle -1; policy accept; }'; nft add rule ip %i mangle tcp sport != { 8080, 10009 } meta mark and 0xff000000 != 0x2000000 meta cgroup 1118498 meta mark set 0x1000000
PostUp = nft \"add chain ip %i nat { type nat hook postrouting priority srcnat -1; policy accept; } ; insert rule ip %i nat fib daddr type != local ip daddr != { $localNetworks } oifname != %i ct mark and 0xff000000 == 0x1000000 drop ; add rule ip %i nat oifname %i ct mark and 0xff000000 == 0x1000000 masquerade\"
${killswitchNonDocker}PostUp = nft \"add chain ip %i postroutingmangle { type filter hook postrouting priority mangle -1; policy accept; } ; add rule ip %i postroutingmangle meta mark and 0xff000000 == 0x1000000 ct mark set meta mark and 0x00ffffff xor 0x1000000\"
PostUp = nft \"add chain ip %i input { type filter hook input priority filter -1; policy accept; } ; add rule ip %i input iifname %i ct state established,related counter accept ; add rule ip %i input iifname %i tcp dport != 9735 counter drop ; add rule ip %i input iifname %i udp dport != 9735 counter drop\"
PostUp = $route_guard release 10.9.9.0/25 $failclosed_host_uid


PostDown = nft delete table ip %i
PostDown = ip rule del priority 21820 from all table main suppress_prefixlength 0 2>/dev/null || true
PostDown = ip rule del priority 21821 from all fwmark 0x1000000/0xff000000 table 51820 2>/dev/null || true
PostDown = $route_guard clean %i || true
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
    systemctl enable tunnelsats-create-cgroup.service &>/dev/null
   systemctl start tunnelsats-create-cgroup.service
    
    print_success "Cgroups configured"
}

# Deletes a TunnelSats-owned policy rule only while `ip rule show` contains a line matching
# the full selector regex ($1). Remaining args are passed to `ip rule del`. Bounded to avoid spinning.
delete_owned_ip_rule() {
    local pattern="$1"
    shift
    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        ip rule show 2>/dev/null | grep -Eq "$pattern" || return 0
        if ! ip rule del "$@" 2>/dev/null; then
            print_warning "Failed to delete TunnelSats policy rule: ip rule del $*"
            return 1
        fi
    done
    return 0
}

check_and_cleanup_routing_table() {
    local iface="${1:-$WG_INTERFACE}"

    # 1. Detect conflicting WireGuard interfaces owning table 51820
    if command -v wg >/dev/null 2>&1; then
        local other_wg
        for other_wg in $(wg show interfaces 2>/dev/null); do
            if [[ -n "$iface" ]] && [[ "$other_wg" != "$iface" ]]; then
                if ip route show table 51820 2>/dev/null | grep -q "dev ${other_wg}\b"; then
                    print_error "Routing table 51820 contains routes owned by another active WireGuard interface (${other_wg}). Conflicting ownership detected. Aborting."
                    exit 1
                fi
            fi
        done
    fi

    # 2. Check for foreign routes in table 51820 (anything not owned by TunnelSats).
    #    An unreadable table is unverified state and aborts (fail-closed).
    local foreign_routes=""
    if ! foreign_routes=$(ts_table51820_foreign_routes "$iface"); then
        print_error "Routing table 51820 could not be verified. Aborting to prevent inconsistent routing."
        exit 1
    fi
    if [[ -n "$foreign_routes" ]]; then
        print_error "Routing table 51820 contains routes owned by another interface/service:"
        echo "$foreign_routes"
        print_error "Conflicting routing ownership detected. Aborting cleanup to protect other networking services."
        exit 1
    fi

    # 3./4. Remove TunnelSats-owned policy rules and routes only
    if ! cleanup_owned_routing_state "$iface"; then
        print_error "Failed to remove stale TunnelSats policy rules. Aborting to prevent inconsistent routing."
        exit 1
    fi
}

# Removes TunnelSats-owned policy rules and TunnelSats-owned routes in table 51820.
# Never flushes the table and never touches foreign rules/routes, so it is also safe for uninstall
# when another service uses table 51820. Returns 1 if an owned policy rule could not be removed.
cleanup_owned_routing_state() {
    local iface="${1:-$WG_INTERFACE}"

    # Rules are matched by priority AND full selector/table,
    # so foreign rules that happen to reuse priority 21820/21821 are never touched.
    local dsubnet="${dockersubnet:-$(resolve_failclosed_subnet)}"
    local dsubnet_re
    dsubnet_re=$(printf '%s' "$dsubnet" | sed 's/\./\\./g')
    local rule_cleanup_failed=0
    delete_owned_ip_rule "^21820:[[:space:]]+from all lookup main suppress_prefixlength 0([[:space:]]|$)" \
        priority 21820 from all table main suppress_prefixlength 0 || rule_cleanup_failed=1
    delete_owned_ip_rule "^21821:[[:space:]]+from ${dsubnet_re} lookup 51820([[:space:]]|$)" \
        priority 21821 from "$dsubnet" table 51820 || rule_cleanup_failed=1
    delete_owned_ip_rule "^21821:[[:space:]]+from all fwmark 0x1000000/0xff000000 lookup 51820([[:space:]]|$)" \
        priority 21821 from all fwmark 0x1000000/0xff000000 table 51820 || rule_cleanup_failed=1

    # Also clean up legacy TunnelSats-specific selectors (any priority) targeting table 51820
    delete_owned_ip_rule "from ${dsubnet_re} lookup 51820([[:space:]]|$)" \
        from "$dsubnet" table 51820 || rule_cleanup_failed=1
    delete_owned_ip_rule "from all fwmark 0x1000000/0xff000000 lookup 51820([[:space:]]|$)" \
        from all fwmark 0x1000000/0xff000000 table 51820 || rule_cleanup_failed=1

    # Routes: only the ones TunnelSats installs (never `ip route flush table 51820`)
    ts_table51820_remove_owned "$iface"

    [[ "$rule_cleanup_failed" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# OWNERSHIP-SCOPED ROUTING TABLE 51820 PRIMITIVES
# These functions are embedded verbatim (declare -f) into the generated wg-quick route guard
# (write_route_guard_script), so the installer and the runtime PostUp/PostDown hooks share one
# implementation. Keep them self-contained: no globals, no print_* helpers.
#
# TunnelSats-owned routes in table 51820 are exactly:
#   - the Docker kill-switch route "blackhole default metric 3"
#   - routes via the TunnelSats WireGuard interface ("... dev <iface> ...")
# Everything else in table 51820 belongs to another service and must never be removed.
# ---------------------------------------------------------------------------

# Prints the IPv4 routes of table 51820. A table that does not exist yet is reported as empty.
# Returns 1 if the table cannot be read; callers must treat that as unverified and fail closed.
ts_table51820_routes() {
    local out rc
    out=$(ip route show table 51820 2>&1) && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        case "$out" in
            *"FIB table does not exist"*) return 0 ;;
        esac
        echo "TunnelSats: unable to read routing table 51820: ${out}" >&2
        return 1
    fi
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
    fi
    return 0
}

# Reads routes of table 51820 on stdin and prints those TunnelSats does not own ($1 = the
# TunnelSats interface; with an empty $1 only the kill-switch blackhole counts as owned).
# Shared by the route guard (embedded verbatim) and detect, so both judge ownership identically.
ts_table51820_filter_foreign() {
    awk -v ifc="$1" '
        NF == 0 { next }
        NF == 4 && $1 == "blackhole" && $2 == "default" && $3 == "metric" && $4 == "3" { next }
        {
            for (i = 1; i < NF; i++) {
                if ($i == "dev" && ifc != "" && $(i + 1) == ifc) { next }
            }
            print
        }'
}

# Prints the routes in table 51820 that TunnelSats does not own ($1 = TunnelSats interface).
# Returns 1 if the table cannot be read.
ts_table51820_foreign_routes() {
    local iface="$1" routes
    routes=$(ts_table51820_routes) || return 1
    [ -n "$routes" ] || return 0
    printf '%s\n' "$routes" | ts_table51820_filter_foreign "$iface"
}

# Removes only the routes TunnelSats installs into table 51820. Never flushes the table.
# Bounded loops; a missing route or device simply ends the loop.
ts_table51820_remove_owned() {
    local iface="$1" n
    for n in 1 2 3 4 5 6 7 8 9 10; do
        ip route del blackhole default metric 3 table 51820 2>/dev/null || break
    done
    if [ -n "$iface" ]; then
        for n in 1 2 3 4 5 6 7 8 9 10; do
            ip route del default dev "$iface" table 51820 2>/dev/null || break
        done
    fi
    return 0
}

# Emergency fail-closed block for Lightning traffic while no verified tunnel exists (#205).
# Primary: nft drop table "ip tunnelsats_failclosed" for host traffic in the TunnelSats cgroup and
# forwarded traffic from the Docker tunnel subnet. Fallback when nft is missing or rejects a rule
# (e.g. nf_tables failed to load at boot): blackhole policy rules that need no netfilter at all,
# evaluated before the main table, so no Lightning traffic can take the main-table default route:
#   21818: from <Docker tunnel subnet> blackhole    (forwarded container traffic)
#   21819: uidrange <node uid> blackhole           (host Lightning daemon, non-Docker only)
# Local destinations keep working through the local table (priority 0), like the nft drop's
# "fib daddr type != local". Every state is verified with a real read (nft list / ip rule show)
# before it is reported as armed.

# $1 = Docker tunnel subnet. Succeeds only if a real read of the ruleset shows both drop rules.
ts_failclosed_nft_verified() {
    local subnet="$1" out subnet_re
    command -v nft >/dev/null 2>&1 || return 1
    out=$(nft list table ip tunnelsats_failclosed 2>/dev/null) || return 1
    subnet_re=$(printf '%s' "$subnet" | sed 's/[.]/\\./g')
    printf '%s\n' "$out" | grep -Eq 'meta cgroup 1118498 .*drop' || return 1
    printf '%s\n' "$out" | grep -Eq "ip saddr ${subnet_re} .*drop" || return 1
    return 0
}

# Arms the nft drop ($1 = Docker tunnel subnet). Returns 1 unless the drop is verified in place.
ts_arm_failclosed_nft() {
    local subnet="$1" failed=0
    if ! command -v nft >/dev/null 2>&1; then
        echo "TunnelSats: nft not available; nft emergency drop could NOT be armed" >&2
        return 1
    fi
    # Already armed and verified (e.g. a repeated refusal): do not stack duplicate rules.
    ts_failclosed_nft_verified "$subnet" && return 0
    nft add table ip tunnelsats_failclosed || failed=1
    nft "add chain ip tunnelsats_failclosed output { type filter hook output priority -100; policy accept; }" || failed=1
    nft "add rule ip tunnelsats_failclosed output meta cgroup 1118498 fib daddr type != local counter drop" || failed=1
    nft "add chain ip tunnelsats_failclosed forward { type filter hook forward priority -100; policy accept; }" || failed=1
    nft "add rule ip tunnelsats_failclosed forward ip saddr ${subnet} fib daddr type != local counter drop" || failed=1
    if [ "$failed" -ne 0 ]; then
        echo "TunnelSats: nft rejected an emergency drop rule; nft emergency drop could NOT be armed" >&2
        return 1
    fi
    if ! ts_failclosed_nft_verified "$subnet"; then
        echo "TunnelSats: nft accepted the emergency drop but it is not in the ruleset; nft emergency drop could NOT be verified" >&2
        return 1
    fi
    return 0
}

# Path to the state file recording emergency blackhole selectors TunnelSats has armed, so release
# and uninstall can still remove a previously armed rule if the node account or subnet later changes.
ts_failclosed_state_file() {
    if [ -n "${WG_DIR:-}" ]; then
        echo "${WG_DIR}/.tunnelsats-failclosed-rules"
    elif [ "${0##*/}" = "tunnelsats-route-guard.sh" ] && [ "${0%/*}" != "$0" ]; then
        echo "${0%/*}/.tunnelsats-failclosed-rules"
    else
        echo "/etc/wireguard/.tunnelsats-failclosed-rules"
    fi
}

# Records a selector ("from <subnet>" or "uidrange <uid>-<uid>") that TunnelSats itself added
# to the kernel policy rules. Returns 1 if the ownership state file cannot be updated.
ts_record_failclosed_rule() {
    local entry="$1" state_file
    state_file=$(ts_failclosed_state_file)
    grep -qxF "$entry" "$state_file" 2>/dev/null && return 0
    printf '%s\n' "$entry" >> "$state_file" 2>/dev/null
}

# $1 = Docker tunnel subnet, $2 = host uid ("" when there is no host daemon to cover).
# Succeeds only if a real read of the IPv4 policy rules shows every required blackhole rule.
ts_failclosed_rules_verified() {
    local subnet="$1" uid="$2" rules subnet_re
    rules=$(ip -4 rule show 2>/dev/null) || return 1
    subnet_re=$(printf '%s' "$subnet" | sed 's/[.]/\\./g')
    printf '%s\n' "$rules" | grep -Eq "^21818:[[:space:]]+from ${subnet_re}[[:space:]]+blackhole[[:space:]]*$" || return 1
    if [ -n "$uid" ]; then
        printf '%s\n' "$rules" | grep -Eq "^21819:[[:space:]]+from all uidrange ${uid}-${uid}[[:space:]]+blackhole[[:space:]]*$" || return 1
    fi
    return 0
}

# Arms the routing-policy fallback. $1 = Docker tunnel subnet, $2 = host uid:
#   ""         Docker platform, only the subnet needs to be blocked;
#   <uid>      non-Docker platform, the node user's uid is blocked too (never root);
#   otherwise  non-Docker platform whose node uid is unknown: the host daemon cannot be
#              covered, so this reports failure even though the subnet rule is armed.
# Only rules that were absent before and added by TunnelSats are recorded in ts_failclosed_state_file,
# so a pre-existing blackhole rule owned by another service is never claimed or deleted on release.
ts_arm_failclosed_rules() {
    local subnet="$1" host_uid="$2" uid="" rules subnet_re
    case "$host_uid" in
        "") ;;
        0|*[!0-9]*)
            echo "TunnelSats: node user uid unknown or root (${host_uid}); the routing-policy fallback cannot cover the host Lightning daemon" >&2
            uid="unusable" ;;
        *) uid="$host_uid" ;;
    esac
    subnet_re=$(printf '%s' "$subnet" | sed 's/[.]/\\./g')
    rules=$(ip -4 rule show 2>/dev/null) || return 1
    if ! printf '%s\n' "$rules" | grep -Eq "^21818:[[:space:]]+from ${subnet_re}[[:space:]]+blackhole[[:space:]]*$"; then
        if ip -4 rule add from "$subnet" blackhole priority 21818; then
            if ! ts_record_failclosed_rule "from ${subnet}"; then
                ip -4 rule del priority 21818 from "$subnet" blackhole 2>/dev/null || true
                return 1
            fi
        fi
    fi
    if [ -n "$uid" ] && [ "$uid" != "unusable" ] && \
        ! printf '%s\n' "$rules" | grep -Eq "^21819:[[:space:]]+from all uidrange ${uid}-${uid}[[:space:]]+blackhole[[:space:]]*$"; then
        if ip -4 rule add uidrange "${uid}-${uid}" blackhole priority 21819; then
            if ! ts_record_failclosed_rule "uidrange ${uid}-${uid}"; then
                ip -4 rule del priority 21819 uidrange "${uid}-${uid}" blackhole 2>/dev/null || true
                return 1
            fi
        fi
    fi
    [ "$uid" = "unusable" ] && return 1
    ts_failclosed_rules_verified "$subnet" "$uid"
}

# Arms the emergency block ($1 = Docker tunnel subnet, $2 = host uid, see ts_arm_failclosed_rules).
# Returns 1 unless nft or the routing-policy fallback is verified in place (callers must report that).
ts_arm_failclosed() {
    local subnet="${1:-10.9.9.0/25}" host_uid="${2:-}"
    if ts_arm_failclosed_nft "$subnet"; then
        return 0
    fi
    if ts_arm_failclosed_rules "$subnet" "$host_uid"; then
        echo "TunnelSats: routing-policy fallback armed and verified (blackhole ip rules 21818/21819): Lightning traffic cannot use the main table" >&2
        return 0
    fi
    echo "TunnelSats: routing-policy fallback could NOT be armed either" >&2
    return 1
}

# Removes only the emergency blackhole rules that TunnelSats itself added and recorded in
# ts_failclosed_state_file. Pre-existing or foreign rules on priorities 21818/21819 are never
# touched, while rules TunnelSats armed are removed even if the tunnel subnet or node UID later
# changed or was removed. Returns 1 if policy rules cannot be read or an owned rule remains.
ts_release_failclosed_rules() {
    local state_file entry entry_re clauses="" pattern n rules line prio sel
    if ! rules=$(ip -4 rule show 2>/dev/null); then
        echo "TunnelSats: ERROR: unable to read IPv4 policy rules while releasing emergency blackhole rules" >&2
        return 1
    fi
    state_file=$(ts_failclosed_state_file)
    [ -f "$state_file" ] || return 0
    while IFS= read -r entry || [ -n "$entry" ]; do
        case "$entry" in
            "from "[0-9]*.[0-9]*.[0-9]*.[0-9]*/*)
                entry_re=$(printf '%s' "${entry#from }" | sed 's/[.]/\\./g')
                clauses="${clauses:+${clauses}|}21818:[[:space:]]+from ${entry_re}"
                ;;
            "uidrange "[1-9][0-9]*-[1-9][0-9]*)
                clauses="${clauses:+${clauses}|}21819:[[:space:]]+from all ${entry}"
                ;;
        esac
    done < "$state_file"
    if [ -z "$clauses" ]; then
        rm -f "$state_file" 2>/dev/null || return 1
        return 0
    fi
    pattern="^(${clauses})[[:space:]]+blackhole[[:space:]]*$"
    for n in 1 2 3 4 5 6 7 8 9 10; do
        if ! rules=$(ip -4 rule show 2>/dev/null); then
            echo "TunnelSats: ERROR: unable to read IPv4 policy rules while releasing emergency blackhole rules" >&2
            return 1
        fi
        line=$(printf '%s\n' "$rules" | grep -E "$pattern" | head -n 1 || true)
        [ -n "$line" ] || break
        prio=${line%%:*}
        sel=$(printf '%s\n' "$line" | sed -E 's/^[0-9]+:[[:space:]]+//; s/[[:space:]]+blackhole[[:space:]]*$//; s/^from all uidrange /uidrange /')
        # $sel is two words on purpose ("from <subnet>" / "uidrange <a>-<b>").
        # shellcheck disable=SC2086
        ip -4 rule del priority "$prio" $sel blackhole 2>/dev/null || break
    done
    if ! rules=$(ip -4 rule show 2>/dev/null); then
        echo "TunnelSats: ERROR: unable to verify removal of emergency blackhole rules" >&2
        return 1
    fi
    if printf '%s\n' "$rules" | grep -Eq "$pattern"; then
        echo "TunnelSats: ERROR: could not remove the emergency blackhole rule(s) at priority 21818/21819; Lightning traffic stays blocked until they are removed" >&2
        return 1
    fi
    if ! rm -f "$state_file" 2>/dev/null; then
        echo "TunnelSats: ERROR: unable to remove emergency blackhole state file ${state_file}" >&2
        return 1
    fi
    return 0
}

# Removes the emergency block (nft table and fallback rules) once a tunnel is verified active.
# $1 = Docker tunnel subnet (default 10.9.9.0/25), $2 = optional host uid (retained for CLI compatibility).
# Returns 1 if the emergency block could not be verified as removed.
ts_release_failclosed() {
    local subnet="${1:-10.9.9.0/25}"
    if command -v nft >/dev/null 2>&1; then
        nft delete table ip tunnelsats_failclosed 2>/dev/null || true
        if ts_failclosed_nft_verified "$subnet"; then
            echo "TunnelSats: ERROR: could not remove emergency nft table ip tunnelsats_failclosed" >&2
            return 1
        fi
    fi
    ts_release_failclosed_rules
}

# Docker tunnel subnet for ts_arm_failclosed / ts_release_failclosed: inspects docker-tunnelsats
# on Docker platforms and falls back to 10.9.9.0/25.
resolve_failclosed_subnet() {
    local subnet=""
    if [[ "$PLATFORM" == "umbrel" ]] && command -v docker >/dev/null 2>&1; then
        subnet=$(docker network inspect "docker-tunnelsats" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | awk '{print $1}')
    fi
    echo "${subnet:-10.9.9.0/25}"
}

# Host uid argument for ts_arm_failclosed: "" on Docker platforms (no host daemon to cover),
# the node user's uid on systemd platforms, or "unresolved" if it is unknown or root (the
# fallback then reports that it cannot cover the host daemon instead of blocking root).
resolve_failclosed_host_uid() {
    if [[ "$PLATFORM" == "umbrel" ]]; then
        echo ""
        return 0
    fi
    local uid=""
    [[ -n "$node_user" ]] && uid=$(id -u "$node_user" 2>/dev/null || true)
    if [[ "$uid" =~ ^[0-9]+$ ]] && [[ "$uid" != "0" ]]; then
        echo "$uid"
    else
        echo "unresolved"
    fi
}

route_guard_path() {
    echo "${WG_DIR:-/etc/wireguard}/tunnelsats-route-guard.sh"
}

# Generates the route guard executed by the wg-quick PostUp/PostDown hooks:
#   check IFACE [SUBNET] [HOST_UID]
#                         first PostUp hook: if table 51820 holds foreign routes or cannot be
#                         read, refuse to start and arm the emergency fail-closed block (nft, or
#                         the blackhole ip rule fallback; HOST_UID as in ts_arm_failclosed_rules).
#                         exit 1 = refused, block armed and verified;
#                         exit 3 = refused, neither nft nor the fallback could be armed
#   clean IFACE           remove only TunnelSats-owned routes from table 51820
#   release [SUBNET] [HOST_UID]
#                         remove the emergency fail-closed block (last PostUp hook)
# The guard is replaced atomically (temp file + rename): a failed write leaves the previous
# guard in place, so a rolled-back config that calls it keeps working.
write_route_guard_script() {
    local guard tmp
    guard=$(route_guard_path)
    mkdir -p "$(dirname "$guard")" 2>/dev/null || true
    tmp=$(mktemp "${guard}.XXXXXX") || return 1
    if ! {
        echo '#!/bin/bash'
        echo '# Generated by tunnelsats.sh - ownership-scoped management of routing table 51820.'
        echo '# Never flushes table 51820; foreign routes are preserved and cause a fail-closed refusal.'
        declare -f ts_table51820_routes ts_table51820_filter_foreign ts_table51820_foreign_routes ts_table51820_remove_owned \
            ts_failclosed_state_file ts_record_failclosed_rule ts_failclosed_nft_verified \
            ts_arm_failclosed_nft ts_failclosed_rules_verified ts_arm_failclosed_rules \
            ts_arm_failclosed ts_release_failclosed_rules ts_release_failclosed
        cat <<'GUARD'
# Refuses the tunnel start ($1 = reason, $2 = optional details). Never returns.
refuse_start() {
    if ts_arm_failclosed "$subnet" "$host_uid"; then
        echo "TunnelSats: $1; refusing to start ${iface}. Emergency fail-closed block armed and verified: Lightning traffic is blocked." >&2
        [ -n "${2:-}" ] && printf '%s\n' "$2" >&2
        exit 1
    fi
    echo "TunnelSats: $1; refusing to start ${iface}. WARNING: emergency fail-closed block could NOT be armed (nft and the blackhole ip rule fallback both failed): Lightning traffic is NOT blocked. Stop the Lightning daemon until the tunnel is up." >&2
    [ -n "${2:-}" ] && printf '%s\n' "$2" >&2
    exit 3
}

action="${1:-}"
case "$action" in
    check)
        iface="${2:?interface required}"
        subnet="${3:-}"
        host_uid="${4:-}"
        if ! foreign=$(ts_table51820_foreign_routes "$iface"); then
            refuse_start "routing table 51820 could not be verified"
        fi
        if [ -n "$foreign" ]; then
            refuse_start "routing table 51820 contains routes not owned by ${iface}" "$foreign"
        fi
        ;;
    clean)
        ts_table51820_remove_owned "${2:?interface required}"
        ;;
    release)
        ts_release_failclosed "${2:-}" "${3:-}" || exit 1
        ;;
    *)
        echo "usage: $0 check IFACE [SUBNET] [HOST_UID] | clean IFACE | release [SUBNET] [HOST_UID]" >&2
        exit 2
        ;;
esac
exit 0
GUARD
    } > "$tmp" || ! chmod 755 "$tmp" || ! mv -f "$tmp" "$guard"; then
        rm -f "$tmp"
        return 1
    fi
    return 0
}

stop_lightning_daemon_for_safe_restart() {
    # Identify and stop running Lightning daemon BEFORE any route/network mutation,
    # independently of WireGuard unit state (fail-closed leak prevention).
    if [[ "$PLATFORM" == "umbrel" ]]; then
        local running_cids
        running_cids=$(get_lightning_docker_containers)
        if [[ "$(printf '%s\n' $running_cids | grep -c . || true)" -gt 1 ]]; then
            print_error "Multiple running ${LN_IMPL} daemon containers found ($(echo $running_cids)). Only one can own the tunnel IP ${TUNNEL_CONTAINER_IP}. Aborting before any changes."
            exit 1
        fi
        if [[ -n "$running_cids" ]]; then
            print_info "Stopping ${LN_IMPL} daemon container for leak-proof tunnel restart..."
            if ! docker stop $running_cids >/dev/null 2>&1; then
                print_error "Failed to safely stop ${LN_IMPL} container. Aborting before network/route changes to prevent traffic leaks."
                exit 1
            fi
            stopped_docker_containers="$running_cids"
            print_success "${LN_IMPL} daemon container stopped (Leak-proof mode)"
        fi
    else
        local service_name="${LN_IMPL}"
        [[ "$LN_IMPL" == "cln" ]] && service_name="lightningd"
        if [[ "$LN_IMPL" == "lit" ]]; then
            service_name="litd"
            systemctl list-units --type=service 2>/dev/null | grep -q "lit.service" && service_name="lit"
        fi

        local target_service=""
        if [[ -n "$service_name" ]] && systemctl is-active --quiet "${service_name}.service" 2>/dev/null; then
            target_service="${service_name}.service"
        elif systemctl is-active --quiet lnd.service 2>/dev/null; then
            target_service="lnd.service"
        elif systemctl is-active --quiet lightningd.service 2>/dev/null; then
            target_service="lightningd.service"
        fi

        if [[ -n "$target_service" ]]; then
            print_info "Stopping ${target_service} for leak-proof tunnel restart..."
            if systemctl stop "${target_service}"; then
                restarted_systemd_service="${target_service}"
                print_success "${target_service} stopped (Leak-proof mode)"
            else
                print_error "Failed to stop ${target_service} safely. Aborting before network/route changes to prevent traffic leaks."
                exit 1
            fi
        fi
    fi

    # If WireGuard interface is currently active, stop it before updating configuration
    if [[ -n "$WG_INTERFACE" ]] && systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
        print_info "Stopping active WireGuard service (${WG_INTERFACE}) before updating configuration..."
        if ! systemctl stop "wg-quick@${WG_INTERFACE}"; then
            print_error "Failed to safely stop active WireGuard service (${WG_INTERFACE}). Aborting to prevent routing conflicts."
            exit 1
        fi
        stopped_wireguard_interface="$WG_INTERFACE"
        print_success "WireGuard service stopped"
    fi
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
    
    # Clean routing tables from prior failed starts, strictly scoped to TunnelSats ownership
    check_and_cleanup_routing_table "$WG_INTERFACE"
    
    # Attach exactly one resolved lightning daemon to docker-tunnelsats with the static tunnel IP.
    # Only one container can own 10.9.9.9; stale stopped leftovers must not compete for it.
    local target_cid
    if ! target_cid=$(select_tunnel_target_container); then
        exit 1
    fi
    if [[ -z "$target_cid" ]]; then
        print_error "No ${LN_IMPL} daemon container found to attach to docker-tunnelsats"
        exit 1
    fi
    if ! attach_container_to_tunnel_network "$target_cid"; then
        exit 1
    fi
    tunnel_target_container="$target_cid"

    # Create Docker network monitor script with shared container resolver regex
    local container_regex
    if [[ "$LN_IMPL" == "cln" ]]; then
        container_regex="$CLN_CONTAINER_REGEX"
    else
        container_regex="$LND_CONTAINER_REGEX"
    fi

    local wg_dir="${WG_DIR:-/etc/wireguard}"
    local systemd_dir="${SYSTEMD_DIR:-/etc/systemd/system}"
    mkdir -p "$wg_dir" "$systemd_dir" 2>/dev/null || true

    local monitor_script=""
    IFS= read -r -d '' monitor_script <<'EOF' || true
#!/bin/sh
# Generated by tunnelsats.sh - keeps exactly one Lightning daemon attached to docker-tunnelsats at __TUNNEL_IP__
NET="docker-tunnelsats"
TUNNEL_IP="__TUNNEL_IP__"
if [ "$(docker network ls 2> /dev/null | grep -c "$NET")" -eq 0 ]; then
  if ! docker network create "$NET" --subnet "10.9.9.0/25" -o "com.docker.network.driver.mtu"="1420" > /dev/null; then
    exit 1
  fi
fi

list_ln() {
  docker ps $1 --format "{{.ID}} {{.Names}}" 2>/dev/null | grep -Ei '__CONTAINER_REGEX__' | grep -Eiv '__EXCLUDE_REGEX__' | awk '{print $1}'
}
tunnel_state() {
  docker inspect -f '__INSPECT_FMT__' "$1" 2>/dev/null
}

running=$(list_ln "")
if [ "$(printf '%s\n' $running | grep -c .)" -gt 1 ]; then
  echo "Multiple running Lightning daemon containers; refusing to share $TUNNEL_IP" >&2
  exit 1
fi
target="$running"
if [ -z "$target" ]; then
  # No daemon running (e.g. installer restart window): never move the tunnel IP away from its current owner
  for c in $(list_ln "-a"); do
    case " $(tunnel_state "$c") " in *" $TUNNEL_IP "*) exit 0 ;; esac
  done
  target=$(list_ln "-a" | head -n 1)
fi
[ -z "$target" ] && exit 0

state=$(tunnel_state "$target")
case " $state " in *" $TUNNEL_IP "*) exit 0 ;; esac
if [ -n "$state" ]; then
  docker network disconnect -f "$NET" "$target" > /dev/null 2>&1 || exit 1
fi

for other in $(list_ln "-a"); do
  [ "$other" = "$target" ] && continue
  case " $(tunnel_state "$other") " in
    *" $TUNNEL_IP "*)
      [ "$(docker inspect -f '{{.State.Running}}' "$other" 2>/dev/null)" = "true" ] && exit 1
      docker network disconnect -f "$NET" "$other" > /dev/null 2>&1 || exit 1
      ;;
  esac
done

docker network connect --ip "$TUNNEL_IP" "$NET" "$target" > /dev/null 2>&1 || exit 1
exit 0
EOF
    monitor_script="${monitor_script//__CONTAINER_REGEX__/"$container_regex"}"
    monitor_script="${monitor_script//__EXCLUDE_REGEX__/"$LN_CONTAINER_EXCLUDE_REGEX"}"
    monitor_script="${monitor_script//__INSPECT_FMT__/"$TUNNEL_NET_INSPECT_FMT"}"
    monitor_script="${monitor_script//__TUNNEL_IP__/"$TUNNEL_CONTAINER_IP"}"
    printf '%s' "$monitor_script" > "$wg_dir/tunnelsats-docker-network.sh"
    
    chmod +x "$wg_dir/tunnelsats-docker-network.sh"
    bash "$wg_dir/tunnelsats-docker-network.sh" &>/dev/null
    
    # Create systemd service and timer
    cat > "$systemd_dir/tunnelsats-docker-network.service" <<'EOF'
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
    
    cat > "$systemd_dir/tunnelsats-docker-network.timer" <<'EOF'
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
            service_file="/etc/systemd/system/litd.service"
            [[ ! -f "$service_file" ]] && service_file="/etc/systemd/system/lit.service"
            service_dir="${service_file}.d"
            ;;
    esac

    # 1. Backup original service file before any modifications
    if [[ -f "$service_file" ]] && [[ ! -f "${service_file}.bak" ]]; then
        cp "$service_file" "${service_file}.bak"
        print_success "Created backup of original service file: ${service_file}.bak"
    fi

    # 2. Deactivate RaspiBlitz config checks if present
    if [[ "$PLATFORM" == "raspiblitz" ]]; then
        if [[ "$LN_IMPL" == "lnd" ]]; then
            # Comment out the ExecStartPre check in the service file
            [[ -f "$service_file" ]] && sed -i '/lnd\.check\.sh/ s/^ExecStartPre=/#ExecStartPre=/' "$service_file" 2>/dev/null || true
            # Also disable any separate health service if present
            systemctl stop lnd-health.service &>/dev/null || true
            systemctl disable lnd-health.service &>/dev/null || true
            print_info "RaspiBlitz lnd.check deactivated in service file"
        elif [[ "$LN_IMPL" == "cln" ]]; then
            [[ -f "$service_file" ]] && sed -i '/cl\.check\.sh/ s/^ExecStartPre=/#ExecStartPre=/' "$service_file" 2>/dev/null || true
            systemctl stop cl-health.service &>/dev/null || true
            systemctl disable cl-health.service &>/dev/null || true
            print_info "RaspiBlitz cl.check deactivated in service file"
        fi
    fi
    
    # For non-Docker setups, modify systemd service to use cgexec
    if [[ "$PLATFORM" != "umbrel" ]]; then
        setup_cgroups

        # 1. Create Drop-in Dependency
        if [[ -n "$service_dir" ]]; then
            if [[ ! -d "$service_dir" ]]; then mkdir -p "$service_dir"; fi
            
            cat > "${service_dir}/tunnelsats-cgroup.conf" << EOF
#Don't edit this file its generated by tunnelsats scripts
[Unit]
Description=${LN_IMPL} service - powered by tunnelsats
Wants=tunnelsats-create-cgroup.service
After=tunnelsats-create-cgroup.service
Wants=wg-quick@${WG_INTERFACE}.service
After=wg-quick@${WG_INTERFACE}.service
EOF
        fi
        
        # 2. Modify ExecStart to use cgexec
        if [[ -f "$service_file" ]]; then
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
        systemctl enable tunnelsats-splitting-processes.service &>/dev/null
        systemctl start tunnelsats-splitting-processes.service &>/dev/null
        systemctl enable tunnelsats-splitting-processes.timer &>/dev/null
        systemctl start tunnelsats-splitting-processes.timer &>/dev/null
        
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
    
    # Ensure kernel routing table 51820 is clean before starting, scoped to TunnelSats ownership
    check_and_cleanup_routing_table "$WG_INTERFACE"

    print_info "Starting WireGuard..."
    local failclosed_subnet failclosed_uid
    failclosed_subnet=$(resolve_failclosed_subnet)
    failclosed_uid=$(resolve_failclosed_host_uid)
    if out=$(systemctl start wg-quick@${WG_INTERFACE} 2>&1); then
        print_success "WireGuard service started"
        # Ensure any temporary emergency failclosed block is cleared once tunnel is active
        if ! ts_release_failclosed "$failclosed_subnet" "$failclosed_uid"; then
            print_error "Emergency fail-closed block could NOT be released after starting WireGuard."
            exit 1
        fi
    else
        print_error "Failed to start service:"
        echo "$out"
        
        # Arm the emergency fail-closed block (nft, or the blackhole ip rule fallback) so no
        # clearnet leak is possible. Covers local host traffic and forwarded Docker traffic.
        if ! ts_arm_failclosed "$failclosed_subnet" "$failclosed_uid"; then
            print_error "Emergency fail-closed block could NOT be armed (nft and the blackhole ip rule fallback both failed): Lightning traffic is NOT blocked. Keep the Lightning daemon stopped until the tunnel is up."
        fi

        # Help user troubleshoot
        echo ""
        print_info "Checking status..."
        systemctl status wg-quick@${WG_INTERFACE} --no-pager -l || true
        if [[ -n "$restarted_systemd_service" ]] || [[ -n "$stopped_docker_containers" ]]; then
            echo ""
            print_warning "Lightning service was kept stopped to prevent clearnet IP leakage."
        fi
        exit 1
    fi

    # Restart Lightning node under the active tunnel if it was stopped for the restart
    if ! restart_stopped_lightning_daemon; then
        exit 1
    fi
}

# Restarts the Lightning daemon that stop_lightning_daemon_for_safe_restart stopped.
# Returns 1 on failure. Callers must only invoke this once a tunnel is verified active.
restart_stopped_lightning_daemon() {
    if [[ -n "$stopped_docker_containers" ]]; then
        print_info "Restarting ${LN_IMPL} daemon container under tunnel..."
        if docker start ${stopped_docker_containers} >/dev/null 2>&1; then
            print_success "${LN_IMPL} daemon container restarted"
        else
            print_error "Failed to restart ${LN_IMPL} daemon container"
            return 1
        fi
    elif [[ -n "$restarted_systemd_service" ]]; then
        print_info "Restarting ${restarted_systemd_service} under tunnel..."
        if systemctl start "${restarted_systemd_service}"; then
            print_success "${restarted_systemd_service} restarted"
        else
            print_error "Failed to restart ${restarted_systemd_service}"
            return 1
        fi
    fi
    return 0
}

# EXIT trap armed by cmd_install between the leak-proof daemon stop and enable_services.
# On failure it restores the previous WireGuard config and tunnel, verifies the tunnel against
# real kernel state, and only then restarts the daemon. Without a verified tunnel the daemon
# stays stopped (fail-closed) to avoid clearnet IP leakage.
rollback_failed_install() {
    local rc=$?
    trap - EXIT
    [[ "$rc" -eq 0 ]] && return 0

    if [[ -z "$stopped_docker_containers" ]] && [[ -z "$restarted_systemd_service" ]]; then
        exit "$rc"
    fi

    echo "" >&2
    print_warning "Installation failed before the new tunnel was started. Attempting to restore the previous tunnel..."

    if [[ -n "$WG_CONFIG_BACKUP" ]] && [[ -f "$WG_CONFIG_BACKUP" ]] && [[ -n "$WG_CONFIG_PATH" ]]; then
        if mv -f "$WG_CONFIG_BACKUP" "$WG_CONFIG_PATH"; then
            print_info "Restored previous WireGuard config: ${WG_CONFIG_PATH}"
        else
            print_error "Failed to restore previous WireGuard config from ${WG_CONFIG_BACKUP}. Lightning daemon kept stopped to prevent clearnet IP leakage."
            exit "$rc"
        fi
    fi

    local restore_iface="$stopped_wireguard_interface"
    if [[ -z "$restore_iface" ]] && [[ -n "$WG_INTERFACE" ]] && systemctl is-active --quiet "wg-quick@${WG_INTERFACE}" 2>/dev/null; then
        # The previous tunnel was never stopped (e.g. stopping it failed) and is still up
        restore_iface="$WG_INTERFACE"
    fi

    if [[ -z "$restore_iface" ]]; then
        print_warning "No previously active TunnelSats tunnel to restore. Lightning daemon kept stopped to prevent clearnet IP leakage."
        print_warning "Fix the error above and re-run the installer."
        exit "$rc"
    fi

    if ! systemctl is-active --quiet "wg-quick@${restore_iface}" 2>/dev/null; then
        if ! systemctl start "wg-quick@${restore_iface}" >/dev/null 2>&1; then
            print_error "Failed to restart previous tunnel (${restore_iface}). Lightning daemon kept stopped to prevent clearnet IP leakage."
            exit "$rc"
        fi
    fi
    if ! wg show "$restore_iface" >/dev/null 2>&1; then
        print_error "Previous tunnel (${restore_iface}) is not present in the kernel. Lightning daemon kept stopped to prevent clearnet IP leakage."
        exit "$rc"
    fi
    if ! ip rule show 2>/dev/null | grep -Eq "lookup 51820([[:space:]]|$)"; then
        print_error "TunnelSats policy routing (table 51820) is not active. Lightning daemon kept stopped to prevent clearnet IP leakage."
        exit "$rc"
    fi
    if [[ -n "$stopped_docker_containers" ]] && ! attach_container_to_tunnel_network "$stopped_docker_containers"; then
        print_error "Lightning container could not be attached to docker-tunnelsats. Lightning daemon kept stopped to prevent clearnet IP leakage."
        exit "$rc"
    fi
    print_success "Previous tunnel (${restore_iface}) restored"

    if restart_stopped_lightning_daemon; then
        print_warning "Lightning daemon restarted on the previous tunnel. The new installation did NOT complete."
    fi
    exit "$rc"
}

verify_installation() {
    if systemctl is-active --quiet wg-quick@${WG_INTERFACE}; then
        print_success "WireGuard service is running"
    else
        print_error "WireGuard service is not running"
        exit 1
    fi

    # Verify the Lightning daemon container(s) on docker-tunnelsats:
    # - containers the installer stopped and restarted must be running with live IP 10.9.9.9
    # - the selected target that was already stopped before installation stays stopped and
    #   only needs its static 10.9.9.9 attachment (it gets the tunnel IP when the user starts it)
    if [[ "$PLATFORM" == "umbrel" ]]; then
        if command -v docker >/dev/null 2>&1; then
            local target="$tunnel_target_container"
            if [[ -z "$target" ]]; then
                if ! target=$(select_tunnel_target_container); then
                    exit 1
                fi
            fi
            local verify_cids
            verify_cids=$(printf '%s\n' $stopped_docker_containers $target | awk 'NF && !seen[$0]++')
            if [[ -z "$verify_cids" ]]; then
                print_error "No Lightning daemon container found during verification"
                exit 1
            fi
            local cid
            for cid in $verify_cids; do
                local restarted_by_installer=0
                [[ " $(echo $stopped_docker_containers) " == *" ${cid} "* ]] && restarted_by_installer=1

                if docker ps -q --no-trunc | grep -q "^${cid}"; then
                    local container_ip
                    container_ip=$(docker inspect -f '{{with index .NetworkSettings.Networks "docker-tunnelsats"}}{{.IPAddress}}{{end}}' "$cid" 2>/dev/null)
                    if [[ "$container_ip" != "$TUNNEL_CONTAINER_IP" ]]; then
                        print_error "Container (${cid}) is not attached to docker-tunnelsats with expected IP ${TUNNEL_CONTAINER_IP} (found: ${container_ip:-none})"
                        exit 1
                    fi
                    print_success "Container (${cid}) verified running on docker-tunnelsats (${TUNNEL_CONTAINER_IP})"
                elif [[ "$restarted_by_installer" -eq 1 ]]; then
                    print_error "Restarted container (${cid}) is not running"
                    exit 1
                else
                    local tunnel_state
                    tunnel_state=$(docker inspect -f "$TUNNEL_NET_INSPECT_FMT" "$cid" 2>/dev/null || true)
                    if [[ " $tunnel_state " != *" ${TUNNEL_CONTAINER_IP} "* ]]; then
                        print_error "Stopped container (${cid}) is not attached to docker-tunnelsats with static IP ${TUNNEL_CONTAINER_IP}"
                        exit 1
                    fi
                    print_success "Container (${cid}) attached to docker-tunnelsats (${TUNNEL_CONTAINER_IP}); it was stopped before installation and was left stopped"
                fi
            done
        fi
    elif [[ -n "$restarted_systemd_service" ]]; then
        if ! systemctl is-active --quiet "${restarted_systemd_service}"; then
            print_error "${restarted_systemd_service} is not running after restart"
            exit 1
        fi
    fi
    
    if wg show ${WG_INTERFACE} &>/dev/null; then
        print_success "WireGuard tunnel is active"
    else
        print_warning "WireGuard tunnel not detected (may be starting)"
    fi

    # Pre-flight Listening Check (Non-Docker)
    if [[ "$PLATFORM" != "umbrel" ]] && [[ -n "$LN_IMPL" ]]; then
        local port=9735
        if ss -tulpn | grep -q "127.0.0.1:${port}"; then
            echo ""
            print_warning "POSSIBLE CONFIG ISSUE: ${LN_IMPL^^} is only listening on 127.0.0.1"
            print_warning "It will NOT accept inbound traffic from the tunnel."
            print_warning "Ensure 'listen=0.0.0.0:${port}' is set in your config."
        fi
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
    
    # Triple confirmation (--yes answers it; nothing has been changed before this point)
    while true; do
        ts_confirm answer "CAUTION! Uninstalling TunnelSats will force your lightning process to stop. Do you really want to proceed? (Y/N) "
        case $answer in
            [yY]*) echo "> OK, proceeding..."; echo; break ;;
            [nN]*) echo "> Exiting process."; exit 1 ;;
            *) echo "Just enter Y or N, please." ;;
        esac
    done
    
    # 1. Detect Platform & Implementation for Cleanup
    local umbrel_user=${SUDO_USER:-${USER}}
    detect_platform
    detect_ln_implementation
    local ln_impl="${LN_IMPL}"
    local is_docker=0
    local home_dir=""

    if [[ "$PLATFORM" == "umbrel" ]]; then
        is_docker=1
        home_dir="/home/$umbrel_user"
    fi

    # 2. Stop Services & Clean Dependencies
    print_step 1 6 "Stopping Lightning services..."
    
    if [[ "$ln_impl" == "lnd" ]]; then
        if [[ $is_docker -eq 1 ]]; then
             local filter_name="_lnd"
             print_info "Stopping ${ln_impl} containers..."
             local container_ids=$(docker ps --filter "name=${filter_name}" --format "{{.ID}}")
             if [[ -n "$container_ids" ]]; then
                 for id in ${container_ids}; do
                     local c_name=$(docker inspect --format '{{.Name}}' "$id" | sed 's/^\///')
                     print_info "Stopping $c_name ... (this may take a few seconds)"
                     echo -n "" >&2
                     docker stop "$id" &>/dev/null
                     docker network disconnect docker-tunnelsats "$id" &>/dev/null || true
                     print_success "Stopped $c_name"
                     echo "" >&2
                 done
             else
                 print_info "No lightning containers found"
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
        
        # Restore original service file if backup exists
        if [[ -f /etc/systemd/system/lnd.service.bak ]]; then
             mv /etc/systemd/system/lnd.service.bak /etc/systemd/system/lnd.service
             print_success "Restored original lnd.service"
        fi

        # Restore RaspiBlitz health services
        systemctl enable lnd-health.service &>/dev/null || true
        systemctl start lnd-health.service &>/dev/null || true

    elif [[ "$ln_impl" == "cln" ]]; then
        if [[ $is_docker -eq 1 ]]; then
             local filter_name="core-lightning"
             print_info "Stopping ${ln_impl} containers..."
             local container_ids=$(docker ps --filter "name=${filter_name}" --format "{{.ID}}")
             if [[ -n "$container_ids" ]]; then
                 for id in ${container_ids}; do
                     local c_name=$(docker inspect --format '{{.Name}}' "$id" | sed 's/^\///')
                     print_info "Stopping $c_name ... (this may take a few seconds)"
                     echo -n "" >&2
                     docker stop "$id" &>/dev/null
                     docker network disconnect docker-tunnelsats "$id" &>/dev/null || true
                     print_success "Stopped $c_name"
                     echo "" >&2
                 done
             else
                 print_info "No lightning containers found"
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
        
        # Restore original service file if backup exists
        if [[ -f /etc/systemd/system/lightningd.service.bak ]]; then
             mv /etc/systemd/system/lightningd.service.bak /etc/systemd/system/lightningd.service
             print_success "Restored original lightningd.service"
        fi

        # Restore RaspiBlitz health services
        systemctl enable cl-health.service &>/dev/null || true
        systemctl start cl-health.service &>/dev/null || true
    fi
    echo ""

    # 3. Restore Hybrid Mode Configuration
    print_step 2 6 "Restoring configuration files..."
    
    if [[ "$ln_impl" == "lnd" ]]; then
        local paths=(
            "/mnt/hdd/lnd/lnd.conf"
            "$home_dir/.lnd/lnd.conf"
            "/home/bitcoin/.lnd/lnd.conf"
            "$home_dir/umbrel/lnd/lnd.conf"
            "$home_dir/umbrel/app-data/lightning/data/lnd/lnd.conf"
            "/data/lnd/lnd.conf"
            "/mnt/hdd/mynode/lnd/lnd.conf"
        )
        for path in "${paths[@]}"; do
            if [[ -f "$path" ]]; then 
                local cleaned=0
                if grep -iq "externalhosts=" "$path" || grep -iq "tor.skip-proxy-for-clearnet-targets" "$path"; then
                    # Backup before surgical cleaning
                    cp "$path" "${path}.bak.$(date +%F_%H%M)"
                    sed -i "/externalhosts=/Id" "$path"
                    sed -i "/tor.skip-proxy-for-clearnet-targets/Id" "$path"
                    sed -i "/tor.streamisolation=false/Id" "$path"
                    cleaned=1
                fi
                if [[ $cleaned -eq 1 ]]; then
                    print_success "Cleaned up $path"
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
                
                # Cleanup TunnelSats specific CLN settings
                if grep -qE "^bind-addr=|^announce-addr=" "$path"; then
                    sed -i '/^bind-addr=/d' "$path" 2>/dev/null
                    sed -i '/^announce-addr=/d' "$path" 2>/dev/null
                    print_success "Removed TunnelSats address bindings in $path"
                fi
            fi
        done
        
        if [[ -f "$home_dir/umbrel/app-data/core-lightning/exports.sh" ]]; then
             sed -i 's/APP_CORE_LIGHTNING_DAEMON_PORT="9735"/APP_CORE_LIGHTNING_DAEMON_PORT="9736"/g' "$home_dir/umbrel/app-data/core-lightning/exports.sh"
             print_success "Restored Umbrel exports.sh port"
        fi
        
        if [[ -f "$home_dir/umbrel/app-data/core-lightning/docker-compose.yml" ]]; then
             # Robust uncomment: handles leading spaces, #, and potential quotes around the flag
             sed -i "s/^[[:space:]]*#[[:space:]]*- ['\"]*--bind-addr/      - '--bind-addr/g" "$home_dir/umbrel/app-data/core-lightning/docker-compose.yml" &>/dev/null
             print_success "Restored Umbrel docker-compose binding"
        fi
    elif [[ "$ln_impl" == "lit" ]]; then
        local paths=(
            "$home_dir/.lit/lit.conf"
            "/home/bitcoin/.lit/lit.conf"
            "/data/lit/lit.conf"
        )
        for path in "${paths[@]}"; do
            if [[ -f "$path" ]]; then 
                local cleaned=0
                if grep -iq "externalhosts=" "$path" || grep -iq "tor.skip-proxy-for-clearnet-targets" "$path"; then
                    cp "$path" "${path}.bak.$(date +%F_%H%M)"
                    sed -i "/externalhosts=/Id" "$path"
                    sed -i "/tor.skip-proxy-for-clearnet-targets/Id" "$path"
                    sed -i "/tor.streamisolation=false/Id" "$path"
                    cleaned=1
                fi
                if [[ $cleaned -eq 1 ]]; then
                    print_success "Cleaned up $path"
                fi
            fi
        done
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
    
    # Every installed TunnelSats tunnel is removed: the configs found by ts_select_wg_config (the
    # list detect, status and restart choose from). tunnelsatsv2 is cleaned up even without a config.
    local -a target_interfaces=()
    local target_interface wg_conf
    ts_select_wg_config "" "" "${WG_DIR:-/etc/wireguard}"
    for wg_conf in "${TS_WG_CANDIDATES[@]}"; do
        target_interfaces+=("$(basename "$wg_conf" .conf)")
    done
    if [[ ${#target_interfaces[@]} -eq 0 ]]; then target_interfaces=("tunnelsatsv2"); fi

    for target_interface in "${target_interfaces[@]}"; do
        systemctl stop "wg-quick@${target_interface}" &>/dev/null || true
        systemctl disable "wg-quick@${target_interface}" &>/dev/null || true
    done
    
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

    for target_interface in "${target_interfaces[@]}"; do
        rm -rf "/etc/systemd/system/wg-quick@${target_interface}.service.d" &>/dev/null
    done
    print_success "WireGuard services removed"
    echo ""

    # 6. NFTables Cleanup (All Platforms)
    print_step 5 6 "Cleaning network rules..."
    for target_interface in "${target_interfaces[@]}"; do
        nft delete table ip "${target_interface}" &>/dev/null || true
        nft delete table inet "${target_interface}" &>/dev/null || true
    done
    nft delete table ip tunnelsatsv2 &>/dev/null || true
    nft delete table inet tunnelsatsv2 &>/dev/null || true
    # TunnelSats is being removed on purpose: drop any emergency fail-closed block it armed
    if ! ts_release_failclosed "$(resolve_failclosed_subnet)" "$(resolve_failclosed_host_uid)"; then
        print_warning "Some emergency fail-closed rules could not be removed. Check 'ip -4 rule show'."
    fi
    
    if [[ -f /etc/nftablespriortunnelsats.backup ]]; then
         mv /etc/nftablespriortunnelsats.backup /etc/nftables.conf
         print_success "Restored original nftables.conf"
    fi

    # Remove only TunnelSats-owned policy rules/routes; other users of table 51820 are preserved
    for target_interface in "${target_interfaces[@]}"; do
        if ! cleanup_owned_routing_state "$target_interface"; then
            print_warning "Some TunnelSats policy rules could not be removed. Check 'ip rule show'."
        fi
    done

    if [[ $is_docker -eq 1 ]]; then
        print_info "Cleaning Docker network..."
        
        # Disconnect containers from network
        docker inspect docker-tunnelsats 2>/dev/null | jq '.[].Containers' | grep Name | sed 's/[",]//g' | awk '{print $2}' | xargs -I % sh -c 'docker network disconnect docker-tunnelsats % 2>/dev/null'
        
        if docker network rm docker-tunnelsats &>/dev/null; then
            print_success "Removed docker-tunnelsats network"
        fi
        
        systemctl daemon-reload || true
        systemctl restart docker &>/dev/null || true
        print_success "Docker restarted"
    fi
    echo ""

    # UFW Rules Cleanup
    if command -v ufw >/dev/null 2>&1; then
        local ufw_marker_file
        for target_interface in "${target_interfaces[@]}"; do
            ufw_marker_file=$(ufw_rule_marker_file "$target_interface")
            if [[ -f "$ufw_marker_file" ]]; then
                print_info "Removing TunnelSats UFW rules..."
                if ufw delete allow in on "${target_interface}" to any port 9735 proto tcp &>/dev/null; then
                    rm -f "$ufw_marker_file" &>/dev/null || true
                    print_success "Removed UFW rules for port 9735 on ${target_interface}"
                else
                    print_error "Failed to remove UFW rules for port 9735 on ${target_interface}"
                fi
            fi
        done
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
        if [[ "$ln_impl" == "lit" ]]; then
            local s_file="/etc/systemd/system/litd.service"
            [[ ! -f "$s_file" ]] && s_file="/etc/systemd/system/lit.service"
            if [[ -f "${s_file}.bak" ]]; then
                mv "${s_file}.bak" "$s_file"
                print_success "Restored ${s_file} backup"
            fi
        fi
        systemctl daemon-reload
        echo ""
    fi
    
    # Optional Package Removal. This question comes after the removal steps above, so it never
    # fails: --remove-packages or --keep-packages answer it, while non-interactive mode and end
    # of input keep the packages (the safe answer).
    case "$TS_OPT_PACKAGES" in
        remove) answer="Y" ;;
        keep) answer="N" ;;
        *)
            if [[ "$TS_NONINTERACTIVE" -eq 1 ]]; then
                answer="N"
                print_info "Non-interactive mode: keeping system packages (pass --remove-packages to remove them)"
            else
                echo "Do you want to uninstall system packages?"
                if [[ $is_docker -eq 1 ]]; then
                    ts_ask answer "--remove-packages" "Remove nftables and wireguard-tools? (Y/N) " "N"
                else
                    ts_ask answer "--remove-packages" "Remove cgroup-tools, nftables and wireguard-tools? (Y/N) " "N"
                fi
            fi
            ;;
    esac
    
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
    if [[ "$ln_impl" == "lnd" ]]; then
        if [[ "$PLATFORM" == "umbrel" ]]; then
            echo -e "  Command: ${BOLD}nano $home_dir/umbrel/app-data/lightning/data/lnd/lnd.conf${NC}"
        fi
        echo "  - externalhosts (should be removed)"
        echo "  - tor.skip-proxy-for-clearnet-targets (should be false or removed)"
    elif [[ "$ln_impl" == "cln" ]]; then
        if [[ "$PLATFORM" == "umbrel" ]]; then
            echo -e "  Command: ${BOLD}nano $home_dir/umbrel/app-data/core-lightning/data/lightningd/bitcoin/config${NC}"
        fi
        echo "  - announce-addr (should be removed)"
        echo "  - bind-addr=0.0.0.0:9735 (should be removed)"
    elif [[ "$ln_impl" == "lit" ]]; then
        echo "  - externalhosts (should be removed)"
        echo "  - tor.skip-proxy-for-clearnet-targets (should be false or removed)"
    fi
    echo ""
    
    echo "Next: Restart your node for changes to take effect."
    echo "      (Required to fully clear persistent network rules)"
    echo ""
    echo -e "   ${BOLD}sudo reboot${NC}"
    echo ""
}

cmd_install() {
    check_root
    check_umbrel_version
    print_header "TunnelSats Installation"

    # Step 1: Configuration is already detected in parse_args
    print_step 1 6 "Configuration verified: ${CONFIG_FILE##*/}"
    echo ""
    
    # Step 2: Detect Environment
    print_step 2 6 "Analyzing environment..."
    detect_platform
    detect_ln_implementation
    
    local is_docker=0
    [[ "$PLATFORM" == "umbrel" ]] && is_docker=1
    [[ "$PLATFORM" == "mynode" ]] && is_docker=0 # myNode nodal part is bare metal
    
    print_info "Platform: ${PLATFORM}, Lightning: ${LN_IMPL}"
    echo ""

    # Step 3: Check dependencies
    print_step 3 6 "Checking dependencies..."
    # wireguard-tools and its systemd unit template
    local wg_service_template_exists=0
    [[ -f /lib/systemd/system/wg-quick@.service || -f /usr/lib/systemd/system/wg-quick@.service || -f /etc/systemd/system/wg-quick@.service ]] && wg_service_template_exists=1

    if ! command -v wg &>/dev/null || [[ $wg_service_template_exists -eq 0 ]]; then
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
    if ! command -v jq &>/dev/null; then
        print_info "Installing jq..."
        apt-get install -yqq jq &>/dev/null
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

    # Resolve target tunnel interface up front so an already-active tunnel is stopped and tracked
    WG_INTERFACE=$(basename "$(resolve_wg_target_path)" .conf)

    # Any failure between the leak-proof stop and enable_services restores the previous tunnel
    # (verified) before restarting the daemon, or keeps the daemon stopped (fail-closed).
    trap rollback_failed_install EXIT

    # Stop running Lightning daemon BEFORE any route or network changes to prevent clearnet leakage
    stop_lightning_daemon_for_safe_restart

    # Step 5: Configure WireGuard
    print_step 5 6 "Configuring WireGuard..."
    configure_wireguard
    
    # Configure DNS Resolver Watchdog
    setup_dns_resolver "$WG_INTERFACE"
    
    # Configure Docker Network (Umbrel/Docker only)
    if [[ $is_docker -eq 1 ]]; then
        setup_docker_network
    fi
    echo ""

    # enable_services has its own fail-closed handling once the new tunnel start is attempted
    trap - EXIT

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
    local vpn_port=$(ts_config_vpn_port "$CONFIG_FILE")
    
    echo -e "${BOLD}CRITICAL: You must update your node configuration!${NC}"
    echo "Please copy the following settings into your configuration file."
    echo ""

    print_node_config_instructions "$vpn_dns" "$vpn_port" "install"

    # Check firewall configuration if UFW is active
    if command -v ufw >/dev/null 2>&1; then
        echo ""
        print_info "Checking Firewall Configuration (UFW)..."
        check_ufw_configuration "$WG_INTERFACE" || true
    elif [[ "$PLATFORM" == "baremetal" || "$PLATFORM" == "raspiblitz" ]]; then
        echo ""
        echo -e "${BOLD}${YELLOW}UFW FIREWALL NOTICE:${NC}"
        echo "If you use UFW, ensure you allow traffic on the Lightning port (TCP 9735):"
        echo -e "  ${BOLD}sudo ufw allow 9735/tcp${NC}"
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
                # Only auto-detect if Integrated Mode
                local s_file="/etc/systemd/system/litd.service"
                [[ ! -f "$s_file" ]] && s_file="/etc/systemd/system/lit.service"
                if grep -qi "lnd-mode=integrated" "$s_file" 2>/dev/null || grep -qi "lnd-mode.*integrated" /etc/lit/lit.conf 2>/dev/null || grep -qi "lnd-mode.*integrated" "$HOME/.lit/lit.conf" 2>/dev/null; then
                    LN_IMPL="lit"
                fi
            fi
        fi
    fi

    # Detect node user for non-Docker
    if [[ -n "$LN_IMPL" ]] && [[ "$PLATFORM" != "umbrel" ]] && [[ -z "$node_user" ]]; then
        local s_file=""
        [[ "$LN_IMPL" == "lnd" ]] && s_file="/etc/systemd/system/lnd.service"
        [[ "$LN_IMPL" == "cln" ]] && s_file="/etc/systemd/system/lightningd.service"
        if [[ "$LN_IMPL" == "lit" ]]; then
            s_file="/etc/systemd/system/litd.service"
            [[ ! -f "$s_file" ]] && s_file="/etc/systemd/system/lit.service"
        fi
        if [[ -f "$s_file" ]]; then
            node_user=$(grep -Ei "^User[[:space:]]*=" "$s_file" | cut -d'=' -f2 | xargs)
        fi
        [[ -z "$node_user" ]] && [[ "$PLATFORM" == "raspiblitz" ]] && node_user="bitcoin"
        [[ -z "$node_user" ]] && node_user=$(whoami)
    fi
    return 0
}

cmd_status() {
    print_header "Subscription Status"
    
    echo ""
    
    # 0. Auto-detect environment if not set
    auto_detect_environment
    
    # 1. Active Config & WireGuard Status Check
    # Same selection as detect and restart (--config, tunnelsatsv2.conf, the only tunnelsats-*.conf);
    # several candidates are asked, never guessed
    local config_file
    if ! ts_resolve_wg_config; then
        print_error "No TunnelSats configuration found."
        echo "Expected locations:"
        echo "  • /etc/wireguard/tunnelsatsv2.conf"
        echo "  • /etc/wireguard/tunnelsats-*.conf"
        echo "Pass --config <file> for a config with another name."
        exit 1
    fi
    config_file="$TS_WG_RESOLVED"

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
    local vpn_port=$(ts_config_vpn_port "$config_file")
    local sub_end=$(parse_config_metadata "$config_file" expiry)
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
        local target_impl="${LN_IMPL:-unknown}"

        case "$setup_type" in
            "docker-lnd")
                docker_name=$(docker ps --filter name=_lnd --format "{{.Names}}" | head -n 1) # Safer fetch
                if [[ -z "$docker_name" ]]; then docker_name="lightning_lnd_1"; fi # Fallback
                node_type="LND (Docker)"
                if command -v jq &> /dev/null; then
                    # Try direct exec
                    local info=$(docker exec "$docker_name" lncli getinfo 2>/dev/null)
                    if [[ -n "$info" ]]; then
                        ext_addr=$(echo "$info" | jq -r '.uris[]' | grep -v "\.onion" | head -n 1)
                        [[ -z "$ext_addr" ]] && ext_addr="NONE_DETECTED"
                    else
                        ext_addr="NODE_UNREACHABLE"
                    fi
                else
                    ext_addr="DEPENDENCY_MISSING"
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
                     if [[ -n "$info" ]]; then
                         local pk=$(echo "$info" | jq -r '.id')
                         local ip=$(echo "$info" | jq -r '.address[] | select(.type == "ipv4") | .address' | head -n 1)
                         local port=$(echo "$info" | jq -r '.address[] | select(.type == "ipv4") | .port' | head -n 1)
                         if [[ -n "$pk" && -n "$ip" ]]; then 
                             ext_addr="${pk}@${ip}:${port}"
                         else
                             ext_addr="NONE_DETECTED"
                         fi
                     else
                         ext_addr="NODE_UNREACHABLE"
                     fi
                else
                    ext_addr="DEPENDENCY_MISSING"
                fi
                ;;
            "manual")
                # Attempt to guess
                local original_user="${SUDO_USER:-$(whoami)}"
                
                 if [[ "$target_impl" == "lnd" ]]; then
                    node_type="LND (Systemd)"
                    if command -v lncli &> /dev/null; then
                         local info
                         # Try as sudo user first (RaspiBlitz standard)
                         info=$(sudo -u "$original_user" lncli getinfo 2>/dev/null)
                         
                         # Fallback to common node users with explicit data directory check
                         if [[ -z "$info" ]]; then
                            local users=("$node_user" "lnd" "bitcoin" "admin")
                            for u in "${users[@]}"; do
                                [[ -z "$u" ]] && continue
                                # Try with default paths for that user
                                info=$(sudo -u "$u" lncli getinfo 2>/dev/null)
                                [[ -n "$info" ]] && break
                            done
                         fi
                         
                         if [[ -n "$info" ]]; then
                             ext_addr=$(echo "$info" | jq -r '.uris[]' | grep -v "\.onion" | head -n 1)
                             [[ -z "$ext_addr" ]] && ext_addr="NONE_DETECTED"
                         else
                             ext_addr="NODE_UNREACHABLE"
                         fi
                    else
                         ext_addr="CLI_MISSING"
                    fi
                 elif [[ "$target_impl" == "cln" ]]; then
                    node_type="CLN (Systemd)"
                     if command -v lightning-cli &> /dev/null; then
                         local info
                         info=$(sudo -u "$original_user" lightning-cli getinfo 2>/dev/null)
                         [[ -z "$info" ]] && [[ "$node_user" != "$original_user" ]] && info=$(sudo -u "$node_user" lightning-cli getinfo 2>/dev/null)
                         [[ -z "$info" ]] && info=$(sudo -u bitcoin lightning-cli getinfo 2>/dev/null)
                         [[ -z "$info" ]] && info=$(lightning-cli getinfo 2>/dev/null)
                         
                         if [[ -n "$info" ]]; then
                             local pk=$(echo "$info" | jq -r '.id')
                             local ip=$(echo "$info" | jq -r '.address[] | select(.type == "ipv4") | .address' | head -n 1)
                             local port=$(echo "$info" | jq -r '.address[] | select(.type == "ipv4") | .port' | head -n 1)
                             if [[ -n "$pk" && -n "$ip" ]]; then 
                                 ext_addr="${pk}@${ip}:${port}"
                             else
                                 ext_addr="NONE_DETECTED"
                             fi
                         else
                             ext_addr="NODE_UNREACHABLE"
                         fi
                     else
                         ext_addr="CLI_MISSING"
                     fi
                  elif systemctl is-active --quiet litd || systemctl is-active --quiet lit; then
                    node_type="LIT (Systemd)"
                    if command -v litcli &> /dev/null; then
                         local info
                         info=$(sudo -u "$original_user" litcli getinfo 2>/dev/null)
                         [[ -z "$info" ]] && info=$(litcli getinfo 2>/dev/null)
                         if [[ -n "$info" ]]; then
                             ext_addr=$(echo "$info" | jq -r '.lnd_uris[]' | grep -v "\.onion" | head -n 1)
                             [[ -z "$ext_addr" ]] && ext_addr="NONE_DETECTED"
                         else
                             ext_addr="NODE_UNREACHABLE"
                         fi
                    else
                         ext_addr="CLI_MISSING"
                    fi
                  else
                    node_type="Unknown/Manual"
                  fi
                ;;
        esac
        
        # Check if we actually have jq
        if ! command -v jq &> /dev/null; then
            echo "$node_type|DEPENDENCY_MISSING"
            return 0
        fi

        echo "$node_type|$ext_addr"
    }

    # Execute Checks
    local setup_method=$(check_docker_setup_status)
    local outbound_ip="N/A"
    local inbound_status="N/A" 
    local inbound_ip="N/A"
    
    # 1. Listening Check (Manual/Bare Metal)
    if [[ "$setup_method" == "manual" ]] && [[ -n "$LN_IMPL" ]]; then
        if ss -tulpn | grep -q "127.0.0.1:9735"; then
            print_warning "Node only listening on Localhost (127.0.0.1)!"
        fi
    fi

    # Only run if config is valid
    if [[ -n "$endpoint" && -n "$vpn_port" ]]; then
         outbound_ip=$(perform_outbound_check_status "$setup_method")
         read -r inbound_status inbound_ip <<< "$(perform_inbound_check_status "$endpoint" "$vpn_port")"
    fi

    local node_data=$(get_node_ext_addr_status "$setup_method")
    local node_type=$(echo "$node_data" | cut -d '|' -f 1)
    local node_addr=$(echo "$node_data" | cut -d '|' -f 2)

    local ufw_status_str="Not Installed"
    local ufw_blocked=0
    if command -v ufw >/dev/null 2>&1; then
        local ufw_status_out
        ufw_status_out=$(ufw status 2>/dev/null)
        if echo "$ufw_status_out" | grep -q "Status: active"; then
            if is_port_allowed_in_ufw "$interface_name" "9735" "$ufw_status_out"; then
                ufw_status_str="${GREEN}Active (Port 9735 Allowed)${NC}"
            else
                ufw_status_str="${RED}Active (Port 9735 BLOCKED on ${interface_name})${NC}"
                ufw_blocked=1
            fi
        else
            ufw_status_str="Inactive"
        fi
    fi

    echo -e "${BOLD}Node Configuration${NC}"
    print_line
    echo -e "  Type:           $node_type"
    echo -e "  Public Address: $node_addr"
    echo ""
    
    echo -e "${BOLD}Connectivity Check${NC}"
    print_line
    echo -e "  Outbound IP:    $outbound_ip"
    echo -e "  Inbound Check:  $inbound_status ($inbound_ip)"
    echo -e "  UFW Status:     $ufw_status_str"
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

    if [[ $ufw_blocked -eq 1 ]]; then
        echo ""
        echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD}${YELLOW}⚠  UFW FIREWALL BLOCKING PORT 9735!${NC}"
        echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "Your UFW firewall is active, but it does NOT allow inbound traffic"
        echo "on the Lightning port (9735) via your WireGuard interface (${interface_name})."
        echo ""
        echo "To allow traffic via this interface specifically, run:"
        echo -e "  ${BOLD}sudo ufw allow in on ${interface_name} to any port 9735 proto tcp${NC}"
        echo ""
        echo "Or to allow it globally on all interfaces:"
        echo -e "  ${BOLD}sudo ufw allow 9735/tcp${NC}"
        echo ""
        echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    fi

    # ---------------------------------------------------------
    # MISCONFIGURATION DETECTION: Node not advertising VPN address
    # Scenario: Tunnel works (inbound/outbound OK) but getinfo shows no VPN URI
    # ---------------------------------------------------------
    if $outbound_ok && $inbound_ok; then
        # ONLY warn if we successfully talked to the node and confirmed it has NO clearnet address
        if [[ "$node_addr" == "NONE_DETECTED" ]] || [[ -z "$node_addr" ]]; then
            echo ""
            echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BOLD}${YELLOW}⚠  NODE NOT ADVERTISING VPN ADDRESS!${NC}"
            echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo "Your tunnel is working perfectly, but your node isn't configured"
            echo "to announce the VPN address to the Lightning network."
            echo ""
            echo "Other nodes CAN connect to you through the tunnel, but they"
            echo "don't know about your clearnet address (it won't appear in lncli getinfo)."
            echo ""
            echo -e "${BOLD}To fix this, please update your node configuration:${NC}"
            echo ""
            
            # Get VPN endpoint details from config for guidance
            local status_vpn_dns=$(grep "^Endpoint" "$config_file" | awk '{print $3}' | cut -d ':' -f 1)
            local status_vpn_port="$vpn_port"
            
            print_node_config_instructions "$status_vpn_dns" "$status_vpn_port" "status"
            
            echo ""
            echo -e "${BOLD}Then restart your node:${NC}"
            if [[ "$PLATFORM" == "umbrel" ]]; then
                echo "   sudo reboot"
                echo "   (Or restart the Lightning app via Umbrel Dashboard: Right-click -> Restart)"
            else
                local svc="${LN_IMPL}"
                [[ "$LN_IMPL" == "cln" ]] && svc="lightningd"
                if [[ "$LN_IMPL" == "lit" ]]; then
                    # Use systemctl is-active for consistent service detection
                    if systemctl is-active --quiet litd 2>/dev/null; then
                        svc="litd"
                    elif systemctl is-active --quiet lit 2>/dev/null; then
                        svc="lit"
                    else
                        svc="litd"  # Default fallback
                    fi
                fi
                echo "   sudo systemctl restart ${svc}.service"
            fi
            echo ""
            echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
        fi
    fi

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
    
    # 1. Find Config/Interface: same selection as detect and status (--config, tunnelsatsv2.conf,
    # the only tunnelsats-*.conf). Several candidates are asked, never guessed, and a foreign
    # WireGuard interface is never restarted.
    local config_file
    if ! ts_resolve_wg_config; then
        print_error "No TunnelSats configuration found. Pass --config <file> for a config with another name."
        exit 1
    fi
    config_file="$TS_WG_RESOLVED"
    
    local interface_name=$(basename "$config_file" .conf)
    local stopped_containers=""
    local node_stopped_systemd=0
    local service_name="${LN_IMPL}"
    [[ "$LN_IMPL" == "cln" ]] && service_name="lightningd"
    if [[ "$LN_IMPL" == "lit" ]]; then
        service_name="litd"
        systemctl list-units --type=service | grep -q "lit.service" && service_name="lit"
    fi
    
    echo ""
    print_info "Platform: ${PLATFORM:-unknown}, Lightning: ${LN_IMPL:-unknown}"
    print_info "Interface: ${interface_name}"
    echo ""

    # 2. Deactivate Lightning node for safety (Privacy first / Leak-proof)
    if [[ "$PLATFORM" == "umbrel" ]] && [[ -n "$LN_IMPL" ]]; then
        local filter_name="lnd"
        [[ "$LN_IMPL" == "cln" ]] && filter_name="core-lightning"
        
        echo -e "${YELLOW}Umbrel detected. To ensure a leak-proof restart, we need to temporarily${NC}"
        echo -e "${YELLOW}stop your ${LN_IMPL} app containers.${NC}"
        ts_confirm restart_confirm "Do you want to proceed? [y/N]: "
        if [[ ! "$restart_confirm" =~ ^[Yy]$ ]]; then
            print_info "Restart aborted by user."
            exit 0
        fi
        echo ""

        print_info "Stopping ${LN_IMPL} app for safe restart..."
        stopped_containers=$(get_lightning_docker_containers)
        
        if [[ -n "$stopped_containers" ]]; then
            docker stop ${stopped_containers} &>/dev/null
            print_success "${LN_IMPL} app stopped (Leak-proof mode)"
        fi
    elif [[ "$PLATFORM" != "umbrel" ]] && [[ -n "$LN_IMPL" ]]; then
        echo -e "${YELLOW}Non-Docker setup detected. To ensure a leak-proof restart, it is${NC}"
        echo -e "${YELLOW}highly recommended to stop your node service temporarily.${NC}"
        # --yes stops the daemon (the leak-proof answer). Restarting without stopping it is only
        # possible interactively; non-interactive mode without --yes fails before any change.
        ts_confirm stop_confirm "Stop ${service_name}.service for safe tunnel restart? [y/N]: "
        if [[ "$stop_confirm" =~ ^[Yy]$ ]]; then
            print_info "Stopping ${service_name}.service..."
            if systemctl stop "${service_name}.service"; then
                node_stopped_systemd=1
                print_success "Node stopped (Leak-proof mode)"
            fi
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
    
    # 4. App Restart
    if [[ "$PLATFORM" == "umbrel" ]] && [[ -n "$stopped_containers" ]]; then
        print_info "Restarting ${LN_IMPL} app containers..."
        docker start ${stopped_containers} &>/dev/null
        print_success "${LN_IMPL} app restarted"
    elif [[ "$node_stopped_systemd" -eq 1 ]]; then
        print_info "Starting ${service_name}.service..."
        systemctl start "${service_name}.service"
        print_success "${LN_IMPL} service restarted"
    fi

    # 5. Verify
    echo ""
    print_info "Verifying tunnel state..."
    sleep 2
    if [[ -n "$(wg show ${interface_name} 2>/dev/null)" ]]; then
        print_success "Tunnel Interface is UP"
        echo ""
        print_info "Note: Your node implementation (${LN_IMPL:-unknown}) may take several minutes"
        print_info "to fully initialize and start listening on its ports."
        echo ""
        echo "Please wait a moment, then run this command to verify full connectivity:"
        echo -e "   ${BOLD}sudo bash tunnelsats.sh status${NC}"
    else
        print_error "Tunnel Interface did not come up"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# VERSION COMMAND
# ---------------------------------------------------------------------------

# Prints the sha256 of the running script file; fails if it cannot be computed.
ts_script_sha256() {
    local file="$TS_SCRIPT_PATH" out=""
    if [[ ! -f "$file" ]] || [[ ! -r "$file" ]]; then
        return 1
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        out=$(sha256sum -b "$file" 2>/dev/null) || return 1
    elif command -v shasum >/dev/null 2>&1; then
        out=$(shasum -a 256 "$file" 2>/dev/null) || return 1
    else
        return 1
    fi
    out="${out%% *}"
    if [[ ! "$out" =~ ^[0-9a-f]{64}$ ]]; then
        return 1
    fi
    echo "$out"
}

cmd_version() {
    local sha="" rc=0 errors="[]"
    if ! sha=$(ts_script_sha256); then
        sha=""
        rc=1
    fi
    if [[ "$TS_JSON" -eq 1 ]]; then
        if [[ "$rc" -ne 0 ]]; then
            ts_j_error E_SHA256_UNAVAILABLE operational "Could not compute the sha256 of the running script file"
            errors="[${TS_R}]"
        fi
        ts_j_str_or_null "$sha"
        ts_json_document "$rc" "$errors" "\"tool_sha256\":${TS_R}"
    else
        echo "tunnelsats.sh ${VERSION} (CLI contract ${TS_CONTRACT})"
        if [[ -n "$sha" ]]; then
            echo "sha256: ${sha}"
        else
            print_error "Could not compute the sha256 of the running script file [E_SHA256_UNAVAILABLE]"
        fi
    fi
    exit "$rc"
}

# ---------------------------------------------------------------------------
# DETECT COMMAND (read-only)
# Reports platform hints, Lightning units, an existing TunnelSats install with its artifacts,
# config facts, capabilities and conflicts. Strictly read-only: no writes anywhere (not even
# temporary files, so no here-strings or here-documents), no network, no package or service
# changes. Works without root: whatever cannot be read gets an explicit status such as
# permission_denied instead of a guess. File reads are prefixed with TS_FS_ROOT and commands run
# through WG_BIN, WG_QUICK_BIN, NFT_BIN, IP_BIN and SYSTEMCTL_BIN, so tests use fixture trees
# and stubs.
# ---------------------------------------------------------------------------

TSD_ST=""
TSD_UNREADABLE=0
TSD_IFACES=" tunnelsatsv2 "
TSD_PLATFORM_GUESS=""
TSD_HINT_PLATFORM=()
TSD_HINT_PATH=()
TSD_HINT_STATUS=()
TSD_LN_GUESS=""
TSD_LN_IMPL=()
TSD_LN_UNIT=()
TSD_LN_FILE=()
TSD_LN_ACTIVE=()
TSD_LN_USER=()
TSD_LN_PATH=()
# systemd unit search path in precedence order (admin, runtime, local, vendor); first match wins
TSD_UNIT_DIRS="/etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system /usr/lib/systemd/system /lib/systemd/system"
TSD_ART_ID=()
TSD_ART_LOC=()
TSD_ART_STATUS=()
TSD_ART_DETAIL=()
TSD_ART_SECRET=()
TSD_T51820_STATUS=""
TSD_T51820_FOREIGN=()
TSD_INSTALL_KIND=""
TSD_INSTALL_CANDIDATES=()
TSD_EVIDENCE=()
TSD_CONF_ID=()
TSD_CONF_STATUS=()
TSD_CONF_DETAIL=()
TSD_CFG_SELECTION="none"
TSD_CFG_CANDIDATES=()

# Sets TSD_ST to present, absent or permission_denied for path $1 (below TS_FS_ROOT).
ts_detect_path_status() {
    local p="${TS_FS_ROOT}$1" dir
    if [[ -e "$p" ]] || [[ -L "$p" ]]; then
        TSD_ST="present"
        return 0
    fi
    # Absent, or hidden behind a directory that may not be searched: check the nearest existing parent
    dir="$p"
    while [[ "$dir" == */* ]]; do
        dir="${dir%/*}"
        if [[ -z "$dir" ]]; then
            break
        fi
        if [[ -e "$dir" ]]; then
            if [[ -d "$dir" ]] && [[ ! -x "$dir" ]]; then
                TSD_ST="permission_denied"
                return 0
            fi
            break
        fi
    done
    TSD_ST="absent"
    return 0
}

# Sets TSD_ST to readable, absent or permission_denied for a file whose content is needed.
ts_detect_read_status() {
    ts_detect_path_status "$1"
    if [[ "$TSD_ST" == "present" ]]; then
        if [[ ! -f "${TS_FS_ROOT}$1" ]]; then
            TSD_ST="absent"
        elif [[ -r "${TS_FS_ROOT}$1" ]]; then
            TSD_ST="readable"
        else
            TSD_ST="permission_denied"
        fi
    fi
    return 0
}

# Records one artifact: $1 = id, $2 = location, $3 = status, $4 = detail, $5 = 1 if it holds keys.
ts_detect_art() {
    TSD_ART_ID+=("$1")
    TSD_ART_LOC+=("$2")
    TSD_ART_STATUS+=("$3")
    TSD_ART_DETAIL+=("${4:-}")
    TSD_ART_SECRET+=("${5:-0}")
}

# Records artifact $1 for path $2 ($3 = 1 if it holds keys).
ts_detect_art_path() {
    ts_detect_path_status "$2"
    ts_detect_art "$1" "$2" "$TSD_ST" "" "${3:-0}"
}

# Records every entry of directory $2 matching glob $3 as artifact $1 ($4 = 1 if they hold keys),
# or a single entry with the pattern when nothing matches or the directory cannot be listed.
ts_detect_art_glob() {
    local id="$1" dir="$2" pattern="$3" secret="${4:-0}" full="${TS_FS_ROOT}$2" entry found=0
    ts_detect_path_status "$dir"
    if [[ "$TSD_ST" == "present" ]] && { [[ ! -r "$full" ]] || [[ ! -x "$full" ]]; }; then
        TSD_ST="permission_denied"
    fi
    if [[ "$TSD_ST" != "present" ]]; then
        ts_detect_art "$id" "${dir}/${pattern}" "$TSD_ST" "" "$secret"
        return 0
    fi
    # $pattern is unquoted on purpose: it is the glob to expand
    # shellcheck disable=SC2086
    for entry in "$full"/$pattern; do
        if [[ -e "$entry" ]] || [[ -L "$entry" ]]; then
            found=1
            ts_detect_art "$id" "${entry#"$TS_FS_ROOT"}" "present" "" "$secret"
        fi
    done
    if [[ "$found" -eq 0 ]]; then
        ts_detect_art "$id" "${dir}/${pattern}" "absent" "" "$secret"
    fi
    return 0
}

# Adds evidence id $1 for the install classification (once).
ts_detect_evidence() {
    local item
    for item in "${TSD_EVIDENCE[@]}"; do
        if [[ "$item" == "$1" ]]; then
            return 0
        fi
    done
    TSD_EVIDENCE+=("$1")
}

ts_detect_conflict() {
    TSD_CONF_ID+=("$1")
    TSD_CONF_STATUS+=("$2")
    TSD_CONF_DETAIL+=("${3:-}")
}

ts_valid_wg_key() {
    [[ "$1" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]
}

# Derives the WireGuard public key from private key $1 with "wg pubkey". The private key goes
# through stdin (never an argument of an external command) and is never printed.
ts_derive_wg_pubkey() {
    local pub=""
    pub=$(printf '%s\n' "$1" | "$WG_BIN" pubkey 2>/dev/null) || return 1
    if ! ts_valid_wg_key "$pub"; then
        return 1
    fi
    echo "$pub"
}

# Sets TSD_ST to the systemctl is-active state of unit $1 ("unavailable" without systemctl).
ts_detect_unit_active() {
    local out=""
    if ! command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1; then
        TSD_ST="unavailable"
        return 0
    fi
    out=$("$SYSTEMCTL_BIN" is-active "$1" 2>/dev/null) || true
    out="${out%%$'\n'*}"
    case "$out" in
        active|inactive|failed|activating|deactivating|reloading|maintenance|refreshing) TSD_ST="$out" ;;
        *) TSD_ST="unknown" ;;
    esac
    return 0
}

# Succeeds if systemd state $1 means that the unit runs (or is starting, stopping or reloading).
ts_detect_unit_running() {
    case "$1" in
        active|activating|deactivating|reloading|refreshing) return 0 ;;
    esac
    return 1
}

# Succeeds if unit file $1 (below TS_FS_ROOT) is masked: systemd treats a symlink to /dev/null
# (systemctl mask) and an empty unit file as masked, so the unit cannot be started.
ts_detect_unit_masked() {
    local p="${TS_FS_ROOT}$1" target=""
    if [[ -L "$p" ]]; then
        target=$(readlink "$p" 2>/dev/null) || target=""
        if [[ "$target" == "/dev/null" ]]; then
            return 0
        fi
    fi
    [[ -f "$p" ]] && [[ ! -s "$p" ]]
}

ts_detect_platform() {
    local marker platform rest
    TSD_PLATFORM_GUESS=$(ts_guess_platform "$TS_FS_ROOT")
    for marker in "${TS_PLATFORM_MARKERS[@]}"; do
        platform="${marker%% *}"
        rest="${marker#* }"
        ts_detect_path_status "${rest#* }"
        TSD_HINT_PLATFORM+=("$platform")
        TSD_HINT_PATH+=("${rest#* }")
        TSD_HINT_STATUS+=("$TSD_ST")
    done
}

ts_detect_lightning() {
    local entry impl unit dir found file_status user
    # The guess is what the installer would detect (unit file in /etc/systemd/system or active unit)
    TSD_LN_GUESS=$(ts_guess_ln_impl_systemd "$TS_FS_ROOT")
    for entry in lnd:lnd.service cln:lightningd.service lit:litd.service lit:lit.service; do
        impl="${entry%%:*}"
        unit="${entry#*:}"
        found=""
        file_status="absent"
        user=""
        # Unit file in any unit directory: packages install them under /usr/lib/systemd/system
        # $TSD_UNIT_DIRS is split into words on purpose
        # shellcheck disable=SC2086
        for dir in $TSD_UNIT_DIRS; do
            ts_detect_path_status "${dir}/${unit}"
            if [[ "$TSD_ST" == "present" ]]; then
                found="${dir}/${unit}"
                file_status="present"
                # systemctl mask hides every other unit file of the same name
                if ts_detect_unit_masked "$found"; then
                    file_status="masked"
                fi
                break
            fi
            if [[ "$TSD_ST" == "permission_denied" ]]; then
                file_status="permission_denied"
            fi
        done
        if [[ "$file_status" == "present" ]] && [[ -r "${TS_FS_ROOT}${found}" ]]; then
            user=$(grep -Ei '^[[:space:]]*User[[:space:]]*=' "${TS_FS_ROOT}${found}" 2>/dev/null | head -n 1 | cut -d'=' -f2 | tr -d '[:space:]') || user=""
            if [[ ! "$user" =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]]; then
                user=""
            fi
        fi
        ts_detect_unit_active "$unit"
        TSD_LN_IMPL+=("$impl")
        TSD_LN_UNIT+=("$unit")
        TSD_LN_FILE+=("$file_status")
        TSD_LN_PATH+=("$found")
        TSD_LN_ACTIVE+=("$TSD_ST")
        TSD_LN_USER+=("$user")
    done
}

# Lightning drop-in $1: v2 wrote Requires=, v3 writes Wants= for tunnelsats-create-cgroup.service.
ts_detect_ln_dropin() {
    local path="$1" detail=""
    ts_detect_read_status "$path"
    case "$TSD_ST" in
        readable)
            TSD_ST="present"
            if grep -qE '^[[:space:]]*Requires[[:space:]]*=[[:space:]]*tunnelsats-create-cgroup\.service' "${TS_FS_ROOT}${path}" 2>/dev/null; then
                detail="requires"
            elif grep -qE '^[[:space:]]*Wants[[:space:]]*=[[:space:]]*tunnelsats-create-cgroup\.service' "${TS_FS_ROOT}${path}" 2>/dev/null; then
                detail="wants"
            else
                detail="unrecognized"
            fi
            ;;
        permission_denied)
            ts_detect_path_status "$path"
            if [[ "$TSD_ST" == "present" ]]; then
                detail="unreadable"
            fi
            ;;
    esac
    ts_detect_art ln_dropin "$path" "$TSD_ST" "$detail"
}

# In-place edits of Lightning unit $1: cgexec in ExecStart, RaspiBlitz check commented out.
ts_detect_ln_unit_edits() {
    local path="$1"
    ts_detect_read_status "$path"
    case "$TSD_ST" in
        absent) return 0 ;;
        permission_denied)
            ts_detect_art ln_unit_cgexec "$path" "permission_denied"
            ts_detect_art ln_unit_check_disabled "$path" "permission_denied"
            return 0
            ;;
    esac
    if grep -qE '^[[:space:]]*ExecStart[[:space:]]*=.*cgexec' "${TS_FS_ROOT}${path}" 2>/dev/null; then
        ts_detect_art ln_unit_cgexec "$path" "present"
    else
        ts_detect_art ln_unit_cgexec "$path" "absent"
    fi
    if grep -qE '^[[:space:]]*#[[:space:]]*ExecStartPre[[:space:]]*=.*(lnd|cl)\.check\.sh' "${TS_FS_ROOT}${path}" 2>/dev/null; then
        ts_detect_art ln_unit_check_disabled "$path" "present"
    else
        ts_detect_art ln_unit_check_disabled "$path" "absent"
    fi
}

ts_detect_ip_rules() {
    local out="" rc=0 line st_main="absent" st_mark="absent" st_legacy="absent" st_failclosed="absent"
    if ! command -v "$IP_BIN" >/dev/null 2>&1; then
        st_main="unavailable"
        st_mark="unavailable"
        st_legacy="unavailable"
        st_failclosed="unavailable"
    else
        out=$("$IP_BIN" -4 rule show 2>/dev/null) || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            st_main="error"
            st_mark="error"
            st_legacy="error"
            st_failclosed="error"
        else
            while IFS= read -r line; do
                case "$line" in
                    "21820:"*"from all lookup main suppress_prefixlength 0"*) st_main="present" ;;
                    "21821:"*"lookup 51820"*) st_mark="present" ;;
                    "21818:"*"blackhole"*|"21819:"*"blackhole"*) st_failclosed="present" ;;
                    *"from all fwmark 0x1000000/0xff000000 lookup 51820"*) st_legacy="present" ;;
                esac
            done < <(printf '%s\n' "$out")
        fi
    fi
    ts_detect_art ip_rule "ip -4 rule 21820 (lookup main suppress_prefixlength 0)" "$st_main"
    ts_detect_art ip_rule "ip -4 rule 21821 (lookup 51820)" "$st_mark"
    ts_detect_art ip_rule_legacy "ip -4 rule fwmark 0x1000000/0xff000000 lookup 51820 (other priority)" "$st_legacy"
    ts_detect_art failclosed_rules "ip -4 rule 21818/21819 blackhole" "$st_failclosed"
}

ts_detect_nft_tables() {
    local out="" rc=0 line found=0
    if ! command -v "$NFT_BIN" >/dev/null 2>&1; then
        ts_detect_art nft_table "nft tables" "unavailable"
        return 0
    fi
    out=$("$NFT_BIN" list tables 2>&1) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        if [[ "$EUID" -ne 0 ]] || [[ "$out" == *"Operation not permitted"* ]]; then
            ts_detect_art nft_table "nft tables" "permission_denied" "listing tables needs root"
        else
            ts_detect_art nft_table "nft tables" "error"
        fi
        return 0
    fi
    while IFS= read -r line; do
        if [[ "$line" =~ ^table[[:space:]]+(ip|ip6|inet)[[:space:]]+(tunnelsats[A-Za-z0-9_.-]*)[[:space:]]*$ ]]; then
            found=1
            ts_detect_art nft_table "nft table ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}" "present"
        fi
    done < <(printf '%s\n' "$out")
    if [[ "$found" -eq 0 ]]; then
        ts_detect_art nft_table "nft table tunnelsats*" "absent"
    fi
}

ts_detect_wg_links() {
    local out="" rc=0 line found=0
    if ! command -v "$IP_BIN" >/dev/null 2>&1; then
        ts_detect_art wg_interface "wireguard link tunnelsats*" "unavailable"
        return 0
    fi
    out=$("$IP_BIN" -o link show type wireguard 2>/dev/null) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        ts_detect_art wg_interface "wireguard link tunnelsats*" "error"
        return 0
    fi
    while IFS= read -r line; do
        if [[ "$line" =~ ^[0-9]+:[[:space:]]+(tunnelsats[A-Za-z0-9_.=+-]*)[:@] ]]; then
            found=1
            ts_detect_art wg_interface "wireguard link ${BASH_REMATCH[1]}" "present"
        fi
    done < <(printf '%s\n' "$out")
    if [[ "$found" -eq 0 ]]; then
        ts_detect_art wg_interface "wireguard link tunnelsats*" "absent"
    fi
}

# Routes in table 51820, judged with the route guard's own filter (ts_table51820_filter_foreign):
# the kill-switch blackhole and routes via the selected TunnelSats interface are owned, everything
# else is foreign.
ts_detect_table51820() {
    local out="" rc=0 line owned=0 iface="" foreign="" total=0
    TSD_T51820_FOREIGN=()
    # Ownership follows the route guard: only the interface of the selected config (the same rule
    # as status and restart) and the kill-switch blackhole are TunnelSats routes. Without any
    # config, the interface a fresh install creates (tunnelsatsv2) is the one the guard would check.
    ts_select_wg_config "" "$TS_FS_ROOT" "/etc/wireguard"
    case "$TS_WG_SELECTION" in
        canonical|single)
            iface="${TS_WG_SELECTED##*/}"
            iface="${iface%.conf}"
            ;;
        none) iface="tunnelsatsv2" ;;
        *) iface="" ;;
    esac
    TSD_IFACES=" ${iface} "
    if ! command -v "$IP_BIN" >/dev/null 2>&1; then
        TSD_T51820_STATUS="unavailable"
        ts_detect_art table_51820_route "ip -4 route table 51820" "unavailable"
        return 0
    fi
    out=$("$IP_BIN" route show table 51820 2>&1) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        if [[ "$out" != *"FIB table does not exist"* ]]; then
            TSD_T51820_STATUS="error"
            ts_detect_art table_51820_route "ip -4 route table 51820" "error"
            return 0
        fi
        out=""
    fi
    while IFS= read -r line; do
        if [[ -n "${line//[[:space:]]/}" ]]; then
            total=$((total + 1))
        fi
    done < <(printf '%s\n' "$out")
    foreign=$(printf '%s\n' "$out" | ts_table51820_filter_foreign "$iface")
    while IFS= read -r line; do
        if [[ -n "${line//[[:space:]]/}" ]]; then
            TSD_T51820_FOREIGN+=("$line")
        fi
    done < <(printf '%s\n' "$foreign")
    owned=$((total - ${#TSD_T51820_FOREIGN[@]}))
    if [[ -z "$iface" ]] && [[ "${#TSD_T51820_FOREIGN[@]}" -gt 0 ]]; then
        # Several configs (or an unreadable directory): which tunnel owns these routes cannot be
        # decided, so the conflict check reports unknown instead of guessing either way
        TSD_T51820_STATUS="selection_${TS_WG_SELECTION}"
        TSD_T51820_FOREIGN=()
    else
        TSD_T51820_STATUS="ok"
    fi
    if [[ "$owned" -gt 0 ]]; then
        ts_detect_art table_51820_route "ip -4 route table 51820" "present" "${owned} route(s) via TunnelSats"
    else
        ts_detect_art table_51820_route "ip -4 route table 51820" "absent"
    fi
}

ts_detect_artifacts() {
    local wg="/etc/wireguard" sd="/etc/systemd/system" name unit
    # WireGuard configs and the sanitizer's backups hold the private key
    ts_detect_art_path wg_config "${wg}/tunnelsatsv2.conf" 1
    ts_detect_art_glob wg_config "$wg" "tunnelsats-*.conf" 1
    ts_detect_art_glob wg_config_backup "$wg" "tunnelsats*.conf.bak.*" 1
    # Route guard (since #204), helper scripts and state files
    ts_detect_art_path route_guard_script "${wg}/tunnelsats-route-guard.sh"
    for name in tunnelsats-create-cgroup.sh tunnelsats-splitting-processes.sh tunnelsats-resolve-dns-wg.sh tunnelsats-docker-network.sh; do
        ts_detect_art_path helper_script "${wg}/${name}"
    done
    ts_detect_art_path failclosed_state "${wg}/.tunnelsats-failclosed-rules"
    ts_detect_art_glob ufw_marker "$wg" ".tunnelsats-ufw-9735-*.created"
    # systemd units, timers and drop-ins
    for unit in tunnelsats-create-cgroup.service tunnelsats-splitting-processes.service \
        tunnelsats-splitting-processes.timer tunnelsats-resolve-dns-wg.service \
        tunnelsats-resolve-dns-wg.timer tunnelsats-docker-network.service tunnelsats-docker-network.timer; do
        ts_detect_art_path unit "${sd}/${unit}"
    done
    ts_detect_art_glob wg_quick_enabled "${sd}/multi-user.target.wants" "wg-quick@tunnelsats*.service"
    ts_detect_art_glob wg_quick_dropin "$sd" "wg-quick@tunnelsats*.service.d"
    for unit in lnd.service lightningd.service litd.service lit.service; do
        ts_detect_ln_dropin "${sd}/${unit}.d/tunnelsats-cgroup.conf"
        ts_detect_ln_unit_edits "${sd}/${unit}"
        ts_detect_art_path ln_unit_backup "${sd}/${unit}.bak"
    done
    ts_detect_art_path blitzapi_dropin "${sd}/blitzapi.service.d/tunnelsats-wg.conf"
    ts_detect_art_path umbrel_killswitch_dropin "${sd}/umbrel.service.d/tunnelsats_killswitch.conf"
    ts_detect_art_path umbrel_killswitch_dropin "${sd}/umbrel-startup.service.d/tunnelsats_killswitch.conf"
    # Left behind by the v2 installer
    ts_detect_art_path raspiblitz_check_renamed "/home/admin/config.scripts/lnd.check.bak"
    ts_detect_art_path raspiblitz_check_renamed "/home/admin/config.scripts/cl.check.bak"
    ts_detect_art_path nftables_conf_backup "/etc/nftablespriortunnelsats.backup"
    # Kernel state (read-only queries)
    ts_detect_ip_rules
    ts_detect_nft_tables
    ts_detect_wg_links
    ts_detect_table51820
}

# Splits WireGuard Endpoint $1 into TSD_CFG_EP_HOST and TSD_CFG_EP_PORT; fails if it is invalid.
ts_detect_parse_endpoint() {
    local ep="$1" host="" port=""
    local re_v6='^\[([0-9A-Fa-f:.]+)\]:([0-9]{1,5})$'
    local re_host='^([A-Za-z0-9.-]{1,253}):([0-9]{1,5})$'
    local re_name='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'
    if [[ "$ep" =~ $re_v6 ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    elif [[ "$ep" =~ $re_host ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        if [[ ! "$host" =~ $re_name ]]; then
            return 1
        fi
    else
        return 1
    fi
    if (( 10#$port < 1 || 10#$port > 65535 )); then
        return 1
    fi
    TSD_CFG_EP_HOST="$host"
    TSD_CFG_EP_PORT="$((10#$port))"
    return 0
}

# Facts from the WireGuard config in use. The private key is read into memory only to derive
# the public key and is never printed.
ts_detect_config() {
    local i rel="" full line trimmed section="" key val privkey="" endpoint="" pub="" comment="" valid=""
    local re_iso='^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,9})?)?)?(Z|[+-][0-9]{2}(:?[0-9]{2})?)?$'
    TSD_CFG_PATH=""
    TSD_CFG_STATUS="absent"
    TSD_CFG_IFACE=""
    TSD_CFG_MARKER=""
    TSD_CFG_MARKERS=0
    TSD_CFG_EP_HOST=""
    TSD_CFG_EP_PORT=""
    TSD_CFG_EP_STATUS="not_read"
    TSD_CFG_VPN_PORT=""
    TSD_CFG_VPN_PORT_STATUS="not_read"
    TSD_CFG_PUB=""
    TSD_CFG_PUB_STATUS="not_read"
    TSD_CFG_PUB_COMMENT=""
    TSD_CFG_PUB_COMMENT_STATUS="not_read"
    TSD_CFG_PUB_MATCH=""
    TSD_CFG_VALID_UNTIL=""
    TSD_CFG_VALID_UNTIL_STATUS="not_read"
    TSD_CFG_HOOK_GUARD="not_read"
    TSD_CFG_HOOK_KILLSWITCH="not_read"

    # The config in use: the same rule as status, restart and uninstall (ts_select_wg_config).
    # Several tunnelsats-*.conf without tunnelsatsv2.conf are ambiguous: no facts are read then.
    ts_select_wg_config "" "$TS_FS_ROOT" "/etc/wireguard"
    TSD_CFG_SELECTION="$TS_WG_SELECTION"
    TSD_CFG_CANDIDATES=("${TS_WG_CANDIDATES[@]}")
    case "$TS_WG_SELECTION" in
        canonical|single) rel="$TS_WG_SELECTED" ;;
        ambiguous)
            TSD_CFG_STATUS="ambiguous"
            return 0
            ;;
        permission_denied)
            TSD_CFG_STATUS="permission_denied"
            return 0
            ;;
        *) return 0 ;;
    esac
    TSD_CFG_PATH="$rel"
    TSD_CFG_IFACE="${rel##*/}"
    TSD_CFG_IFACE="${TSD_CFG_IFACE%.conf}"
    ts_detect_read_status "$rel"
    if [[ "$TSD_ST" != "readable" ]]; then
        TSD_CFG_STATUS="$TSD_ST"
        return 0
    fi
    TSD_CFG_STATUS="ok"
    full="${TS_FS_ROOT}${rel}"
    TSD_CFG_HOOK_GUARD="absent"
    TSD_CFG_HOOK_KILLSWITCH="none"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        case "$line" in
            "#Tunnelsats-Setupv2-Non-Docker"*|"#Tunnelsats-Setupv2-Docker"*)
                TSD_CFG_MARKERS=$((TSD_CFG_MARKERS + 1))
                if [[ -z "$TSD_CFG_MARKER" ]] && [[ "$line" == "#Tunnelsats-Setupv2-Docker"* ]]; then
                    TSD_CFG_MARKER="docker"
                elif [[ -z "$TSD_CFG_MARKER" ]]; then
                    TSD_CFG_MARKER="non_docker"
                fi
                ;;
        esac
        trimmed="${line#"${line%%[![:space:]]*}"}"
        if [[ "$trimmed" =~ ^\[([A-Za-z]+)\] ]]; then
            section="${BASH_REMATCH[1],,}"
            continue
        fi
        if [[ ! "$trimmed" =~ ^([A-Za-z]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            continue
        fi
        key="${BASH_REMATCH[1],,}"
        val="${BASH_REMATCH[2]}"
        case "$key" in
            privatekey)
                if [[ "$section" == "interface" ]] && [[ -z "$privkey" ]]; then
                    privkey="${val%%[[:space:]#]*}"
                fi
                ;;
            endpoint)
                if [[ "$section" == "peer" ]] && [[ -z "$endpoint" ]]; then
                    endpoint="${val%%[[:space:]#]*}"
                fi
                ;;
            postup)
                if [[ "$val" == *"tunnelsats-route-guard.sh"* ]]; then
                    TSD_CFG_HOOK_GUARD="present"
                fi
                if [[ "$val" == *"skuid"* ]]; then
                    if [[ "$val" == *"meta cgroup 1118498"* ]]; then
                        TSD_CFG_HOOK_KILLSWITCH="skuid_cgroup"
                    elif [[ "$TSD_CFG_HOOK_KILLSWITCH" != "skuid_cgroup" ]]; then
                        TSD_CFG_HOOK_KILLSWITCH="skuid_only"
                    fi
                fi
                ;;
        esac
    done < "$full"

    if [[ -z "$endpoint" ]]; then
        TSD_CFG_EP_STATUS="missing"
    elif ts_detect_parse_endpoint "$endpoint"; then
        TSD_CFG_EP_STATUS="ok"
    else
        TSD_CFG_EP_STATUS="invalid"
    fi

    # Forwarded VPN port from "# Port Forwarding: N" (or "#VPNPort = N"). The complete value is
    # checked: 100000 is invalid (not 10000) and 80 is valid (not missing).
    TSD_CFG_VPN_PORT=$(parse_config_metadata "$full" port) || TSD_CFG_VPN_PORT=""
    if [[ -z "$TSD_CFG_VPN_PORT" ]]; then
        TSD_CFG_VPN_PORT_STATUS="missing"
    elif TSD_CFG_VPN_PORT=$(ts_normalize_port "$TSD_CFG_VPN_PORT"); then
        TSD_CFG_VPN_PORT_STATUS="ok"
    else
        TSD_CFG_VPN_PORT=""
        TSD_CFG_VPN_PORT_STATUS="invalid"
    fi

    # Public key in use: derived from PrivateKey, never taken from a comment
    if [[ -z "$privkey" ]]; then
        TSD_CFG_PUB_STATUS="no_private_key"
    elif ! ts_valid_wg_key "$privkey"; then
        TSD_CFG_PUB_STATUS="invalid_private_key"
    elif ! command -v "$WG_BIN" >/dev/null 2>&1; then
        TSD_CFG_PUB_STATUS="wg_unavailable"
    elif pub=$(ts_derive_wg_pubkey "$privkey"); then
        TSD_CFG_PUB="$pub"
        TSD_CFG_PUB_STATUS="derived"
    else
        TSD_CFG_PUB_STATUS="derive_failed"
    fi
    privkey=""

    # The myPubKey comment is only a hint and can be stale
    comment=$(parse_config_metadata "$full" pubkey) || comment=""
    if [[ -z "$comment" ]]; then
        TSD_CFG_PUB_COMMENT_STATUS="missing"
    elif ts_valid_wg_key "$comment"; then
        TSD_CFG_PUB_COMMENT="$comment"
        TSD_CFG_PUB_COMMENT_STATUS="ok"
        if [[ -n "$TSD_CFG_PUB" ]] && [[ "$TSD_CFG_PUB" == "$comment" ]]; then
            TSD_CFG_PUB_MATCH="true"
        elif [[ -n "$TSD_CFG_PUB" ]]; then
            TSD_CFG_PUB_MATCH="false"
        fi
    else
        TSD_CFG_PUB_COMMENT_STATUS="invalid"
    fi

    # Valid Until is a display hint; the TunnelSats API is the source of truth
    valid=$(parse_config_metadata "$full" expiry) || valid=""
    if [[ -z "$valid" ]]; then
        TSD_CFG_VALID_UNTIL_STATUS="missing"
    elif [[ "$valid" =~ $re_iso ]]; then
        TSD_CFG_VALID_UNTIL="$valid"
        TSD_CFG_VALID_UNTIL_STATUS="ok"
    else
        TSD_CFG_VALID_UNTIL_STATUS="invalid"
    fi
}

# Classifies the existing install (R2 7.5). The newest generation with positive evidence wins:
# legacy_v3_post_204 (route guard, #204), legacy_v3_pre_204, legacy_v2. "unknown" lists the
# kinds the readable evidence cannot tell apart; "none" requires that nothing was unreadable.
ts_detect_install_kind() {
    local i id status detail any_present=0 any_unreadable=0 v2=0 v3=0 pre=0 post=0
    TSD_EVIDENCE=()
    for i in "${!TSD_ART_ID[@]}"; do
        id="${TSD_ART_ID[$i]}"
        status="${TSD_ART_STATUS[$i]}"
        detail="${TSD_ART_DETAIL[$i]}"
        case "$status" in
            present) any_present=1 ;;
            permission_denied|error) any_unreadable=1; continue ;;
            *) continue ;;
        esac
        case "$id" in
            raspiblitz_check_renamed) v2=1; ts_detect_evidence v2_check_script_renamed ;;
            umbrel_killswitch_dropin) v2=1; ts_detect_evidence v2_umbrel_killswitch ;;
            nftables_conf_backup) v2=1; ts_detect_evidence v2_nftables_conf_backup ;;
            ln_dropin)
                if [[ "$detail" == "requires" ]]; then
                    v2=1
                    ts_detect_evidence v2_dropin_requires
                elif [[ "$detail" == "wants" ]]; then
                    v3=1
                    ts_detect_evidence v3_dropin_wants
                fi
                ;;
            ln_unit_check_disabled) v3=1; ts_detect_evidence v3_check_disabled_in_unit ;;
            ufw_marker) v3=1; ts_detect_evidence v3_ufw_marker ;;
            route_guard_script) post=1; ts_detect_evidence route_guard_script ;;
            wg_config_backup) post=1; ts_detect_evidence config_backup_copies ;;
            failclosed_state|failclosed_rules) post=1; ts_detect_evidence failclosed_block ;;
            ip_rule) post=1; ts_detect_evidence rule_priorities_21820_21821 ;;
            ip_rule_legacy) pre=1; ts_detect_evidence legacy_rule_selectors ;;
            nft_table)
                if [[ "${TSD_ART_LOC[$i]}" == *"tunnelsats_failclosed"* ]]; then
                    post=1
                    ts_detect_evidence failclosed_block
                fi
                ;;
        esac
    done
    if [[ "$TSD_CFG_STATUS" == "ok" ]]; then
        if [[ "$TSD_CFG_HOOK_KILLSWITCH" == "skuid_only" ]]; then
            v2=1
            ts_detect_evidence v2_killswitch_uid_only
        elif [[ "$TSD_CFG_HOOK_KILLSWITCH" == "skuid_cgroup" ]]; then
            v3=1
            ts_detect_evidence v3_killswitch_uid_cgroup
        fi
        if [[ "$TSD_CFG_HOOK_GUARD" == "present" ]]; then
            post=1
            ts_detect_evidence route_guard_hook
        elif [[ -n "$TSD_CFG_MARKER" ]]; then
            pre=1
            ts_detect_evidence config_without_route_guard
        fi
    fi

    if [[ "$post" -eq 1 ]]; then
        TSD_INSTALL_KIND="legacy_v3_post_204"
        TSD_INSTALL_CANDIDATES=(legacy_v3_post_204)
    elif [[ "$v3" -eq 1 ]] && [[ "$pre" -eq 1 ]]; then
        TSD_INSTALL_KIND="legacy_v3_pre_204"
        TSD_INSTALL_CANDIDATES=(legacy_v3_pre_204)
    elif [[ "$v3" -eq 1 ]]; then
        TSD_INSTALL_KIND="unknown"
        TSD_INSTALL_CANDIDATES=(legacy_v3_pre_204 legacy_v3_post_204)
    elif [[ "$v2" -eq 1 ]]; then
        TSD_INSTALL_KIND="legacy_v2"
        TSD_INSTALL_CANDIDATES=(legacy_v2)
    elif [[ "$pre" -eq 1 ]]; then
        TSD_INSTALL_KIND="unknown"
        TSD_INSTALL_CANDIDATES=(legacy_v2 legacy_v3_pre_204)
    elif [[ "$any_present" -eq 1 ]]; then
        TSD_INSTALL_KIND="unknown"
        TSD_INSTALL_CANDIDATES=(legacy_v2 legacy_v3_pre_204 legacy_v3_post_204)
    elif [[ "$any_unreadable" -eq 1 ]]; then
        TSD_INSTALL_KIND="unknown"
        TSD_INSTALL_CANDIDATES=(none legacy_v2 legacy_v3_pre_204 legacy_v3_post_204)
    else
        TSD_INSTALL_KIND="none"
        TSD_INSTALL_CANDIDATES=(none)
    fi
}

ts_detect_capabilities() {
    local out="" path dev mountpoint fstype options rest
    TSD_CAP_WG="missing"
    TSD_CAP_WG_VERSION=""
    TSD_CAP_WG_QUICK="missing"
    TSD_CAP_WG_UNIT="absent"
    TSD_CAP_NFT="missing"
    TSD_CAP_NFT_VERSION=""
    TSD_CAP_SYSTEMD="missing"
    TSD_CAP_SYSTEMD_VERSION=""
    TSD_CAP_CG2="unknown"
    TSD_CAP_CG2_MP=""
    TSD_CAP_NETCLS="unknown"
    TSD_CAP_NETCLS_MP=""
    TSD_CAP_KERNEL=""
    if command -v "$WG_BIN" >/dev/null 2>&1; then
        TSD_CAP_WG="present"
        out=$("$WG_BIN" --version 2>/dev/null) || out=""
        if [[ "$out" =~ v([0-9]+(\.[0-9]+)+) ]]; then
            TSD_CAP_WG_VERSION="${BASH_REMATCH[1]}"
        fi
    fi
    if command -v "$WG_QUICK_BIN" >/dev/null 2>&1; then
        TSD_CAP_WG_QUICK="present"
    fi
    for path in /lib/systemd/system/wg-quick@.service /usr/lib/systemd/system/wg-quick@.service /etc/systemd/system/wg-quick@.service; do
        ts_detect_path_status "$path"
        if [[ "$TSD_ST" == "present" ]]; then
            TSD_CAP_WG_UNIT="present"
            break
        fi
        if [[ "$TSD_ST" == "permission_denied" ]]; then
            TSD_CAP_WG_UNIT="permission_denied"
        fi
    done
    if command -v "$NFT_BIN" >/dev/null 2>&1; then
        TSD_CAP_NFT="present"
        out=$("$NFT_BIN" --version 2>/dev/null) || out=""
        if [[ "$out" =~ v([0-9]+(\.[0-9]+)+) ]]; then
            TSD_CAP_NFT_VERSION="${BASH_REMATCH[1]}"
        fi
    fi
    if command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1; then
        TSD_CAP_SYSTEMD="present"
        out=$("$SYSTEMCTL_BIN" --version 2>/dev/null) || out=""
        if [[ "$out" =~ ^systemd[[:space:]]+([0-9]+) ]]; then
            TSD_CAP_SYSTEMD_VERSION="${BASH_REMATCH[1]}"
        fi
    fi
    # cgroup hierarchies from the mount table (no cgroup is created or modified)
    if [[ -r "${TS_FS_ROOT}/proc/mounts" ]]; then
        TSD_CAP_CG2="not_mounted"
        TSD_CAP_NETCLS="not_mounted"
        while read -r dev mountpoint fstype options rest; do
            if [[ "$fstype" == "cgroup2" ]] && [[ -z "$TSD_CAP_CG2_MP" ]]; then
                TSD_CAP_CG2="mounted"
                TSD_CAP_CG2_MP="$mountpoint"
            elif [[ "$fstype" == "cgroup" ]] && [[ ",${options}," == *",net_cls,"* ]] && [[ -z "$TSD_CAP_NETCLS_MP" ]]; then
                TSD_CAP_NETCLS="mounted"
                TSD_CAP_NETCLS_MP="$mountpoint"
            fi
        done < "${TS_FS_ROOT}/proc/mounts"
    fi
    out=$(uname -r 2>/dev/null) || out=""
    if [[ "$out" =~ ^[A-Za-z0-9._+~-]{1,64}$ ]]; then
        TSD_CAP_KERNEL="$out"
    fi
}

ts_detect_conflicts() {
    local out="" rc=0 line i impls="" units="" unreadable="" count=0 file="" value="" lines="" blitz_conf_st=""
    local re_port="^[[:space:]]*lndPort=[\"']?([0-9]+)[\"']?[[:space:]]*\$"

    # Routes in table 51820 that TunnelSats does not own: install and the route guard refuse to start
    local t51820_iface="${TSD_IFACES// /}"
    if [[ "$TSD_T51820_STATUS" == "ok" ]] && [[ "${#TSD_T51820_FOREIGN[@]}" -gt 0 ]]; then
        ts_detect_conflict table_51820_foreign_routes detected "${#TSD_T51820_FOREIGN[@]} route(s) not via ${t51820_iface}, first: ${TSD_T51820_FOREIGN[0]}"
    elif [[ "$TSD_T51820_STATUS" == "ok" ]]; then
        ts_detect_conflict table_51820_foreign_routes not_detected "${t51820_iface:+judged against ${t51820_iface}}${t51820_iface:-no routes besides the kill-switch blackhole}"
    elif [[ "$TSD_T51820_STATUS" == selection_* ]]; then
        ts_detect_conflict table_51820_foreign_routes unknown "config selection ${TSD_T51820_STATUS#selection_}: the owning interface cannot be decided"
    else
        ts_detect_conflict table_51820_foreign_routes unknown "$TSD_T51820_STATUS"
    fi

    # Tailscale exit node: its default route in table 52 is looked up before the TunnelSats rules
    if ! command -v "$IP_BIN" >/dev/null 2>&1; then
        ts_detect_conflict tailscale_exit_node unknown "unavailable"
    else
        out=$("$IP_BIN" route show table 52 2>&1) || rc=$?
        if [[ "$rc" -ne 0 ]] && [[ "$out" != *"FIB table does not exist"* ]]; then
            ts_detect_conflict tailscale_exit_node unknown "error"
        elif [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -qE '^(default|0\.0\.0\.0/0)[[:space:]]'; then
            ts_detect_conflict tailscale_exit_node detected "default route in table 52"
        else
            ts_detect_conflict tailscale_exit_node not_detected
        fi
    fi

    # nftables.service enabled: its boot-time ruleset load can flush the TunnelSats tables
    ts_detect_path_status "/etc/systemd/system/sysinit.target.wants/nftables.service"
    case "$TSD_ST" in
        present)
            out="nftables.service is enabled"
            ts_detect_read_status "/etc/nftables.conf"
            if [[ "$TSD_ST" == "readable" ]] && grep -qE '^[[:space:]]*flush[[:space:]]+ruleset' "${TS_FS_ROOT}/etc/nftables.conf" 2>/dev/null; then
                out+="; /etc/nftables.conf flushes the whole ruleset"
            fi
            ts_detect_conflict nftables_service_enabled detected "$out"
            ;;
        absent) ts_detect_conflict nftables_service_enabled not_detected ;;
        *) ts_detect_conflict nftables_service_enabled unknown "$TSD_ST" ;;
    esac

    # More than one Lightning implementation: only one can receive the forwarded port 9735. An
    # implementation counts if its unit file exists in any unit directory or if its unit runs
    # (packaged units live under /usr/lib/systemd/system, generated units have no file at all).
    # A masked unit (file status masked) cannot start, so it only counts while it still runs.
    for i in "${!TSD_LN_UNIT[@]}"; do
        if [[ "${TSD_LN_FILE[$i]}" == "present" ]] || ts_detect_unit_running "${TSD_LN_ACTIVE[$i]}"; then
            units+="${units:+, }${TSD_LN_UNIT[$i]} (${TSD_LN_ACTIVE[$i]})"
            if [[ "$impls" != *" ${TSD_LN_IMPL[$i]} "* ]]; then
                impls+=" ${TSD_LN_IMPL[$i]} "
                count=$((count + 1))
            fi
        elif [[ "${TSD_LN_FILE[$i]}" == "permission_denied" ]]; then
            unreadable+="${unreadable:+, }${TSD_LN_UNIT[$i]}"
        fi
    done
    if [[ "$count" -gt 1 ]]; then
        ts_detect_conflict multiple_ln_implementations detected "$units"
    elif [[ -n "$unreadable" ]]; then
        # A stopped implementation could be installed in a unit directory that cannot be read
        ts_detect_conflict multiple_ln_implementations unknown "unit file location not readable: ${unreadable}"
    else
        ts_detect_conflict multiple_ln_implementations not_detected "$units"
    fi

    # RaspiBlitz: a custom lndPort moves LND away from 9735, where the server forwards to
    for file in /mnt/hdd/app-data/raspiblitz.conf /mnt/hdd/raspiblitz.conf; do
        ts_detect_read_status "$file"
        if [[ "$TSD_ST" != "absent" ]]; then
            break
        fi
    done
    blitz_conf_st="$TSD_ST"
    case "$TSD_ST" in
        absent)
            # raspiblitz.conf lives on the data drive, which may not be mounted (yet)
            if [[ "$TSD_PLATFORM_GUESS" == "raspiblitz" ]]; then
                ts_detect_conflict raspiblitz_custom_lnd_port unknown "raspiblitz.conf not found"
            else
                ts_detect_conflict raspiblitz_custom_lnd_port not_applicable
            fi
            ;;
        readable)
            value=""
            while IFS= read -r line || [[ -n "$line" ]]; do
                if [[ "$line" =~ $re_port ]]; then
                    value="${BASH_REMATCH[1]}"
                fi
            done < "${TS_FS_ROOT}${file}"
            if [[ -n "$value" ]] && [[ "$value" != "9735" ]]; then
                ts_detect_conflict raspiblitz_custom_lnd_port detected "lndPort=${value}"
            else
                ts_detect_conflict raspiblitz_custom_lnd_port not_detected
            fi
            ;;
        *) ts_detect_conflict raspiblitz_custom_lnd_port unknown "$TSD_ST" ;;
    esac

    # RaspiBlitz: custom-installs.sh runs on every provisioning and may re-apply an old setup
    ts_detect_read_status "/mnt/hdd/app-data/custom-installs.sh"
    case "$TSD_ST" in
        absent)
            if [[ "$blitz_conf_st" != "absent" ]]; then
                ts_detect_conflict raspiblitz_custom_installs not_detected
            elif [[ "$TSD_PLATFORM_GUESS" == "raspiblitz" ]]; then
                ts_detect_conflict raspiblitz_custom_installs unknown "raspiblitz.conf not found"
            else
                ts_detect_conflict raspiblitz_custom_installs not_applicable
            fi
            ;;
        readable)
            lines=$(grep -niE 'tunnelsats' "${TS_FS_ROOT}/mnt/hdd/app-data/custom-installs.sh" 2>/dev/null | cut -d: -f1 | head -n 20 | tr '\n' ',') || lines=""
            lines="${lines%,}"
            if [[ -n "$lines" ]]; then
                ts_detect_conflict raspiblitz_custom_installs detected "lines ${lines}"
            else
                ts_detect_conflict raspiblitz_custom_installs not_detected
            fi
            ;;
        *) ts_detect_conflict raspiblitz_custom_installs unknown "$TSD_ST" ;;
    esac
}

ts_detect_render_json() {
    local i privileged="false" platform_j ln_j arts_j cand_j ev_j install_j config_j caps_j conf_j
    local ep_j port_j pub_j comment_j valid_j hooks_j wg_j nft_j sd_j cg2_j netcls_j cand_cfg_j
    local -a items=()
    if [[ "$EUID" -eq 0 ]]; then
        privileged="true"
    fi

    for i in "${!TSD_HINT_PLATFORM[@]}"; do
        ts_j_obj s:platform "${TSD_HINT_PLATFORM[$i]}" s:path "${TSD_HINT_PATH[$i]}" s:status "${TSD_HINT_STATUS[$i]}"
        items+=("$TS_R")
    done
    ts_j_arr "${items[@]}"
    ts_j_obj sn:guess "$TSD_PLATFORM_GUESS" r:evidence "$TS_R"
    platform_j="$TS_R"

    items=()
    for i in "${!TSD_LN_IMPL[@]}"; do
        ts_j_obj s:impl "${TSD_LN_IMPL[$i]}" s:unit "${TSD_LN_UNIT[$i]}" s:file "${TSD_LN_FILE[$i]}" sn:path "${TSD_LN_PATH[$i]}" s:active "${TSD_LN_ACTIVE[$i]}" sn:user "${TSD_LN_USER[$i]}"
        items+=("$TS_R")
    done
    ts_j_arr "${items[@]}"
    ts_j_obj sn:guess "$TSD_LN_GUESS" r:units "$TS_R"
    ln_j="$TS_R"

    items=()
    for i in "${!TSD_ART_ID[@]}"; do
        ts_j_obj s:id "${TSD_ART_ID[$i]}" s:location "${TSD_ART_LOC[$i]}" s:status "${TSD_ART_STATUS[$i]}" sn:detail "${TSD_ART_DETAIL[$i]}" b:contains_secrets "${TSD_ART_SECRET[$i]}"
        items+=("$TS_R")
    done
    ts_j_arr "${items[@]}"
    arts_j="$TS_R"
    items=()
    for i in "${TSD_INSTALL_CANDIDATES[@]}"; do
        ts_j_str "$i"
        items+=("$TS_R")
    done
    ts_j_arr "${items[@]}"
    cand_j="$TS_R"
    items=()
    for i in "${TSD_EVIDENCE[@]}"; do
        ts_j_str "$i"
        items+=("$TS_R")
    done
    ts_j_arr "${items[@]}"
    ev_j="$TS_R"
    ts_j_obj s:kind "$TSD_INSTALL_KIND" r:candidates "$cand_j" r:evidence "$ev_j" r:artifacts "$arts_j"
    install_j="$TS_R"

    ts_j_obj sn:host "$TSD_CFG_EP_HOST" i:port "$TSD_CFG_EP_PORT" s:status "$TSD_CFG_EP_STATUS"
    ep_j="$TS_R"
    ts_j_obj i:value "$TSD_CFG_VPN_PORT" s:status "$TSD_CFG_VPN_PORT_STATUS"
    port_j="$TS_R"
    ts_j_obj sn:value "$TSD_CFG_PUB" s:status "$TSD_CFG_PUB_STATUS" s:source "private_key"
    pub_j="$TS_R"
    ts_j_obj sn:value "$TSD_CFG_PUB_COMMENT" s:status "$TSD_CFG_PUB_COMMENT_STATUS" b:matches_derived "$TSD_CFG_PUB_MATCH"
    comment_j="$TS_R"
    ts_j_obj sn:value "$TSD_CFG_VALID_UNTIL" s:status "$TSD_CFG_VALID_UNTIL_STATUS"
    valid_j="$TS_R"
    ts_j_obj s:route_guard "$TSD_CFG_HOOK_GUARD" s:killswitch "$TSD_CFG_HOOK_KILLSWITCH"
    hooks_j="$TS_R"
    items=()
    for i in "${TSD_CFG_CANDIDATES[@]}"; do
        ts_j_str "$i"
        items+=("$TS_R")
    done
    ts_j_arr "${items[@]}"
    cand_cfg_j="$TS_R"
    ts_j_obj sn:path "$TSD_CFG_PATH" s:status "$TSD_CFG_STATUS" s:selection "$TSD_CFG_SELECTION" r:candidates "$cand_cfg_j" \
        sn:interface "$TSD_CFG_IFACE" sn:marker "$TSD_CFG_MARKER" \
        i:marker_count "$TSD_CFG_MARKERS" r:endpoint "$ep_j" r:vpn_port "$port_j" r:public_key "$pub_j" \
        r:public_key_comment "$comment_j" r:valid_until "$valid_j" r:hooks "$hooks_j"
    config_j="$TS_R"

    ts_j_obj s:status "$TSD_CAP_WG" sn:version "$TSD_CAP_WG_VERSION" s:wg_quick "$TSD_CAP_WG_QUICK" s:wg_quick_unit "$TSD_CAP_WG_UNIT"
    wg_j="$TS_R"
    ts_j_obj s:status "$TSD_CAP_NFT" sn:version "$TSD_CAP_NFT_VERSION"
    nft_j="$TS_R"
    ts_j_obj s:status "$TSD_CAP_SYSTEMD" i:version "$TSD_CAP_SYSTEMD_VERSION"
    sd_j="$TS_R"
    ts_j_obj s:status "$TSD_CAP_CG2" sn:mountpoint "$TSD_CAP_CG2_MP"
    cg2_j="$TS_R"
    ts_j_obj s:status "$TSD_CAP_NETCLS" sn:mountpoint "$TSD_CAP_NETCLS_MP"
    netcls_j="$TS_R"
    ts_j_obj r:wireguard_tools "$wg_j" r:nft "$nft_j" r:systemd "$sd_j" r:cgroup_v2 "$cg2_j" r:net_cls_v1 "$netcls_j" sn:kernel_release "$TSD_CAP_KERNEL"
    caps_j="$TS_R"

    items=()
    for i in "${!TSD_CONF_ID[@]}"; do
        ts_j_obj s:id "${TSD_CONF_ID[$i]}" s:status "${TSD_CONF_STATUS[$i]}" sn:detail "${TSD_CONF_DETAIL[$i]}"
        items+=("$TS_R")
    done
    ts_j_arr "${items[@]}"
    conf_j="$TS_R"

    ts_json_document 0 "[]" "\"privileged\":${privileged},\"unreadable_items\":${TSD_UNREADABLE},\"platform\":${platform_j},\"lightning\":${ln_j},\"install\":${install_j},\"config\":${config_j},\"capabilities\":${caps_j},\"conflicts\":${conf_j}"
}

ts_detect_render_human() {
    local i shown
    print_header "Detect (read-only)"
    echo -e "${BOLD}Platform${NC}"
    print_line
    echo "  Guess:            ${TSD_PLATFORM_GUESS:-none}"
    for i in "${!TSD_HINT_PLATFORM[@]}"; do
        if [[ "${TSD_HINT_STATUS[$i]}" != "absent" ]]; then
            echo "  Evidence:         ${TSD_HINT_PATH[$i]} (${TSD_HINT_PLATFORM[$i]}, ${TSD_HINT_STATUS[$i]})"
        fi
    done
    echo ""
    echo -e "${BOLD}Lightning${NC}"
    print_line
    echo "  Guess:            ${TSD_LN_GUESS:-none}"
    for i in "${!TSD_LN_UNIT[@]}"; do
        if [[ "${TSD_LN_FILE[$i]}" != "absent" ]] || ts_detect_unit_running "${TSD_LN_ACTIVE[$i]}"; then
            echo "  ${TSD_LN_UNIT[$i]}: file ${TSD_LN_FILE[$i]}${TSD_LN_PATH[$i]:+ (${TSD_LN_PATH[$i]})}, ${TSD_LN_ACTIVE[$i]}${TSD_LN_USER[$i]:+, user ${TSD_LN_USER[$i]}}"
        fi
    done
    echo ""
    echo -e "${BOLD}Existing TunnelSats install${NC}"
    print_line
    echo "  Kind:             ${TSD_INSTALL_KIND}"
    if [[ "$TSD_INSTALL_KIND" == "unknown" ]]; then
        echo "  Candidates:       ${TSD_INSTALL_CANDIDATES[*]}"
    fi
    echo "  Evidence:         ${TSD_EVIDENCE[*]:-none}"
    for i in "${!TSD_ART_ID[@]}"; do
        if [[ "${TSD_ART_STATUS[$i]}" != "absent" ]]; then
            shown="${TSD_ART_LOC[$i]//[[:cntrl:]]/?}"
            printf '  %-18s %-26s %s%s\n' "${TSD_ART_STATUS[$i]}" "${TSD_ART_ID[$i]}" "$shown" "${TSD_ART_DETAIL[$i]:+ (${TSD_ART_DETAIL[$i]})}"
        fi
    done
    echo ""
    echo -e "${BOLD}WireGuard config${NC}"
    print_line
    if [[ "$TSD_CFG_STATUS" == "ok" ]]; then
        echo "  Path:             ${TSD_CFG_PATH} (interface ${TSD_CFG_IFACE}, marker ${TSD_CFG_MARKER:-none})"
        echo "  Endpoint:         ${TSD_CFG_EP_HOST:-?}${TSD_CFG_EP_PORT:+:${TSD_CFG_EP_PORT}} (${TSD_CFG_EP_STATUS})"
        echo "  VPN port:         ${TSD_CFG_VPN_PORT:-?} (${TSD_CFG_VPN_PORT_STATUS})"
        echo "  Public key:       ${TSD_CFG_PUB:-?} (${TSD_CFG_PUB_STATUS}, from PrivateKey)"
        echo "  Key comment:      ${TSD_CFG_PUB_COMMENT:-?} (${TSD_CFG_PUB_COMMENT_STATUS}${TSD_CFG_PUB_MATCH:+, matches derived key: ${TSD_CFG_PUB_MATCH}})"
        echo "  Valid until:      ${TSD_CFG_VALID_UNTIL:-?} (${TSD_CFG_VALID_UNTIL_STATUS}, hint only)"
    else
        echo "  Status:           ${TSD_CFG_STATUS}${TSD_CFG_PATH:+ (${TSD_CFG_PATH})}"
    fi
    echo "  Selection:        ${TSD_CFG_SELECTION}${TSD_CFG_CANDIDATES[0]:+ (candidates: ${TSD_CFG_CANDIDATES[*]})}"
    echo ""
    echo -e "${BOLD}Capabilities${NC}"
    print_line
    echo "  wireguard-tools:  ${TSD_CAP_WG}${TSD_CAP_WG_VERSION:+ ${TSD_CAP_WG_VERSION}} (wg-quick ${TSD_CAP_WG_QUICK}, unit template ${TSD_CAP_WG_UNIT})"
    echo "  nftables:         ${TSD_CAP_NFT}${TSD_CAP_NFT_VERSION:+ ${TSD_CAP_NFT_VERSION}}"
    echo "  systemd:          ${TSD_CAP_SYSTEMD}${TSD_CAP_SYSTEMD_VERSION:+ ${TSD_CAP_SYSTEMD_VERSION}}"
    echo "  cgroup v2:        ${TSD_CAP_CG2}${TSD_CAP_CG2_MP:+ (${TSD_CAP_CG2_MP})}"
    echo "  net_cls (v1):     ${TSD_CAP_NETCLS}${TSD_CAP_NETCLS_MP:+ (${TSD_CAP_NETCLS_MP})}"
    echo "  Kernel:           ${TSD_CAP_KERNEL:-unknown}"
    echo ""
    echo -e "${BOLD}Conflicts${NC}"
    print_line
    for i in "${!TSD_CONF_ID[@]}"; do
        shown="${TSD_CONF_DETAIL[$i]//[[:cntrl:]]/?}"
        echo "  ${TSD_CONF_ID[$i]}: ${TSD_CONF_STATUS[$i]}${shown:+ (${shown})}"
    done
    echo ""
    if [[ "$TSD_UNREADABLE" -gt 0 ]]; then
        print_warning "${TSD_UNREADABLE} item(s) could not be read. Run as root for a complete report."
    fi
}

cmd_detect() {
    local i
    TS_FS_ROOT="${TS_FS_ROOT%/}"
    ts_detect_platform
    ts_detect_lightning
    ts_detect_artifacts
    ts_detect_config
    ts_detect_install_kind
    ts_detect_capabilities
    ts_detect_conflicts
    # Items that could not be read: unreadable locations, plus files that exist but cannot be read
    TSD_UNREADABLE=0
    for i in "${!TSD_ART_STATUS[@]}"; do
        if [[ "${TSD_ART_STATUS[$i]}" == "permission_denied" ]] || [[ "${TSD_ART_STATUS[$i]}" == "error" ]] || \
            [[ "${TSD_ART_DETAIL[$i]}" == "unreadable" ]]; then
            TSD_UNREADABLE=$((TSD_UNREADABLE + 1))
        elif [[ "$TSD_CFG_STATUS" == "permission_denied" ]] && [[ "${TSD_ART_ID[$i]}" == "wg_config" ]] && \
            [[ "${TSD_ART_LOC[$i]}" == "$TSD_CFG_PATH" ]]; then
            TSD_UNREADABLE=$((TSD_UNREADABLE + 1))
        fi
    done
    if [[ "$TS_JSON" -eq 1 ]]; then
        ts_detect_render_json
    else
        ts_detect_render_human
    fi
    exit 0
}

# ---------------------------------------------------------------------------
# ARGUMENT PARSING
# Options are global: they are accepted before or after the command word.
# ---------------------------------------------------------------------------

# Prints the canonical name of command word $1 (aliases included), nothing if it is unknown.
ts_canonical_command() {
    case "$1" in
        install) echo "install" ;;
        pre-check|precheck|check) echo "pre-check" ;;
        uninstall|remove) echo "uninstall" ;;
        status) echo "status" ;;
        restart) echo "restart" ;;
        detect) echo "detect" ;;
        version) echo "version" ;;
        help) echo "help" ;;
    esac
    return 0
}

# Succeeds if option $2 applies to command $1.
ts_option_supported() {
    case "$2" in
        --non-interactive|--yes|--json) return 0 ;;
        --config) [[ "$1" == "install" || "$1" == "status" || "$1" == "restart" ]] ;;
        --platform|--impl) [[ "$1" == "install" || "$1" == "uninstall" || "$1" == "status" || "$1" == "restart" ]] ;;
        --remove-packages|--keep-packages) [[ "$1" == "uninstall" ]] ;;
        *) return 1 ;;
    esac
}

# Keeps the first usage problem found while parsing (reported by parse_args).
ts_usage_note() {
    if [[ -z "$TS_USAGE_ERROR" ]]; then
        TS_USAGE_ERROR="$1"
    fi
    return 0
}

# Parses the command line into the TS_* variables without printing or exiting.
ts_parse_cli() {
    local word="" opt value
    TS_ARGV=("$@")
    TS_COMMAND=""
    TS_JSON=0
    TS_NONINTERACTIVE=0
    TS_OPT_YES=0
    TS_OPT_PLATFORM=""
    TS_OPT_IMPL=""
    TS_OPT_PACKAGES=""
    TS_WANT_HELP=0
    TS_USAGE_ERROR=""
    TS_OPTS_GIVEN=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive)
                TS_NONINTERACTIVE=1
                TS_OPTS_GIVEN+=("$1")
                ;;
            --json)
                TS_JSON=1
                TS_OPTS_GIVEN+=("$1")
                ;;
            --yes)
                TS_OPT_YES=1
                TS_OPTS_GIVEN+=("$1")
                ;;
            --remove-packages|--keep-packages)
                value="${1#--}"
                value="${value%-packages}"
                if [[ -n "$TS_OPT_PACKAGES" ]] && [[ "$TS_OPT_PACKAGES" != "$value" ]]; then
                    ts_usage_note "--remove-packages and --keep-packages cannot be combined"
                fi
                TS_OPT_PACKAGES="$value"
                TS_OPTS_GIVEN+=("$1")
                ;;
            --config|--platform|--impl)
                opt="$1"
                if [[ $# -lt 2 ]] || [[ -z "$2" ]] || [[ "$2" == -* ]]; then
                    ts_usage_note "${opt} requires a value"
                    TS_OPTS_GIVEN+=("$opt")
                    shift
                    continue
                fi
                value="$2"
                if [[ " ${TS_OPTS_GIVEN[*]} " == *" ${opt} "* ]]; then
                    ts_usage_note "${opt} given more than once"
                fi
                case "$opt" in
                    --config) CONFIG_FILE="$value" ;;
                    --platform)
                        if ! ts_in_list "$value" "$TS_PLATFORMS"; then
                            ts_usage_note "Invalid --platform '${value}' (expected: ${TS_PLATFORMS// /, })"
                        fi
                        TS_OPT_PLATFORM="$value"
                        ;;
                    --impl)
                        if ! ts_in_list "$value" "$TS_IMPLS"; then
                            ts_usage_note "Invalid --impl '${value}' (expected: ${TS_IMPLS// /, })"
                        fi
                        TS_OPT_IMPL="$value"
                        ;;
                esac
                TS_OPTS_GIVEN+=("$opt")
                shift 2
                continue
                ;;
            -h|--help)
                TS_WANT_HELP=1
                ;;
            -*)
                ts_usage_note "Unknown option: $1"
                ;;
            *)
                if [[ -z "$word" ]]; then
                    word="$1"
                else
                    ts_usage_note "Unexpected argument: $1"
                fi
                ;;
        esac
        shift
    done
    if [[ "$TS_WANT_HELP" -eq 1 ]]; then
        word="help"
    fi
    if [[ -n "$word" ]]; then
        TS_COMMAND=$(ts_canonical_command "$word")
        if [[ -z "$TS_COMMAND" ]]; then
            ts_usage_note "Unknown command: ${word}"
            TS_COMMAND="$word"
        fi
    fi
    # A JSON consumer cannot answer prompts
    if [[ "$TS_JSON" -eq 1 ]]; then
        TS_NONINTERACTIVE=1
    fi
    return 0
}

# Rejects options the command does not use, and --json where it is not supported yet.
ts_validate_cli() {
    local opt
    for opt in "${TS_OPTS_GIVEN[@]}"; do
        if ! ts_option_supported "$TS_COMMAND" "$opt"; then
            ts_usage_error "${opt} is not supported by '${TS_COMMAND}'"
        fi
    done
    if [[ "$TS_JSON" -eq 1 ]] && [[ "$TS_COMMAND" != "version" ]] && [[ "$TS_COMMAND" != "detect" ]]; then
        ts_fail 2 E_JSON_UNSUPPORTED usage "'${TS_COMMAND}' does not support --json yet (supported: version, detect)"
    fi
    return 0
}

parse_args() {
    ts_parse_cli "$@"
    ts_init_colors
    if [[ "$TS_JSON" -eq 1 ]]; then
        # Anything printed to stdout from here on is a log and goes to stderr; the JSON document
        # goes to the original stdout, kept on file descriptor 3
        exec 3>&1 1>&2
        TS_OUT_FD=3
        trap ts_json_exit_guard EXIT
    fi

    if [[ -n "$TS_USAGE_ERROR" ]]; then
        ts_usage_error "$TS_USAGE_ERROR"
    fi
    if [[ -z "$TS_COMMAND" ]]; then
        if [[ ${#TS_ARGV[@]} -eq 0 ]]; then
            cmd_help
            exit 0
        fi
        ts_usage_error "Missing command"
    fi
    ts_validate_cli
    
    # Verify configuration exists before proceeding (Early fail)
    if [[ "$TS_COMMAND" == "install" ]]; then
        config_path=$(detect_config_file "$CONFIG_FILE") || exit $?
        CONFIG_FILE="$config_path"
    fi
    
    # Dispatch command
    case "$TS_COMMAND" in
        install)
            check_root "${TS_ARGV[@]}"
            cmd_install
            ;;
        pre-check)
            check_root "${TS_ARGV[@]}"
            cmd_pre_check
            ;;
        uninstall)
            check_root "${TS_ARGV[@]}"
            cmd_uninstall
            ;;
        status)
            check_root "${TS_ARGV[@]}"
            if [[ -n "$CONFIG_FILE" ]] && [[ ! -f "$CONFIG_FILE" ]]; then
                print_error "Config file not found: $CONFIG_FILE"
                exit 1
            fi
            # Explicit --platform / --impl take precedence over auto-detection
            PLATFORM="$TS_OPT_PLATFORM"
            LN_IMPL="$TS_OPT_IMPL"
            cmd_status
            ;;
        restart)
            check_root "${TS_ARGV[@]}"
            if [[ -n "$CONFIG_FILE" ]]; then
                # wg-quick@<name> always reads <WireGuard dir>/<name>.conf: only an installed config fits
                if [[ ! -f "$CONFIG_FILE" ]]; then
                    print_error "Config file not found: $CONFIG_FILE"
                    exit 1
                fi
                if [[ "$(cd "$(dirname "$CONFIG_FILE")" && pwd -P)" != "$(cd "${WG_DIR:-/etc/wireguard}" 2>/dev/null && pwd -P)" ]]; then
                    ts_usage_error "restart --config must name an installed config in ${WG_DIR:-/etc/wireguard}"
                fi
                # Checked before anything is stopped: a backup such as tunnelsatsv2.conf.bak.X is not
                # a config wg-quick can start, so restarting with it would leave Lightning stopped
                if ! ts_valid_installed_config_name "${CONFIG_FILE##*/}"; then
                    ts_usage_error "restart --config must name an installed TunnelSats config (tunnelsatsv2.conf or tunnelsats-<name>.conf)"
                fi
            fi
            PLATFORM="$TS_OPT_PLATFORM"
            LN_IMPL="$TS_OPT_IMPL"
            cmd_restart
            ;;
        detect)
            cmd_detect
            ;;
        version)
            cmd_version
            ;;
        help)
            cmd_help
            ;;
    esac
}

# ---------------------------------------------------------------------------
# MAIN ENTRY POINT
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"
}

# Run the script only when executed directly, not when sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
