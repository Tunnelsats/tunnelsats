#!/bin/bash

# Check if script is run with sudo
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo bash tunnelsats-sub-details.sh"
  exit 1
fi

# Help text
if [[ "$1" == "-h" ]]; then
  echo "Usage: sudo bash tunnelsats-sub-details.sh"
  echo "This script provides details about your Tunnel⚡️Sats subscription."
  echo "Beware of scammers, don't ever share your private key."
  exit 0
fi

# Function to check Wireguard status and config file
check_wireguard_status() {
  wg_output=$(sudo wg show)
  if ! echo "$wg_output" | grep -q "interface: tunnelsatsv2"; then
    config_file="/etc/wireguard/tunnelsatsv2.conf"
    if [ ! -f "$config_file" ]; then
      echo "The wireguard tunnel seems to be offline, and no tunnelsatsv2.conf could be found in the wireguard directory."
      echo "Please try a reinstall per https://guide.tunnelsats.com"
      echo "Alternatively, visit the Tunnel⚡️Sats Telegram Chat: https://tunnelsats.com/join-telegram"
      return 1
    else
      echo "The wireguard tunnel seems to be offline. Please try restarting your node."
      return 1
    fi
  fi
  return 0
}

# Call the function to check Wireguard status
check_wireguard_status
if [ $? -ne 0 ]; then
  exit 1
fi

# Function to check if Docker is running and relevant containers exist
 check_docker_setup() {
   if systemctl is-active --quiet docker; then
     if docker ps --filter name=core-lightning -q | grep -q . || docker ps --filter name=lnd -q | grep -q .; then
      if docker ps --filter name=core-lightning -q | grep -q .; then # Check for core-lightning container
        local result="docker-core-lightning"
        echo -e "\e[1;31m${result}\e[0m" >&2
        echo "${result}"
        return 0
      elif docker ps --filter name=lnd -q | grep -q .; then # Check for lnd container
        local result="docker-lnd"
        echo -e "\e[1;31m${result}\e[0m" >&2
        echo "${result}"
        return 0
      fi
     fi
   fi
   local result="manual" # Neither Docker container found explicitly
   echo -e "\e[1;31m${result}\e[0m" >&2
   echo "${result}"
   return 1
 }

