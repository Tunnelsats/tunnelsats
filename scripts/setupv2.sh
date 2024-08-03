#!/bin/bash
# This script setup the environment needed for VPN usage on lightning network nodes
# Use with care
#
# Usage: sudo bash setup.sh

#VERSION NUMBER of setupv2.sh
#Update if you make a significant change
##########UPDATE IF YOU MAKE A NEW RELEASE#############
major=0
minor=1
patch=32

#Helper
function valid_ipv4() {
  local ip=$1
  local stat=1

  if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    OIFS=$IFS
    IFS='.'
    ip=($ip)
    IFS=$OIFS
    [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 &&
      ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
    stat=$?
  fi
  return $stat
}

# check if sudo
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (with sudo)"
  exit 1
fi

# intro
echo -e "
###############################
         TunnelSats v2
         Setup Script
         Version:
         v$major.$minor.$patch
###############################"
echo

# Check if docker / non-docker
isDocker=0
killswitchRaspi=0
litpossible=0  # Set this to 1 earlier in your script if LIT is possible

while true; do
  read -p "What lightning node package are you running?: 
    1) RaspiBlitz
    2) Umbrel
    3) myNode
    4) RaspiBolt / Bare Metal
    > " answer

  case $answer in
  1)
    echo "> RaspiBlitz"
    echo
    killswitchRaspi=1
    isDocker=0
    break
    ;;

  2)
    echo "> Umbrel"
    echo
    isDocker=1
    isUmbrel=1
    break
    ;;

  3)
    echo "> myNode"
    echo
    isDocker=0
    break
    ;;

  4)
    echo "> RaspiBolt / Bare Metal"
    echo
    isDocker=0
    litpossible=1

    break
    ;;

  *) echo "Please enter a number from 1 to 4." ;;
  esac
done

# Check which implementation the user wants to tunnel
lnImplementation=""

while true; do
  echo "Which lightning implementation do you want to tunnel?"
  echo "    1) LND"
  echo "    2) CLN (Core Lightning)"
  if [ $litpossible -eq 1 ]; then
    echo "    3) LIT (integrated mode)"
    echo "    4) Exit"
    prompt_range="1-4"
  else
    echo "    3) Exit"
    prompt_range="1-3"
  fi
  read -p "Enter your choice [${prompt_range}]: " choice

  case $choice in
    1)
      echo "> Setting up Tunneling for LND on port 9735 "
      echo
      lnImplementation="lnd"
      break
      ;;
    2)
      echo "> Setting up Tunneling for CLN on port 9735 "
      echo
      lnImplementation="cln"
      break
      ;;
    3)
      if [ $litpossible -eq 1 ]; then
        echo "> Setting up Tunneling for integrated LND in LIT on port 9735 "
        echo
        lnImplementation="lit"
        break
      else
        echo "Exiting..."
        exit 0
      fi
      ;;
    4)
      echo "Exiting..."
      exit 0
      ;;
    *)
      echo "Invalid option. Please enter a valid number."
      ;;
  esac
done

# check for downloaded tunnelsatsv2.conf, exit if not available
# get current directory
directory=$(dirname -- "$(readlink -fn -- "$0")")
echo "Looking for WireGuard config file..."
if [ ! -f "$directory"/tunnelsatsv2.conf ] || [ $(grep -c "Endpoint" "$directory"/tunnelsatsv2.conf) -eq 0 ]; then
  echo "> ERR: tunnelsatsv2.conf not found or missing Endpoint."
  echo "> Please place it in this script's location and check original tunnelsatsv2.conf for \"Endpoint\" entry"
  echo
  exit 1
else
  echo "> tunnelsatsv2.conf found, proceeding."
  echo
fi

# security check - exit if nonDocker and no systemd service found
if [ $isDocker -eq 0 ]; then
  echo "Looking for systemd service..."

  if [ "$lnImplementation" == "lnd" ] && [ ! -f /etc/systemd/system/lnd.service ]; then
    echo "> /etc/systemd/system/lnd.service not found. Setup aborted."
    echo
    exit 1
  fi

  if [ "$lnImplementation" == "cln" ] && [ ! -f /etc/systemd/system/lightningd.service ]; then
    echo "> /etc/systemd/system/lightningd.service not found. Setup aborted."
    echo
    exit 1
  fi

  if [ "$lnImplementation" == "lit" ] && [ ! -f /etc/systemd/system/lit.service ]; then
    echo "> /etc/systemd/system/lit.service not found. Setup aborted."
    echo
    exit 1
  fi
fi

# RaspiBlitz: deactivate config checks
if [ "$lnImplementation" == "lnd" ]; then
  if [ -f /home/admin/config.scripts/lnd.check.sh ]; then
    mv /home/admin/config.scripts/lnd.check.sh /home/admin/config.scripts/lnd.check.bak
    echo "RaspiBlitz detected, lnd conf safety check removed"
    echo
  fi
elif [ "$lnImplementation" == "cln" ]; then
  if [ -f /home/admin/config.scripts/cl.check.sh ]; then
    mv /home/admin/config.scripts/cl.check.sh /home/admin/config.scripts/cl.check.bak
    echo "RaspiBlitz detected, cln conf safety check removed"
    echo
  fi
fi

# check requirements and update repos
echo "Checking and installing requirements..."
echo "Updating the package repositories..."
apt-get update >/dev/null
echo

# only non-docker
if [ $isDocker -eq 0 ]; then
  # check cgroup-tools only necessary when lightning runs as systemd service
  if [ -f /etc/systemd/system/lnd.service ] ||
    [ -f /etc/systemd/system/lightningd.service ] ||
    [ -f /etc/systemd/system/lit.service ]; then
    echo "Checking cgroup-tools..."
    checkcgroup=$(cgcreate -h 2>/dev/null | grep -c "Usage")
    if [ $checkcgroup -eq 0 ]; then
      echo "Installing cgroup-tools..."
      if apt-get install -y cgroup-tools >/dev/null; then
        echo "> cgroup-tools installed"
        echo
      else
        echo "> failed to install cgroup-tools"
        echo
        exit 1
      fi
    else
      echo "> cgroup-tools found"
      echo
    fi
  fi
fi

sleep 2

# check nftables
echo "Checking nftables installation..."
checknft=$(nft -v 2>/dev/null | grep -c "nftables")
if [ $checknft -eq 0 ]; then
  echo "Installing nftables..."
  if apt-get install -y nftables >/dev/null; then
    echo "> nftables installed"
    echo
  else
    echo "> failed to install nftables"
    echo
    exit 1
  fi
else
  echo "> nftables found"
  echo
fi

sleep 2

#Check if system is virtualized
virtualized=0
#Only modprobe in unvirtualized system
modprobe=""
systemd-detect-virt -c --quiet
if [ $? -eq 0 ]; then
  echo "> Virtualized setup"
  virtualized=1
  echo
fi

echo "Checking wireguard installation..."
checkwg=$(wg -v 2>/dev/null | grep -c "wireguard-tools")
if [ $checkwg -eq 0 ]; then
  echo "Installing wireguard..."

  if apt-get install -y wireguard >/dev/null; then
    echo "> wireguard installed"
    echo
  else
    # try Debian 10 Buster workaround / myNode
    codename=$(lsb_release -c 2>/dev/null | awk '{print $2}')
    if [ "$codename" == "buster" ] && [ "$(hostname)" != "umbrel" ]; then
      if apt-get install -y -t buster-backports wireguard >/dev/null; then
        echo "> wireguard installed"
        echo
      else
        echo "> failed to install wireguard"
        echo
        exit 1
      fi
    fi
  fi
else
  echo "> wireguard found"
  echo
fi

# Install wireguard-go because we need a wireguard which runs in userspace
# because we are virtualized
# Check for a go installation first

if [ $virtualized -eq 1 ]; then
  echo "> Your system is virtualized, you need to download userspace wireguard implementation"
  echo "> wireguard-go is such a userspace wireguard implementation, therefore we check in the"
  echo "> following whether its installed on your system."
  echo
  goinstalled=$(go version 2>/dev/null | grep -c "go version")
  if [ $goinstalled -eq 0 ]; then
    echo "> failed to find golang on your system (go version)"
    echo
    exit 1
  fi

  wireguard-go --version 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "> failed to find wireguard-go on your system (wireguard-go --version)"
    echo "> make sure you install wireguard-go on your system"
    echo "> see https://github.com/WireGuard/wireguard-go"
    echo "> make sure you edit the following line after installing wireguard-go"
    echo "> in /lib/systemd/system/wg-quick@.service edit"
    echo "> Environment=WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KMOD=1 below the entry"
    echo "> Environment=WG_ENDPOINT_RESOLUTION_RETRIES=infinity"
    echo
    exit 1
  fi

else
  modprobe="modprobe cls_cgroup"

fi

sleep 2

# add resolvconf package to docker systems for DNS resolving
if [ $isDocker -eq 1 ]; then
  echo "Checking resolvconf installation..."
  checkResolv=$(resolvconf 2>/dev/null | grep -c "^Usage")
  if [ $checkResolv -eq 0 ]; then
    echo "Installing resolvconf..."
    if apt-get install -y resolvconf >/dev/null; then
      echo "> resolvconf installed"
      echo
    else
      echo "> failed to install resolvconf"
      echo
      exit 1
    fi
  else
    echo "> resolvconf found"
    echo
  fi
  sleep 2
fi

#Create Docker Tunnelsat Network
if [ $isDocker -eq 1 ]; then

  echo "Creating TunnelSats Docker Network..."
  checkdockernetwork=$(docker network ls 2>/dev/null | grep -c "docker-tunnelsats")
  #the subnet needs a bigger subnetmask (25) than the normal umbrel_mainet subnetmask of 24
  #otherwise the network will not be chosen as the gateway for outside connection
  dockersubnet="10.9.9.0/25"

  if [ $checkdockernetwork -eq 0 ]; then
    docker network create "docker-tunnelsats" --subnet $dockersubnet -o "com.docker.network.driver.mtu"="1420" &>/dev/null
    if [ $? -eq 0 ]; then
      echo "> docker-tunnelsats created successfully"
      echo
    else
      echo "> failed to create docker-tunnelsats network"
      echo
      exit 1
    fi
  else
    echo "> docker-tunnelsats already created"
    echo
  fi

  #Clean Routing Tables from prior failed wg-quick starts
  delrule1=$(ip rule | grep -c "from all lookup main suppress_prefixlength 0")
  delrule2=$(ip rule | grep -c "from $dockersubnet lookup 51820")
  for i in $(seq 1 $delrule1); do
    ip rule del from all table main suppress_prefixlength 0
  done

  for i in $(seq 1 $delrule2); do
    ip rule del from $dockersubnet table 51820
  done

  #Flush any rules which are still present from failed interface starts
  ip route flush table 51820 &>/dev/null

else

  #Delete Rules for non-docker setup
  #Clean Routing Tables from prior failed wg-quick starts
  delrule1=$(ip rule | grep -c "from all lookup main suppress_prefixlength 0")
  delrule2=$(ip rule | grep -c "from all fwmark 0x1000000/0xff000000 lookup 51820")
  for i in $(seq 1 $delrule1); do
    ip rule del from all table main suppress_prefixlength 0
  done

  for i in $(seq 1 $delrule2); do
    ip rule del from all fwmark 0x1000000/0xff000000 table 51820
  done

  #Flush any rules which are still present from failed interface starts
  ip route flush table 51820 &>/dev/null

fi

sleep 2

# Fetch all local networks and exclude them from kill switch
localNetworks=$(ip route | awk '{print $1}' | grep -v default | sed -z 's/\n/, /g')

if [ -z "$localNetworks" ]; then
  # add default networks according to RFC 1918
  localNetworks="10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16"
fi

if [ $killswitchRaspi -eq 1 ]; then

  killswitchNonDocker="PostUp = nft insert rule ip %i nat skuid bitcoin fib  daddr type != local ip daddr != {$localNetworks}  meta oifname != %i  meta l4proto { tcp, udp } th dport != { 51820 } counter drop\n"
else
  # only implemented for RaspiBlitz
  killswitchNonDocker=""

fi

# edit tunnelsats.conf, add PostUp/Down rules
# and copy to destination folder
echo "Copy wireguard conf file to /etc/wireguard and apply network rules..."
inputDocker="\n
#Tunnelsats-Setupv2-Docker\n
[Interface]\n
DNS = 8.8.8.8\n
Table = off\n
\n

PostUp = while [ \$(ip rule | grep -c suppress_prefixlength) -gt 0 ]; do ip rule del from all table  main suppress_prefixlength 0;done\n
PostUp = while [ \$(ip rule | grep -c 0x1000000) -gt 0 ]; do ip rule del from all fwmark 0x1000000/0xff000000 table  51820;done\n
PostUp = if [ \$(ip route show table 51820 2>/dev/null | grep -c blackhole) -gt  0 ]; then echo \$?; ip route del blackhole default metric 3 table 51820; ip rule flush table 51820 ;fi\n