# Function to perform outbound connectivity check
perform_outbound_check() {
  local setup_type=$1
  local ip_address=""
  local cmd_exit_code=0 # For Docker or manual commands

  echo "Performing outbound check..." >&2
  if [[ "$setup_type" == "docker-lnd" || "$setup_type" == "docker-core-lightning" ]]; then
    if ! docker network inspect docker-tunnelsats > /dev/null 2>&1; then
        echo "Warning: Docker network 'docker-tunnelsats' not found. Cannot perform Docker outbound check." >&2
        ip_address="Error: Docker network missing"
    else
        ip_address=$(timeout 20s docker run --rm --net=docker-tunnelsats curlimages/curl -s https://api.ipify.org)
        cmd_exit_code=$?

        if [ $cmd_exit_code -ne 0 ]; then
             echo "Warning: Docker outbound check command failed or timed out (exit code: $cmd_exit_code)." >&2
             if [[ "$ip_address" == "" ]]; then # Check if ip_address is empty string
                ip_address="Error: Docker check timed out or command failed with no output"
             else
                ip_address="Error: Docker check failed (command error)"
             fi
        elif [[ "$ip_address" == "" ]]; then # Check if ip_address is empty string
            echo "Warning: Docker outbound check command succeeded but returned empty output." >&2
            ip_address="Error: Empty response from server via Docker"
        fi
    fi
  else
    # Manual setup check
    if command -v cgexec &> /dev/null; then
      ip_address=$(timeout 20s cgexec -g net_cls:splitted_processes curl --silent https://api.ipify.org)
      cmd_exit_code=$?
       if [ $cmd_exit_code -ne 0 ]; then
             echo "Warning: cgexec outbound check failed or timed out (exit code: $cmd_exit_code)." >&2
             ip_address="Error: cgexec check failed"
        elif [[ "$ip_address" == "" ]]; then
             echo "Warning: cgexec outbound check succeeded but returned empty." >&2
             ip_address="Error: Empty response from server via cgexec"
        fi
    else
      echo "Warning: 'cgexec' command not found. Falling back to standard curl. Outbound check might use the wrong interface." >&2
      ip_address=$(timeout 20s curl --silent https://api.ipify.org)
      cmd_exit_code=$?
       if [ $cmd_exit_code -ne 0 ]; then
             echo "Warning: Standard curl outbound check failed or timed out (exit code: $cmd_exit_code)." >&2
             ip_address="Error: curl check failed"
       elif [[ "$ip_address" == "" ]]; then
             echo "Warning: Standard curl outbound check succeeded but returned empty." >&2
             ip_address="Error: Empty response from server via curl"
       fi
    fi
  fi

  # Basic validation if it looks like an IP
  if [[ "$ip_address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Outbound check completed. IP: $ip_address" >&2
      echo "$ip_address" # Print final IP to stdout
  else
      echo "Outbound check could not retrieve a valid IP. Value was: [$ip_address]" >&2
      echo "$ip_address" # Print error message or invalid IP to stdout
  fi
}

perform_inbound_check() {
  local target_endpoint=$1
  local target_port=$2
  local result_ip=""
  local status="failed"

  echo "Performing inbound check for $target_endpoint:$target_port..." >&2
  
  # Use timeout and head to capture just the connection attempt
  curl_output=$(timeout 3s curl -sv telnet://"$target_endpoint":"$target_port" 2>&1 | head -n 2)
  curl_exit_code=${PIPESTATUS[0]}
  
  if [[ "$curl_output" == *"Connected to"* ]]; then
    result_ip=$(echo "$curl_output" | grep "Connected to" | grep -oP 'Connected to [^ ]+ \(\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    if [[ -n "$result_ip" ]]; then
      echo "Inbound check successful. Server IP: $result_ip" >&2
      status="success"
    else
      echo "Warning: Inbound check succeeded but could not parse server IP from output." >&2
      result_ip="Unknown (Success)"
      status="success_no_ip"
    fi
  else
    echo "Inbound check failed." >&2
    result_ip="Error: Connection failed"
  fi

  # Return status and IP on a single line to stdout, space-separated
  echo "$status $result_ip"
}

interface="tunnelsatsv2"
latest_handshake=$(echo "$wg_output" | grep -A 12 "interface: $interface" | grep 'latest handshake' | awk -F': ' '{print $2}')
transfer=$(echo "$wg_output" | grep -A 12 "interface: $interface" | grep 'transfer' | awk -F': ' '{print $2}')
public_key=$(echo "$wg_output" | grep -A 5 "interface: $interface" | grep 'public key' | awk -F': ' '{print $2}')

# Parse endpoint and VPN port from config file
config_file="/etc/wireguard/tunnelsatsv2.conf"
endpoint=$(grep '^Endpoint =' "$config_file" | awk '{print $3}' | cut -d ':' -f 1)
VPNPort=$(grep '^#VPNPort =' "$config_file" | awk '{print $3}')

# Check if parsing was successful
if [ -z "$endpoint" ]; then
  echo "Warning: Could not parse Endpoint from $config_file"
  endpoint="N/A"
fi
if [ -z "$VPNPort" ]; then
  echo "Warning: Could not parse VPNPort from $config_file"
  VPNPort="N/A"
fi

# Determine setup type
setup_method=$(check_docker_setup)
echo "Detected setup: $setup_method"

# Perform checks only if endpoint and VPNPort were successfully parsed
VPNIPoutbound="N/A"
VPNIPinbound="N/A"
inbound_status="N/A"
connectivity_ok=false
outbound_ok=false
inbound_ok=false

if [[ "$endpoint" != "N/A" && "$VPNPort" != "N/A" ]]; then
    VPNIPoutbound=$(perform_outbound_check "$setup_method")
    read -r inbound_status VPNIPinbound <<< "$(perform_inbound_check "$endpoint" "$VPNPort")"

    # Validate IPs and statuses
    if [[ "$VPNIPoutbound" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        outbound_ok=true
    fi
    if [[ "$inbound_status" == "success" || "$inbound_status" == "success_no_ip" ]]; then
        inbound_ok=true
    fi

    # Check overall connectivity
    if $outbound_ok && $inbound_ok && [[ "$VPNIPoutbound" == "$VPNIPinbound" ]]; then
        connectivity_ok=true
    elif $outbound_ok && $inbound_ok && [[ "$inbound_status" == "success_no_ip" ]]; then
        # Handle case where inbound succeeded but IP couldn't be parsed - assume OK if outbound IP looks valid
         echo "Warning: Inbound IP could not be parsed from our output parser, but check succeeded. Assuming OK based on outbound check."
         connectivity_ok=true # Consider it OK for the summary message
    fi
else
    echo "Skipping connectivity checks because Endpoint or VPNPort could not be determined."
fi

# Function to get the node's external address (PUBKEY@IP:PORT) based on setup type
get_node_external_address() {
  local setup_type=$1
  local external_address="N/A"
  local getinfo_cmd=""
  local docker_container_name=""
  local node_type=""

  echo "Attempting to get pubkey for setup type: $setup_type" >&2

  case "$setup_type" in
    "docker-lnd")
      docker_container_name="lightning_lnd_1"
      getinfo_cmd="lncli getinfo"
      node_type="LND"
      if ! command -v jq &> /dev/null; then 
        echo "Error: jq not found. Please install jq to parse LND info." >&2
        echo "$node_type"
        echo "N/A"
        return 1
      else
        # For Docker, assume lncli is available and try to execute directly
        local LND_INFO
        LND_INFO=$(docker exec "$docker_container_name" $getinfo_cmd 2>&1)
        local docker_exit_code=$?
        if [[ $docker_exit_code -ne 0 ]]; then
          echo "Error: Failed to execute lncli getinfo in Docker container $docker_container_name." >&2
          echo "Command output: $LND_INFO" >&2
        else
          # Find first IPv4 URI (not tor)
          external_address=$(echo "$LND_INFO" | jq -r '.uris[]' | grep -v "\.onion" | head -n 1)
          if [[ -z "$external_address" || "$external_address" == "null" ]]; then
            external_address="N/A"
          fi
        fi
      fi
      ;;
    "docker-core-lightning")
      docker_container_name="core-lightning_lightningd_1"
      getinfo_cmd="lightning-cli getinfo"
      node_type="CLN"
      if ! command -v jq &> /dev/null; then 
        echo "Error: jq not found. Please install jq to parse Core-Lightning info." >&2
        echo "$node_type"
        echo "N/A"
        return 1
      else
        # For Docker, assume lightning-cli is available and try to execute directly
        local CLN_INFO
        CLN_INFO=$(docker exec "$docker_container_name" $getinfo_cmd 2>&1)
        local docker_exit_code=$?
        if [[ $docker_exit_code -ne 0 ]]; then
          echo "Error: Failed to execute lightning-cli getinfo in Docker container $docker_container_name." >&2
          echo "Command output: $CLN_INFO" >&2
        else
          # Get pubkey and IPv4 address
          local pubkey=$(echo "$CLN_INFO" | jq -r '.id')
          local ipv4_address=$(echo "$CLN_INFO" | jq -r '.address[] | select(.type == "ipv4") | .address' | head -n 1)
          local ipv4_port=$(echo "$CLN_INFO" | jq -r '.address[] | select(.type == "ipv4") | .port' | head -n 1)
          if [[ -n "$pubkey" && "$pubkey" != "null" && -n "$ipv4_address" && "$ipv4_address" != "null" && -n "$ipv4_port" && "$ipv4_port" != "null" ]]; then
            external_address="${pubkey}@${ipv4_address}:${ipv4_port}"
          else
            external_address="N/A"
          fi
        fi
      fi
      ;;
    "manual")
      # Check for globally available commands
      local original_user="${SUDO_USER:-$(whoami)}" # Get the original user who invoked sudo
      local lnd_base_dir="/home/$original_user/.lnd"
      local lnd_tls_cert="/home/$original_user/.lnd/tls.cert"
      local cln_lightning_dir="/home/$original_user/.lightning" # Assuming this path for CLN

      if command -v lncli &> /dev/null; then
        echo "Detected manual LND setup. Fetching pubkey..." >&2
        node_type="LND"
        if ! command -v jq &> /dev/null; then 
          echo "Error: jq not found. Please install jq to parse LND info." >&2
          echo "$node_type"
          echo "N/A"
          # Return 1 is handled by the overall function, no explicit return needed here for just the jq check
        else
          local LND_INFO
          # Try running lncli as the original user with explicit paths
          LND_INFO=$(sudo -u "$original_user" lncli --lnddir="$lnd_base_dir" --tlscertpath="$lnd_tls_cert" getinfo 2>/dev/null)
          local lncli_exit_code=$?

          if [[ $lncli_exit_code -ne 0 ]] || [[ -z "$LND_INFO" ]]; then
            echo "Error: Failed to get LND info for user $original_user. Command output: $LND_INFO" >&2
            echo "$node_type"
            echo "N/A"
          else
            # Extract first IPv4 URI (skip .onion addresses)
            external_address=$(echo "$LND_INFO" | jq -r '.uris[]' | grep -v "\.onion" | head -n 1)
            if [[ -z "$external_address" || "$external_address" == "null" ]]; then
              external_address="N/A"
            fi
          fi
        fi
      elif command -v lightning-cli &> /dev/null; then
        echo "Detected manual Core-Lightning setup. Fetching pubkey..." >&2
        node_type="CLN"
        if ! command -v jq &> /dev/null; then 
          echo "Error: jq not found. Please install jq to parse Core-Lightning info." >&2
          echo "$node_type"
          echo "N/A"
          # Return 1 is handled by the overall function, no explicit return needed here for just the jq check if command is not found
        else
          local CLN_INFO
          # Try running lightning-cli as the original user with explicit paths
          CLN_INFO=$(sudo -u "$original_user" lightning-cli --lightning-dir="$cln_lightning_dir" getinfo 2>/dev/null)
          local cln_exit_code=$?

          if [[ $cln_exit_code -ne 0 ]] || [[ -z "$CLN_INFO" ]]; then
            echo "Error: Failed to get Core-Lightning info for user $original_user. Command output: $CLN_INFO" >&2
            echo "$node_type"
            echo "N/A"
            # Get pubkey and IPv4 address
            local pubkey=$(echo "$CLN_INFO" | jq -r '.id')
            local ipv4_address=$(echo "$CLN_INFO" | jq -r '.address[] | select(.type == "ipv4") | .address' | head -n 1)
            local ipv4_port=$(echo "$CLN_INFO" | jq -r '.address[] | select(.type == "ipv4") | .port' | head -n 1)
            if [[ -n "$pubkey" && "$pubkey" != "null" && -n "$ipv4_address" && "$ipv4_address" != "null" && -n "$ipv4_port" && "$ipv4_port" != "null" ]]; then
              external_address="${pubkey}@${ipv4_address}:${ipv4_port}"
            else
              external_address="N/A"
            fi
          fi
        fi
      else
        echo "Could not find 'lncli' or 'lightning-cli' commands globally for manual setup." >&2
        echo "$node_type"
        echo "N/A"
        # Return 1 is handled by the overall function, no explicit return needed here for just the command check
      fi
      ;;
    *)
      echo "Unknown setup type: $setup_type" >&2
      echo "$node_type"
      echo "N/A"
      # Return 1 is handled by the overall function, no explicit return needed here for just the unknown type check
      ;;
  esac

  # Output node type and external address on separate lines (always output, even on error)
  # The calling script will read these two lines.
  echo "$node_type"
  echo "$external_address"
}

# Determine setup type and get external address
lightning_implementation=$(check_docker_setup) # e.g., "docker-lnd", "docker-core-lightning", or "manual"
 node_info=$(get_node_external_address "$lightning_implementation") # Capture both lines of output_implementation")
 node_type=$(echo "$node_info" | head -n 1)
 external_address=$(echo "$node_info" | tail -n 1)

# Display summary
echo -e "\e[1;32m=================================\e[0m"
echo -e "\e[1;32mTunnel⚡️Sats Subscription Summary\e[0m"
echo -e "\e[1;32m=================================\e[0m"
echo -e "My Wireguard Tunnel Public Key: \e[1;34m$public_key\e[0m"
echo -e "My transfer since last tunnel restart: \e[1;34m$transfer\e[0m"
echo -e "Latest handshake with the Tunnel Server: \e[1;34m$latest_handshake\e[0m"
echo ""
echo -e "\e[1;33m--- VPN Details (Wireguard Tunnel Config) ---\e[0m"
echo -e "Your VPN Server: \e[1;34m$endpoint\e[0m"
echo -e "Your VPN Public Port: \e[1;34m$VPNPort\e[0m"
echo ""
if [[ -n "$node_type" ]]; then
  echo -e "\e[1;33m--- {$node_type} Node Configuration Details ---\e[0m"
else
  echo -e "\e[1;33m--- Node Configuration Details ---\e[0m"
fi
echo -e "Your external Address: \e[1;34m$external_address\e[0m"
echo ""
echo -e "\e[1;32m--- Connectivity Check ---\e[0m"
echo -e "Outbound IP via Tunnel: \e[1;34m$VPNIPoutbound\e[0m"
echo -e "Inbound Check Status: \e[1;34m$inbound_status\e[0m"
echo -e "Inbound Check Server IP: \e[1;34m$VPNIPinbound\e[0m"
echo ""

if $connectivity_ok; then
  echo -e "\e[1;32m✅ Both inbound and outbound connections via the tunnel seem to be working correctly!\e[0m"
elif $outbound_ok && ! $inbound_ok; then
  echo -e "\e[1;31m⚠️ Outbound connection seems OK, but the inbound check failed.\e[0m"
  echo -e "\e[1;31m   Please check firewall settings and ensure port $VPNPort is reachable on $endpoint.\e[0m"
  echo -e "\e[1;31m   See: https://guide.tunnelsats.com/ and https://guide.tunnelsats.com/FAQ.html\e[0m"
elif ! $outbound_ok && $inbound_ok; then
   echo -e "\e[1;31m⚠️ Inbound connection seems OK, but the outbound check failed or reported a different IP.\e[0m"
   echo -e "\e[1;31m   Ensure services are configured to use the tunnel (e.g., Docker network, cgexec).\e[0m"
   echo -e "\e[1;31m   See: https://guide.tunnelsats.com/ and https://guide.tunnelsats.com/FAQ.html\e[0m"
elif $outbound_ok && $inbound_ok && [[ "$VPNIPoutbound" != "$VPNIPinbound" ]]; then
    echo -e "\e[1;31m⚠️ Both checks reported an IP, but they don't match ($VPNIPoutbound vs $VPNIPinbound).\e[0m"
    echo -e "\e[1;31m   This might indicate a configuration issue or network problem.\e[0m"
    echo -e "\e[1;31m   See: https://guide.tunnelsats.com/ and https://guide.tunnelsats.com/FAQ.html\e[0m"
else # Both failed or couldn't run
  echo -e "\e[1;31m❌ Both inbound and outbound checks failed or could not be completed.\e[0m"
  echo -e "\e[1;31m   Please review the warnings above and check your configuration.\e[0m"
  echo -e "\e[1;31m   See: https://guide.tunnelsats.com/ and https://guide.tunnelsats.com/FAQ.html\e[0m"
fi
echo ""
echo "To validate your subscription details, copy your Wireguard Tunnel Public Key and visit 'https://tunnelsats.com/ > Renew'."
echo "Use Telegram Reminder Bot to add a secure and anon reminder when your subscription runs out: https://t.me/TunnelSatsReminderBot."
echo ""
echo "Thank you for using our Service"