PostUp = ip rule add from \$(docker network inspect \"docker-tunnelsats\" | grep Subnet | awk '{print \$2}' | sed 's/[\",]//g') table 51820\n
PostUp = ip rule add from all table main suppress_prefixlength 0\n
PostUp = ip route add blackhole default metric 3 table 51820\n
PostUp = ip route add default dev %i metric 2 table 51820\n
PostUp = ip route add  10.9.0.0/24 dev %i  proto kernel scope link; ping -c1 10.9.0.1\n
\n
PostUp = sysctl -w net.ipv4.conf.all.rp_filter=0\n
PostUp = sysctl -w net.ipv6.conf.all.disable_ipv6=1\n
PostUp = sysctl -w net.ipv6.conf.default.disable_ipv6=1\n
\n
PostDown = ip rule del from \$(docker network inspect \"docker-tunnelsats\" | grep Subnet | awk '{print \$2}' | sed 's/[\",]//g') table 51820\n
PostDown = ip rule del from all table  main suppress_prefixlength 0\n
PostDown = ip route flush table 51820\n
PostDown = sysctl -w net.ipv4.conf.all.rp_filter=1\n
"
inputNonDocker="\n
#Tunnelsats-Setupv2-Non-Docker\n
[Interface]\n
FwMark = 0x2000000\n
Table = off\n
\n

PostUp = while [ \$(ip rule | grep -c suppress_prefixlength) -gt 0 ]; do ip rule del from all table  main suppress_prefixlength 0;done\n
PostUp = while [ \$(ip rule | grep -c 0x1000000) -gt 0 ]; do ip rule del from all fwmark 0x1000000/0xff000000 table  51820;done\n

PostUp = ip rule add from all fwmark 0x1000000/0xff000000 table 51820;ip rule add from all table main suppress_prefixlength 0\n
PostUp = ip route add default dev %i table 51820;\n
PostUp = ip route add  10.9.0.0/24 dev %i  proto kernel scope link; ping -c1 10.9.0.1\n
PostUp = sysctl -w net.ipv4.conf.all.rp_filter=0\n
PostUp = sysctl -w net.ipv6.conf.all.disable_ipv6=1\n
PostUp = sysctl -w net.ipv6.conf.default.disable_ipv6=1\n
\n
PostUp = nft add table ip %i\n
PostUp = nft add chain ip %i prerouting '{type filter hook prerouting priority mangle -1; policy accept;}'; nft add rule ip %i prerouting meta mark set ct mark\n
PostUp = nft add chain ip %i mangle '{type route hook output priority mangle -1; policy accept;}'; nft add rule ip %i mangle tcp sport != { 8080, 10009 } meta mark and 0xff000000 != 0x2000000 meta cgroup 1118498 meta mark set mark and 0x00ffffff xor 0x1000000\n
PostUp = nft add chain ip %i nat'{type nat hook postrouting priority srcnat -1; policy accept;}'; nft insert rule ip %i nat  fib daddr type != local  ip daddr != {$localNetworks} oifname != %i ct mark and 0xff000000 == 0x1000000 drop;nft add rule ip %i nat oifname %i ct mark and 0xff000000 == 0x1000000 masquerade\n
$killswitchNonDocker
PostUp = nft add chain ip %i postroutingmangle'{type filter hook postrouting priority mangle -1; policy accept;}'; nft add rule ip %i postroutingmangle meta mark and 0xff000000 == 0x1000000 ct mark set meta mark and 0x00ffffff xor 0x1000000 \n
PostUp = nft add chain ip %i input'{type filter hook input priority filter -1; policy accept;}'; nft add rule ip %i input iifname %i  ct state established,related counter accept; nft add rule ip %i input iifname %i tcp dport != 9735 counter drop; nft add rule ip %i input iifname %i udp dport != 9735 counter drop\n

\n
PostDown = nft delete table ip %i\n
PostDown = ip rule del from all table  main suppress_prefixlength 0; ip rule del from all fwmark 0x1000000/0xff000000 table 51820\n
PostDown = ip route flush table 51820\n
PostDown = sysctl -w net.ipv4.conf.all.rp_filter=1\n
"

directory=$(dirname -- "$(readlink -fn -- "$0")")
if [ -f "$directory"/tunnelsatsv2.conf ]; then
  cp "$directory"/tunnelsatsv2.conf /etc/wireguard/
  if [ -f /etc/wireguard/tunnelsatsv2.conf ]; then
    echo "> tunnelsatsv2.conf copied to /etc/wireguard/"
  else
    echo "> ERR: tunnelsatsv2.conf not found in /etc/wireguard/. Please check for errors."
    echo
  fi

  #  Don't paste content if user already has something in there
  check=$(grep -c "Tunnelsats-Setupv2" /etc/wireguard/tunnelsatsv2.conf)

  if [ $isDocker -eq 1 ] && [ $check -eq 0 ]; then
    echo -e $inputDocker 2>/dev/null >>/etc/wireguard/tunnelsatsv2.conf
  elif [ $isDocker -eq 0 ] && [ $check -eq 0 ]; then
    echo -e $inputNonDocker 2>/dev/null >>/etc/wireguard/tunnelsatsv2.conf
  fi

  # check after pasting in the content
  check=$(grep -c "Tunnelsats-Setupv2" /etc/wireguard/tunnelsatsv2.conf)
  if [ $check -eq 1 ]; then
    echo "> network rules applied"
    echo
  else
    echo "> ERR: network rules not applied"
    echo
    exit 1
  fi
fi

sleep 2

if [ $isDocker -eq 0 ]; then

  # setup for cgroup
  # create file
  echo "Creating cgroup tunnelsats-create-cgroup.sh file in /etc/wireguard/..."
  echo "#!/bin/sh
set -e
dir_netcls=\"/sys/fs/cgroup/net_cls\"
splitted_processes=\"/sys/fs/cgroup/net_cls/splitted_processes\"
$modprobe
if [ ! -d \"\$dir_netcls\" ]; then
  mkdir \$dir_netcls
  mount -t cgroup -o net_cls none \$dir_netcls
  echo \"> Successfully added cgroup net_cls subsystem\"
fi
if [ ! -d \"\$splitted_processes\" ]; then
  mkdir /sys/fs/cgroup/net_cls/splitted_processes
  echo 1118498  > /sys/fs/cgroup/net_cls/splitted_processes/net_cls.classid
  chmod 666  /sys/fs/cgroup/net_cls/splitted_processes/tasks
  echo \"> Successfully added Mark for net_cls subsystem\"
else
  echo \"> Mark for net_cls subsystem already present\"
fi
" >/etc/wireguard/tunnelsats-create-cgroup.sh

  chmod +x /etc/wireguard/tunnelsats-create-cgroup.sh

  if [ -f /etc/wireguard/tunnelsats-create-cgroup.sh ]; then
    echo "> /etc/wireguard/tunnelsats-create-cgroup.sh created."
    echo
  else
    echo "> ERR: /etc/wireguard/tunnelsats-create-cgroup.sh was not created. Please check for errors."
    exit 1
  fi

  # run it once
  if [ -f /etc/wireguard/tunnelsats-create-cgroup.sh ]; then
    echo "> tunnelsats-create-cgroup.sh created, executing..."
    # run
    if /etc/wireguard/tunnelsats-create-cgroup.sh; then
      echo "> Created tunnelsats cgroup successfully"
      echo
    else
      echo "> ERR: tunnelsats-create-cgroup.sh execution failed. Please check for errors."
      echo
      exit 1
    fi
  fi

  # enable systemd service
  # create systemd file
  echo "Creating cgroup systemd service..."
  echo "[Unit]
Description=Creating cgroup for Splitting lightning traffic
StartLimitInterval=200
StartLimitBurst=5
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/wireguard/tunnelsats-create-cgroup.sh
[Install]
WantedBy=multi-user.target
" >/etc/systemd/system/tunnelsats-create-cgroup.service

  # enable and start tunnelsats-create-cgroup.service
  if [ -f /etc/systemd/system/tunnelsats-create-cgroup.service ]; then
    systemctl daemon-reload >/dev/null
    if systemctl enable tunnelsats-create-cgroup.service >/dev/null &&
      systemctl start tunnelsats-create-cgroup.service >/dev/null; then
      echo "> tunnelsats-create-cgroup.service: systemd service enabled and started"
      echo
    else
      echo "> ERR: tunnelsats-create-cgroup.service could not be enabled or started. Please check for errors."
      echo
    fi
  else
    echo "> ERR: tunnelsats-create-cgroup.service was not created. Please check for errors."
    echo
    exit 1
  fi

  #Adding tunnelsats-create-cgroup requirement to lnd/cln/lit
  if [ "$lnImplementation" == "lnd" ]; then
    if [ ! -d /etc/systemd/system/lnd.service.d ]; then
      mkdir /etc/systemd/system/lnd.service.d >/dev/null
    fi
    echo "#Don't edit this file its generated by tunnelsats scripts
[Unit]
Description=lnd service - powered by tunnelsats
Requires=tunnelsats-create-cgroup.service
After=tunnelsats-create-cgroup.service
Requires=wg-quick@tunnelsatsv2.service
After=wg-quick@tunnelsatsv2.service
" >/etc/systemd/system/lnd.service.d/tunnelsats-cgroup.conf

    systemctl daemon-reload >/dev/null

  elif [ "$lnImplementation" == "cln" ]; then

    if [ ! -d /etc/systemd/system/lightningd.service.d ]; then
      mkdir /etc/systemd/system/lightningd.service.d >/dev/null
    fi
    echo "#Don't edit this file its generated by tunnelsats scripts
[Unit]
Description=lightningd service - powered by tunnelsats
Requires=tunnelsats-create-cgroup.service
After=tunnelsats-create-cgroup.service
Requires=wg-quick@tunnelsatsv2.service
After=wg-quick@tunnelsatsv2.service
" >/etc/systemd/system/lightningd.service.d/tunnelsats-cgroup.conf

    systemctl daemon-reload >/dev/null

  elif [ "$lnImplementation" == "lit" ]; then

    if [ ! -d /etc/systemd/system/lit.service.d ]; then
      mkdir /etc/systemd/system/lit.service.d >/dev/null
    fi
    echo "#Don't edit this file its generated by tunnelsats scripts
[Unit]
Description=lit service - powered by tunnelsats
Requires=tunnelsats-create-cgroup.service
After=tunnelsats-create-cgroup.service
Requires=wg-quick@tunnelsatsv2.service
After=wg-quick@tunnelsatsv2.service
" >/etc/systemd/system/lit.service.d/tunnelsats-cgroup.conf

    systemctl daemon-reload >/dev/null

  fi

  #Create lightning splitting.service

  # create file
  echo "Creating tunnelsats-splitting-processes.sh file in /etc/wireguard/..."
  echo "#!/bin/sh
# add Lightning pid(s) to cgroup
pgrep -x lnd | xargs -I % sh -c 'echo % >> /sys/fs/cgroup/net_cls/splitted_processes/tasks' &> /dev/null
pgrep -x lightningd | xargs -I % sh -c 'echo % >> /sys/fs/cgroup/net_cls/splitted_processes/tasks' &> /dev/null
count=\$(cat /sys/fs/cgroup/net_cls/splitted_processes/tasks | wc -l)
if [ \$count -eq 0 ];then
  echo \"> no available lightning processes available for tunneling\"
else
  echo \"> \${count} Process(es) successfully excluded\"
fi
" >/etc/wireguard/tunnelsats-splitting-processes.sh

  if [ -f /etc/wireguard/tunnelsats-splitting-processes.sh ]; then
    echo "> /etc/wireguard/tunnelsats-splitting-processes.sh created"
    chmod +x /etc/wireguard/tunnelsats-splitting-processes.sh
  else
    echo "> ERR: /etc/wireguard/tunnelsats-splitting-processes.sh was not created. Please check for errors."
    exit 1
  fi

  # run it once
  if [ -f /etc/wireguard/tunnelsats-splitting-processes.sh ]; then
    echo "> tunnelsats-splitting-processes.sh created, executing..."
    # run
    bash /etc/wireguard/tunnelsats-splitting-processes.sh
    echo "> tunnelsats-splitting-processes.sh successfully executed"
    echo
  else
    echo "> ERR: tunnelsats-splitting-processes.sh execution failed"
    echo
    exit 1
  fi

  # enable systemd service
  # create systemd file
  echo "Creating tunnelsats-splitting-processes systemd service..."
  if [ ! -f /etc/systemd/system/tunnelsats-splitting-processes.sh ]; then

    echo "[Unit]
Description=Adding Lightning Process to the tunnel
[Service]
Type=oneshot
ExecStart=/bin/bash /etc/wireguard/tunnelsats-splitting-processes.sh
[Install]
WantedBy=multi-user.target
" >/etc/systemd/system/tunnelsats-splitting-processes.service

    echo "[Unit]
Description=1min timer for tunnelsats-splitting-processes.service
[Timer]
OnBootSec=10
OnUnitActiveSec=10
Persistent=true
[Install]
WantedBy=timers.target
" >/etc/systemd/system/tunnelsats-splitting-processes.timer

    if [ -f /etc/systemd/system/tunnelsats-splitting-processes.service ]; then
      echo "> tunnelsats-splitting-processes.service created"
    else
      echo "> ERR: tunnelsats-splitting-processes.service not created. Please check for errors."
      echo
      exit 1
    fi

    if [ -f /etc/systemd/system/tunnelsats-splitting-processes.timer ]; then
      echo "> tunnelsats-splitting-processes.timer created"
    else
      echo "> ERR: tunnelsats-splitting-processes.timer not created. Please check for errors."
      echo
      exit 1
    fi
  fi

  # enable and start tunnelsats-splitting-processes.service
  if [ -f /etc/systemd/system/tunnelsats-splitting-processes.service ]; then
    systemctl daemon-reload >/dev/null
    if systemctl enable tunnelsats-splitting-processes.service >/dev/null &&
      systemctl start tunnelsats-splitting-processes.service >/dev/null; then
      echo "> tunnelsats-splitting-processes.service: systemd service enabled and started"
    else
      echo "> ERR: tunnelsats-splitting-processes.service could not be enabled or started. Please check for errors."
      echo
      exit 1
    fi
    # enable timer
    if [ -f /etc/systemd/system/tunnelsats-splitting-processes.timer ]; then
      if systemctl enable tunnelsats-splitting-processes.timer >/dev/null &&
        systemctl start tunnelsats-splitting-processes.timer >/dev/null; then
        echo "> tunnelsats-splitting-processes.timer: systemd timer enabled and started"
        echo
      else
        echo "> ERR: tunnelsats-splitting-processes.timer: systemd timer could not be enabled or started. Please check for errors."
        echo
        exit 1
      fi
    fi
  else
    echo "> ERR: tunnelsats-splitting-processes.service was not created. Please check for errors."
    echo
    exit 1
  fi
  # Raspiblitz new API breaks with tunnelsats and needs a new dependency to the wg tunnelsats interface
  if [ -f /etc/systemd/system/blitzapi.service ]; then

    if [ ! -d /etc/systemd/system/blitzapi.service.d ]; then
      mkdir /etc/systemd/system/blitzapi.service.d >/dev/null
    fi

    echo "#Don't edit this file its generated by tunnelsats scripts
[Unit]
Description=blitzapi needs the wg service before it can start successfully
Requires=wg-quick@tunnelsatsv2.service
After=wg-quick@tunnelsatsv2.service
" >/etc/systemd/system/blitzapi.service.d/tunnelsats-wg.conf

    systemctl daemon-reload >/dev/null

  fi

fi

sleep 2

#Start lightning implementation in cggroup when non docker
#changing respective .service file

if [ $isDocker -eq 0 ]; then

  if [ "$lnImplementation" == "lnd" ]; then

    if [ ! -f /etc/systemd/system/lnd.service.bak ]; then
      cp /etc/systemd/system/lnd.service /etc/systemd/system/lnd.service.bak
    fi

    #Check if lnd.service already has cgexec command included
    check=$(grep -c "cgexec" /etc/systemd/system/lnd.service)
    if [ $check -eq 0 ]; then

      if sed -i 's/ExecStart=/ExecStart=\/usr\/bin\/cgexec -g net_cls:splitted_processes /g' /etc/systemd/system/lnd.service; then
        echo "> lnd.service updated now starts in cgroup tunnelsats"
        echo
        echo "> backup saved under /etc/systemd/system/lnd.service.bak"
        echo
        systemctl daemon-reload >/dev/null
      else
        echo "> ERR: not able to change /etc/systemd/system/lnd.service. Please check for errors."
        echo
      fi

    else
      echo "> /etc/systemd/system/lnd.service already starts in cgroup tunnelsats"
      echo
    fi

  elif [ "$lnImplementation" == "cln" ]; then

    if [ ! -f /etc/systemd/system/lightningd.service.bak ]; then
      cp /etc/systemd/system/lightningd.service /etc/systemd/system/lightningd.service.bak
    fi

    #Check if lightningd.service already has cgexec command included
    check=$(grep -c "cgexec" /etc/systemd/system/lightningd.service)
    if [ $check -eq 0 ]; then
      if sed -i 's/ExecStart=/ExecStart=\/usr\/bin\/cgexec -g net_cls:splitted_processes /g' /etc/systemd/system/lightningd.service; then
        echo "> lightningd.service updated now starts in cgroup tunnelsats"
        echo
        echo "> backup saved under /etc/systemd/system/lightningd.service.bak"
        echo
        systemctl daemon-reload >/dev/null
      else
        echo "> ERR: not able to change /etc/systemd/system/lightningd.service. Please check for errors."
        echo
      fi
    else
      echo "> /etc/systemd/system/lightningd.service already starts in cgroup tunnelsats"
      echo
    fi

  elif [ "$lnImplementation" == "lit" ]; then

    if [ ! -f /etc/systemd/system/lit.service.bak ]; then
      cp /etc/systemd/system/lit.service /etc/systemd/system/lit.service.bak
    fi

    #Check if lit.service already has cgexec command included
    check=$(grep -c "cgexec" /etc/systemd/system/lit.service)
    if [ $check -eq 0 ]; then
      if sed -i 's/ExecStart=/ExecStart=\/usr\/bin\/cgexec -g net_cls:splitted_processes /g' /etc/systemd/system/lit.service; then
        echo "> lit.service updated now starts in cgroup tunnelsats"
        echo
        echo "> backup saved under /etc/systemd/system/lit.service.bak"
        echo
        systemctl daemon-reload >/dev/null
      else
        echo "> ERR: not able to change /etc/systemd/system/lit.service. Please check for errors."
        echo
      fi
    else
      echo "> /etc/systemd/system/lit.service already starts in cgroup tunnelsats"
      echo
    fi

  fi

fi

sleep 2

#Creating Killswitch to prevent any leakage
if [ $isDocker -eq 1 ]; then
  echo "Applying KillSwitch to Docker setup..."
  #Get main interface
  mainif=$(ip route | grep default | cut -d' ' -f5)
  localsubnet="$(hostname -I | awk '{print $1}' | cut -d"." -f1-3)".0/24

  #Get docker umbrel lnd/cln ip address
  dockerlndip=$(grep LND_IP "$HOME"/umbrel/.env 2>/dev/null | cut -d= -f2)
  dockerlndip=${dockerlndip:-"10.21.21.9"}

  if [ -d "$HOME"/umbrel/app-data/core-lightning ]; then
    dockerclnip=$(grep APP_CORE_LIGHTNING_DAEMON_IP "$HOME"/umbrel/app-data/core-lightning/exports.sh | cut -d "\"" -f2)
  else
    dockerclnip=""
  fi

  result=""
  dockertunnelsatsip="10.9.9.9"
  if [ -z "$dockerclnip" ]; then
    result="$dockerlndip"
  else
    result="${dockerlndip}, ${dockerclnip}"
  fi

  if [ -n "$mainif" ]; then

    if [ -f /etc/nftables.conf ] && [ ! -f /etc/nftablespriortunnelsats.backup ]; then
      echo "> Info: tunnelsats replaces the whole /etc/nftables.conf, backup was saved to /etc/nftablespriortunnelsats.backup"
      mv /etc/nftables.conf /etc/nftablespriortunnelsats.backup
    fi

    #Flush table if exist to avoid redundant rules
    if nft list table ip tunnelsatsv2 &>/dev/null; then
      nft flush table ip tunnelsatsv2
    fi

    echo "#!/sbin/nft -f
table ip tunnelsatsv2 {
  set killswitch_tunnelsats {
    type ipv4_addr
    elements = { ${dockertunnelsatsip}, ${result} }
  }
  #block traffic from lighting containers
  chain forward {
    type filter hook forward priority filter -1; policy accept;
    oifname ${mainif} ip daddr != ${localsubnet} ip saddr @killswitch_tunnelsats  meta mark != 0x00001111 counter  drop
  }
  #restrict traffic from the tunnelsats network other than the lightning traffic
  chain input {
    type filter hook input priority filter - 1; policy accept;
    iifname tunnelsatsv2  ct state established,related counter accept
    iifname tunnelsatsv2   tcp dport != 9735 counter drop 
    iifname tunnelsatsv2   udp dport != 9735 counter drop 
  }

  #Allow Access via tailscale/zerotier
  	chain prerouting { 
		type filter hook prerouting priority dstnat - 10; policy accept;
		ip saddr ${dockertunnelsatsip} tcp sport { 8080, 10009 } fib daddr type != local meta mark set 0x00001111 counter
	}

}" >/etc/nftables.conf

    # check application
    check=$(grep -c "tunnelsatsv2" /etc/nftables.conf)
    if [ $check -ne 0 ]; then
      echo "> KillSwitch applied"
      echo
    else
      echo "> ERR: KillSwitch not applied. Please check /etc/nftables.conf"
      echo
      exit 1
    fi

  else
    echo "> ERR: not able to get default routing interface.  Please check for errors."
    echo
    exit 1
  fi

  ## create and enable nftables service
  echo "Initializing nftables..."
  systemctl daemon-reload >/dev/null
  if systemctl enable nftables >/dev/null && systemctl start nftables >/dev/null; then

    if [ -f /etc/systemd/system/umbrel.service ]; then
      if [ ! -d /etc/systemd/system/umbrel.service.d ]; then
        mkdir /etc/systemd/system/umbrel.service.d >/dev/null
      fi

      echo "[Unit]
Description=Forcing wg-quick to start after umbrel startup scripts
# Make sure kill switch is in place before starting umbrel containers
Requires=nftables.service
After=nftables.service
" >/etc/systemd/system/umbrel.service.d/tunnelsats_killswitch.conf
    fi

    if [ -f /etc/systemd/system/umbrel-startup.service ]; then
      if [ ! -d /etc/systemd/system/umbrel-startup.service.d ]; then
        mkdir /etc/systemd/system/umbrel-startup.service.d >/dev/null
      fi

      echo "[Unit]
Description=Forcing wg-quick to start after umbrel startup scripts
# Make sure kill switch is in place before starting umbrel containers
Requires=nftables.service
After=nftables.service
" >/etc/systemd/system/umbrel-startup.service.d/tunnelsats_killswitch.conf
    fi

    #Start nftables service
    systemctl daemon-reload >/dev/null
    systemctl reload nftables >/dev/null
    if [ $? -eq 0 ]; then
      echo "> nftables systemd service started"
    else
      echo "> ERR: nftables service could not be started. Please check for errors."
      echo
      #We exit here to prevent potential ip leakage
      exit 1
    fi

  else
    echo "> ERR: nftables service could not be enabled. Please check for errors."
    echo
    exit 1
  fi

  #Check if kill switch is in place
  checkKillSwitch=$(nft list chain ip tunnelsatsv2 forward | grep -c "oifname")
  if [ $checkKillSwitch -eq 0 ]; then
    echo "> ERR: Killswitch failed to activate. Please check for errors."
    echo
    exit 1
  else
    echo "> Killswitch successfully activated"
    echo
  fi
fi

sleep 2

#Add Monitor which connects the docker-tunnelsats network to the lightning container
if [ $isDocker -eq 1 ]; then
  # create file
  echo "Creating tunnelsats-docker-network.sh file in /etc/wireguard/..."
  echo "#!/bin/sh
#set -e
lightningcontainer=\$(docker ps --format 'table {{.Image}} {{.Names}} {{.Ports}}' | grep 0.0.0.0:9735 | awk '{print \$2}')
checkdockernetwork=\$(docker network ls  2> /dev/null | grep -c \"docker-tunnelsats\")
if [ \$checkdockernetwork -eq 0 ]; then
  if ! docker network create \"docker-tunnelsats\" --subnet \"10.9.9.0/25\" -o \"com.docker.network.driver.mtu\"=\"1420\" >/dev/null; then
    exit 1
  fi
fi
if [ ! -z \$lightningcontainer ]; then
  inspectlncontainer=\$(docker inspect \$lightningcontainer | grep -c \"tunnelsats\")
  if [ \$inspectlncontainer -eq 0 ]; then
    if ! docker network connect --ip 10.9.9.9 docker-tunnelsats \$lightningcontainer >/dev/null; then
      exit 1
    fi
  fi
fi
exit 0" >/etc/wireguard/tunnelsats-docker-network.sh

  if [ -f /etc/wireguard/tunnelsats-docker-network.sh ]; then
    echo "> /etc/wireguard/tunnelsats-docker-network.sh created"
    chmod +x /etc/wireguard/tunnelsats-docker-network.sh
  else
    echo "> ERR: /etc/wireguard/tunnelsats-docker-network.sh was not created. Please check for errors."
    exit 1
  fi

  # run it once
  if [ -f /etc/wireguard/tunnelsats-docker-network.sh ]; then
    echo "> tunnelsats-docker-network.sh created, executing..."
    # run
    bash /etc/wireguard/tunnelsats-docker-network.sh
    echo "> tunnelsats-docker-network.sh successfully executed"
    echo
  else
    echo "> ERR: tunnelsats-docker-network.sh execution failed"
    echo
    exit 1
  fi

  # enable systemd service
  # create systemd file
  echo "Creating tunnelsats-docker-network.sh systemd service..."
  if [ ! -f /etc/systemd/system/tunnelsats-docker-network.sh ]; then
    echo "[Unit]
Description=Adding Lightning Container to the tunnel
StartLimitInterval=200
StartLimitBurst=5
[Service]
Type=oneshot
ExecStart=/bin/bash /etc/wireguard/tunnelsats-docker-network.sh
[Install]
WantedBy=multi-user.target
" >/etc/systemd/system/tunnelsats-docker-network.service

    echo "[Unit]
Description=5min timer for tunnelsats-docker-network.service
[Timer]
OnBootSec=60
OnUnitActiveSec=60
Persistent=true
[Install]
WantedBy=timers.target
" >/etc/systemd/system/tunnelsats-docker-network.timer

    if [ -f /etc/systemd/system/tunnelsats-docker-network.service ]; then
      echo "> tunnelsats-docker-network.service created"
    else
      echo "> ERR: tunnelsats-docker-network.service not created. Please check for errors."
      echo
      exit 1
    fi

    if [ -f /etc/systemd/system/tunnelsats-docker-network.timer ]; then
      echo "> tunnelsats-docker-network.timer created"
    else
      echo "> ERR: tunnelsats-docker-network.timer not created. Please check for errors."
      echo
      exit 1
    fi

  fi

  # enable and start tunnelsats-docker-network.service
  if [ -f /etc/systemd/system/tunnelsats-docker-network.service ]; then
    systemctl daemon-reload >/dev/null
    if systemctl enable tunnelsats-docker-network.service >/dev/null &&
      systemctl start tunnelsats-docker-network.service >/dev/null; then
      echo "> tunnelsats-docker-network.service: systemd service enabled and started"
    else
      echo "> ERR: tunnelsats-docker-network.service could not be enabled or started. Please check for errors."
      echo
      exit 1
    fi
    # Docker: enable timer
    if [ -f /etc/systemd/system/tunnelsats-docker-network.timer ]; then
      if systemctl enable tunnelsats-docker-network.timer >/dev/null &&
        systemctl start tunnelsats-docker-network.timer >/dev/null; then
        echo "> tunnelsats-docker-network.timer: systemd timer enabled and started"
        echo
      else
        echo "> ERR: tunnelsats-docker-network.timer: systemd timer could not be enabled or started. Please check for errors."
        echo
        exit 1
      fi
    fi

  else
    echo "> ERR: tunnelsats-docker-network.service was not created. Please check for errors."
    echo
    exit 1
  fi

fi

sleep 2

## create and enable wireguard service
echo "Initializing the service..."
systemctl daemon-reload >/dev/null
if systemctl enable wg-quick@tunnelsatsv2 >/dev/null; then

  if [ $isDocker -eq 1 ]; then
    if [ -f /etc/systemd/system/umbrel.service ]; then
      if [ ! -d /etc/systemd/system/wg-quick@tunnelsatsv2.service.d ]; then
        mkdir /etc/systemd/system/wg-quick@tunnelsatsv2.service.d >/dev/null
      fi
      echo "[Unit]
Description=Forcing wg-quick to start after umbrel startup scripts
# Make sure to start vpn after umbrel start up to have ln containers available
Requires=umbrel.service
After=umbrel.service
" >/etc/systemd/system/wg-quick@tunnelsatsv2.service.d/tunnelsatsv2.conf
    fi
    if [ -f /etc/systemd/system/umbrel-startup.service ]; then
      if [ ! -d /etc/systemd/system/wg-quick@tunnelsatsv2.service.d ]; then
        mkdir /etc/systemd/system/wg-quick@tunnelsatsv2.service.d >/dev/null
      fi
      echo "[Unit]
Description=Forcing wg-quick to start after umbrel startup scripts
# Make sure to start vpn after umbrel start up to have ln containers available
Requires=umbrel-startup.service
After=umbrel-startup.service
" >/etc/systemd/system/wg-quick@tunnelsatsv2.service.d/tunnelsatsv2.conf
    fi
  fi

  systemctl daemon-reload >/dev/null
  systemctl restart wg-quick@tunnelsatsv2 >/dev/null
  if [ $? -eq 0 ]; then
    echo "> wireguard systemd service enabled and started"
    echo
    if [ -f /etc/systemd/system/blitzapi.service.d/tunnelsats-wg.conf ]; then
      echo "> Restarting blitzapi after successful start of tunnelsats interface"
      systemctl restart blitzapi.service >/dev/null
    fi
  else
    echo "> ERR: wireguard service could not be started. Please check for errors."
    echo
    exit 1
  fi

else
  echo "> ERR: wireguard service could not be enabled. Please check for errors."
  echo
  exit 1
fi

# Create dns-resolver of the wg interface

wget -O /etc/wireguard/tunnelsats-resolve-dns-wg.sh https://raw.githubusercontent.com/Tunnelsats/tunnelsats/main/scripts/resolve-dns-wg.sh
chmod u+x /etc/wireguard/tunnelsats-resolve-dns-wg.sh
if [ $? -ne 0 ]; then
  echo "> ERR: could not fetch tunnelsats-resolve-dns-wg.sh (check source: https://raw.githubusercontent.com/Tunnelsats/tunnelsats/main/scripts/resolve-dns-wg.sh)"
  echo
  exit 1
fi
# Create systemd service
if [ ! -f /etc/systemd/system/tunnelsats-resolve-dns-wg.service ]; then
  echo "[Unit]
Description= tunnelsats-resolve-dns-wg: Trigger Resolve DNS in case Handshake is older than 2 minutes
# Disabling any rate limit
StartLimitInterval=0
[Service]
Type=simple
Restart=on-failure
RestartSec=30
ExecStart=/bin/bash /etc/wireguard/tunnelsats-resolve-dns-wg.sh tunnelsatsv2
[Install]
WantedBy=multi-user.target
" >/etc/systemd/system/tunnelsats-resolve-dns-wg.service

  echo "[Unit]
Description=30sec timer for tunnelsats-resolve-dns-wg.service
[Timer]
OnBootSec=60
OnUnitActiveSec=30
Persistent=true
[Install]
WantedBy=timers.target
" >/etc/systemd/system/tunnelsats-resolve-dns-wg.timer

fi

# enable and start tunnelsats-resolve-dns-wg.service
if [ -f /etc/systemd/system/tunnelsats-resolve-dns-wg.service ]; then
  systemctl daemon-reload >/dev/null
  if systemctl enable tunnelsats-resolve-dns-wg.service >/dev/null &&
    systemctl start tunnelsats-resolve-dns-wg.service >/dev/null; then
    echo "> tunnelsats-resolve-dns-wg.service : systemd service enabled and started"
  else
    echo "> ERR: tunnelsats-resolve-dns-wg.service  could not be enabled or started. Please check for errors."
    echo
    exit 1
  fi
  if [ -f /etc/systemd/system/tunnelsats-resolve-dns-wg.timer ]; then
    if systemctl enable tunnelsats-resolve-dns-wg.timer >/dev/null &&
      systemctl start tunnelsats-resolve-dns-wg.timer >/dev/null; then
      echo "> tunnelsats-resolve-dns-wg.timer: systemd timer enabled and started"
      echo
    else
      echo "> ERR: tunnelsats-resolve-dns-wg.timer: systemd timer could not be enabled or started. Please check for errors."
      echo
      exit 1
    fi
  fi
fi

sleep 2

#Check if tunnel works
echo "Verifying tunnel ..."
if [ $isDocker -eq 0 ]; then
  ipHome=$(curl --silent https://api.ipify.org)
  ipVPN=$(cgexec -g net_cls:splitted_processes curl --silent https://api.ipify.org)
  if [ "$ipHome" != "$ipVPN" ] && valid_ipv4 $ipHome && valid_ipv4 $ipVPN; then
    echo "> Tunnel is  active ✅
    Your ISP external IP: ${ipHome}
    Your Tunnelsats external IP: ${ipVPN}"
    echo
  else
    echo "> ERR: Tunnelsats VPN Interface not successfully activated, check debug logs"
    echo
    exit 1
  fi

else #Docker

  if docker pull curlimages/curl:8.1.1 >/dev/null; then
    ipHome=$(curl --silent https://api.ipify.org)
    ipVPN=$(docker run -ti --rm --net=docker-tunnelsats curlimages/curl:8.1.1 https://api.ipify.org 2>/dev/null)
    if [ "$ipHome" != "$ipVPN" ] && valid_ipv4 $ipHome && valid_ipv4 $ipVPN; then
      echo "> Tunnel is active ✅
      Your ISP external IP: ${ipHome} 
      Your TunnelSats external IP: ${ipVPN}"
      echo
    else
      echo "> ERR: TunnelSats VPN interface not successfully activated, please check debug logs"
      echo
      exit 1
    fi
  else
    echo "> Tunnel verification not checked. curlimages/curl not available for your system "
    echo
    exit 1
  fi

fi

## UFW firewall configuration
vpnExternalPort=$(grep "#VPNPort" /etc/wireguard/tunnelsatsv2.conf | awk '{ print $3 }')
vpnInternalPort="9735"
checkUFW=$(ufw version 2>/dev/null | grep -c "Canonical")
if [ $checkUFW -gt 0 ]; then
  echo "Checking for firewalls and adjusting settings if applicable..."
  ufw allow $vpnInternalPort comment '# VPN Tunnelsats' >/dev/null
  ufw reload >/dev/null
  echo "> ufw detected. VPN port rule added"
  echo
fi

sleep 2

# Instructions
vpnExternalDNS=$(grep "Endpoint" /etc/wireguard/tunnelsatsv2.conf | awk '{ print $3 }' | cut -d ":" -f1)
echo "______________________________________________________________________

These are your personal VPN credentials for your lightning configuration."
echo

# echo "INFO: Tunnel⚡️Sats only support one lightning process on a single node.
# Meaning that running lnd and cln simultaneously via the tunnel will not work.
# Only the process which listens on 9735 will be reachable via the tunnel";echo

if [ "$lnImplementation" == "lnd" ]; then
  if [ $isDocker -eq 0 ]; then

    echo "LND:

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
#########################################"
    echo
  else
    echo "LND on Umbrel 0.5+:

Make a backup and then edit ~/umbrel/app-data/lightning/data/lnd/lnd.conf 
to add or modify the below lines.

Important
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
#########################################"
    echo
  fi
fi

if [ "$lnImplementation" == "lit" ]; then
  if [ $isUmbrel -eq 1 ]; then
  echo "LIT:

Before editing, please create a backup of your current lit.conf config file.
Then edit and add or modify the following lines. Please note that
settings could already be part of your configuration file 
and duplicated lines could lead to errors.

#########################################
[Application Options]
#listen=0.0.0.0:9735
externalhosts=${vpnExternalDNS}:${vpnExternalPort}
[Tor]
tor.streamisolation=false
tor.skip-proxy-for-clearnet-targets=true
#########################################"
  echo

fi

if [ "$lnImplementation" == "cln" ]; then
  if [ $isUmbrel -eq 1 ]; then
  echo "CLN:

Before editing, please create a backup of your current CLN config file.
Then edit and add or modify the following lines. Please note that
settings could already be part of your configuration file
and duplicated lines could lead to errors.

###############################################################################
Umbrel 0.5+:
create CLN config file 'config':
  $ sudo nano ~/umbrel/app-data/core-lightning/data/lightningd/bitcoin/config 
insert:
  bind-addr=0.0.0.0:9735
  announce-addr=${vpnExternalDNS}:${vpnExternalPort}
  always-use-proxy=false

edit 'export.sh':
  $ nano ~/umbrel/app-data/core-lightning/export.sh
change assigned port of APP_CORE_LIGHTNING_DAEMON_PORT from 9736 to 9735:
  export APP_CORE_LIGHTNING_DAEMON_PORT=\"9735\"

edit 'docker-compose.yml':
comment out 'bind-addr' parameter like so
   command:
   ...
   #- --bind-addr=\${APP_CORE_LIGHTNING_DAEMON_IP}:9735  

###############################################################################"

    echo

  else

    echo "CLN:

###############################################################################
Native CLN installation (config file):

  # Tor
  addr=statictor:127.0.0.1:9051/torport=9735
  proxy=127.0.0.1:9050
  always-use-proxy=false

  # VPN
  bind-addr=0.0.0.0:9735
  announce-addr=${vpnExternalDNS}:${vpnExternalPort}
###############################################################################"
    echo

  fi
fi

echo "Please save this info in a file or write them down for later use.

A more detailed guide is available at: https://guide.tunnelsats.com
Afterwards please restart LND / CLN / LIT for changes to take effect.
VPN setup completed!

Welcome to Tunnel⚡Sats.
- Feel free to join the Amboss Community: https://amboss.space/community/29db5f25-24bb-407e-b752-be69f9431071
- Check your clearnet connection functionality and speed: https://t.me/TunnelSatsBot
- Join our Telegram Group: https://t.me/tunnelsats
- Add a reminder on your subscription expiration date: https://t.me/TunnelSatsReminderBot"
echo

if [ $isDocker -eq 0 ]; then
  serviceName="${lnImplementation}"
  if [ "${lnImplementation}" == "cln" ]; then
    serviceName="lightningd"
  elif [ "${lnImplementation}" == "lit" ]; then
    serviceName="lit"
  fi
  echo "Restart ${lnImplementation} afterwards via the command:
    sudo systemctl restart ${serviceName}.service"
  echo
else
  if [ -f /etc/systemd/system/umbrel-startup.service ]; then
    echo "Restart Umbrel afterwards via the command:
      sudo ~/umbrel/scripts/stop
      sudo ~/umbrel/scripts/start"
    echo
  fi
  if [ -f /etc/systemd/system/umbrel.service ]; then
    echo "Restart Umbrel afterwards via the command:
      sudo systemctl restart umbrel.service"
    echo
  fi
fi

# the end
exit 0