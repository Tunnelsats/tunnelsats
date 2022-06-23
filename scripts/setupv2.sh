# This script setup the environment needed for VPN usage on lightning network nodes
# Use with care
#
# Usage: sudo bash setup.sh

# check if sudo
if [ "$EUID" -ne 0 ]
  then echo "Please run as root (with sudo)"
  exit 1
fi

# check if docker
isDocker=0
if [ $(hostname) = "umbrel" ] ||
   [ -f /home/umbrel/umbrel/lnd/lnd.conf ] ||
   [ -d /home/umbrel/umbrel/app-data/lightning ] ||
   [ -d /home/umbrel/umbrel/app-data/core-lightning ] ||
   [ -d /embassy-data/package-data/volumes/lnd ]; then
  isDocker=1
fi

# intro
echo "
##############################
#        TunnelSatsv2        #
#        Setup Script        #
##############################";echo

# check for downloaded tunnelsatsv2.conf, exit if not available
# get current directory
directory=$(dirname -- $(readlink -fn -- "$0"))
echo "Looking for WireGuard config file..."
if [ ! -f $directory/tunnelsatsv2.conf ]; then
  echo "> ERR: tunnelsatsv2.conf not found. Please place it where this script is located.";echo
  exit 1
else
  echo "> tunnelsatsv2.conf found, proceeding.";echo
fi


# RaspiBlitz: deactivate config checks
if [ $(hostname) = "raspberrypi" ] && [ -f /etc/systemd/system/lnd.service ]; then
    if [ -f /home/admin/config.scripts/lnd.check.sh ]; then
        mv /home/admin/config.scripts/lnd.check.sh /home/admin/config.scripts/lnd.check.bak
        echo "RaspiBlitz detected, lnd conf safety check removed";echo
    fi
elif [ $(hostname) = "raspberrypi" ] && [ -f /etc/systemd/system/lightningd.service ]; then
  if [ -f /home/admin/config.scripts/cl.check.sh ]; then
    mv /home/admin/config.scripts/cl.check.sh /home/admin/config.scripts/cl.check.bak
    echo "RaspiBlitz detected, cln conf safety check removed";echo
  fi    
fi

# check requirements and update repos
echo "Checking and installing requirements..."
echo "Updating the package repositories..."
apt-get update > /dev/null;echo

# only non-docker
if [ ! $isDocker ]; then
  # check cgroup-tools only necessary when lightning runs as systemd service
  if [ -f /etc/systemd/system/lnd.service ] || 
     [ -f /etc/systemd/system/lightningd.service ]; then 
      echo "Checking cgroup-tools..."
      checkcgroup=$(cgcreate -h 2> /dev/null | grep -c "Usage")
      if [ $checkcgroup -eq 0 ]; then
          echo "Installing cgroup-tools..."
          if apt-get install -y cgroup-tools > /dev/null; then
              echo "> cgroup-tools installed";echo
          else
              echo "> failed to install cgroup-tools";echo
              exit 1
          fi
      else
          echo "> cgroup-tools found";echo
      fi
  fi
fi

sleep 2

# check nftables
echo "Checking nftables installation..."
checknft=$(nft -v 2> /dev/null | grep -c "nftables")
if [ $checknft -eq 0 ]; then
    echo "Installing nftables..."
    if apt-get install -y nftables > /dev/null; then
        echo "> nftables installed";echo
    else
        echo "> failed to install nftables";echo
        exit 1
    fi
else
    echo "> nftables found";echo
fi

sleep 2

# check wireguard
echo "Checking wireguard installation..."
checkwg=$(wg -v 2> /dev/null | grep -c "wireguard-tools")
if [ ! -f /etc/wireguard ] && [ $checkwg -eq 0 ]; then
    echo "Installing wireguard..."
    if apt-get install -y wireguard > /dev/null; then
        echo "> wireguard installed";echo
    else
        echo "> failed to install wireguard";echo
        exit 1
    fi
else
    echo "> wireguard found";echo
fi

sleep 2

#Create Docker Tunnelsat Network which stays persistent over restarts
if [ $isDocker ]; then 
  
  echo "Creating TunnelSats Docker Network..."
  checkdockernetwork=$(docker network ls  2> /dev/null | grep -c "docker-tunnelsats")
  #the subnet needs a bigger subnetmask (25) than the normal umbrel_mainet subnetmask of 24
  #otherwise the network will not be chosen as the gateway for outside connection
  dockersubnet="10.9.9.0/25"

  if [ $checkdockernetwork -eq 0 ]; then
    docker network create "docker-tunnelsats" --subnet $dockersubnet -o "com.docker.network.driver.mtu"="1420" &> /dev/null
    if [ $? -eq 0 ]; then
      echo "> docker-tunnelsats created successfully";echo
    else 
      echo "> failed to create docker-tunnelsats network";echo
      exit 1
    fi
  else
      echo "> docker-tunnelsats already created";echo
  fi

  #Clean Routing Tables from prior failed wg-quick starts
  delrule1=$(ip rule | grep -c "from all lookup main suppress_prefixlength 0")
  delrule2=$(ip rule | grep -c "from $dockersubnet lookup 51820")
  for i in $( seq 1 $delrule1 )
    do
      ip rule del from all table  main suppress_prefixlength 0
  done

  for i in $( seq 1 $delrule2 )
    do
      ip rule del from $dockersubnet table 51820
  done

  #Flush any rules which are still present from failed interface starts
  ip route flush table 51820

else
  #Delete Rules for non-docker setup
  #Clean Routing Tables from prior failed wg-quick starts
  delrule1=$(ip rule | grep -c "from all lookup main suppress_prefixlength 0")
  delrule2=$(ip rule | grep -c "from all fwmark 0xdeadbeef lookup 51820")
  for i in $( seq 1 $delrule1 )
    do
      ip rule del from all table  main suppress_prefixlength 0
  done

  for i in $( seq 1 $delrule2 )
    do
      ip rule del from all fwmark 0xdeadbeef table  51820
  done

   #Flush any rules which are still present from failed interface starts
  ip route flush table 51820

fi

sleep 2

# edit tunnelsats.conf, add PostUp/Down rules
# and copy to destination folder
echo "Applying network rules to wireguard conf file..."
inputDocker="
[Interface]
FwMark = 0x3333
Table = off

PostUp = ip rule add from \$(docker network inspect \"docker-tunnelsats\" | grep Subnet | awk '{print \$2}' | sed 's/[\",]//g') table 51820;ip rule add from all table main suppress_prefixlength 0
PostUp = ip route add blackhole default metric 3 table 51820;
PostUp = ip route add default dev %i metric 2 table 51820

PostUp = sysctl -w net.ipv4.conf.all.rp_filter=0
PostUp = sysctl -w net.ipv6.conf.all.disable_ipv6=1
PostUp = sysctl -w net.ipv6.conf.default.disable_ipv6=1
PostUp = docker network connect --ip 10.9.9.9  \"docker-tunnelsats\" \$(docker ps --format 'table {{.Image}} {{.Names}} {{.Ports}}' | grep 9735 | awk '{print \$2}')

PostDown = ip rule del from \$(docker network inspect \"docker-tunnelsats\" | grep Subnet | awk '{print \$2}' | sed 's/[\",]//g') table 51820
PostDown = ip rule del from all table  main suppress_prefixlength 0
PostDown = ip route flush table 51820
PostDown = sysctl -w net.ipv4.conf.all.rp_filter=1
PostDown = docker network disconnect docker-tunnelsats \$(docker ps --format 'table {{.Image}} {{.Names}} {{.Ports}}' | grep 9735 | awk '{print \$2}')
"
inputNonDocker="
[Interface]
FwMark = 0x3333
Table = off

PostUp = ip rule add from all fwmark 0xdeadbeef table 51820;ip rule add from all table main suppress_prefixlength 0
PostUp = ip route add default dev %i table 51820;
PostUp = sysctl -w net.ipv4.conf.all.rp_filter=0
PostUp = sysctl -w net.ipv6.conf.all.disable_ipv6=1
PostUp = sysctl -w net.ipv6.conf.default.disable_ipv6=1

PostUp = nft add table inet %i
PostUp = nft add chain inet %i prerouting '{type filter hook prerouting priority mangle; policy accept;}'; nft add rule inet %i prerouting meta mark set ct mark
PostUp = nft add chain inet %i mangle '{type route hook output priority mangle; policy accept;}'; nft add rule inet %i mangle meta mark != 0x3333 meta cgroup 1118498 meta mark set 0xdeadbeef
PostUp = nft add chain inet %i nat'{type nat hook postrouting priority srcnat; policy accept;}'; nft insert rule inet %i nat fib saddr type != local oif != %i ct mark 0xdeadbeef drop;nft add rule inet %i nat oif != "lo" ct mark 0xdeadbeef masquerade
PostUp = nft add chain inet %i postroutingmangle'{type filter hook postrouting priority mangle; policy accept;}'; nft add rule inet %i postroutingmangle meta mark 0xdeadbeef ct mark set meta mark

PostDown = nft delete table inet %i
PostDown = ip rule del from all table  main suppress_prefixlength 0; ip rule del not from all fwmark 0xdeadbeef table 51820
PostDown = ip route flush table 51820
PostDown = sysctl -w net.ipv4.conf.all.rp_filter=1
"

directory=$(dirname -- $(readlink -fn -- "$0"))
if [ -f $directory/tunnelsatsv2.conf ]; then
  line=$(grep -n "#VPNPort" $directory/tunnelsatsv2.conf | cut -d ":" -f1)
  if [ $line != "" ]; then
    line="$(($line+1))"
    
    if [ $isDocker ]; then
      echo -e $inputDocker 2> /dev/null >> $directory/tunnelsatsv2.conf
    else
      echo -e $inputNonDocker 2> /dev/null >> $directory/tunnelsatsv2.conf
    fi
  fi
  # check
  check=$(grep -c "FwMark" $directory/tunnelsatsv2.conf)
  if [ $check -gt 0 ]; then
    echo "> network rules applied"
    cp $directory/tunnelsatsv2.conf /etc/wireguard/
    if [ -f /etc/wireguard/tunnelsatsv2.conf ]; then
      echo "> tunnelsatsv2.conf copied to /etc/wireguard/";echo
    else
      echo "> ERR: tunnelsatsv2.conf not found in /etc/wireguard/. Please check for errors.";echo
    fi    
  else
    echo "> ERR: network rules not applied";echo
  fi
fi


sleep 2


if [ ! $isDocker ]; then

  # setup lnd/clnfor splitting
  # create file
  echo "Creating lightning splitting.sh file in /etc/wireguard/..."
  echo "#!/bin/sh
set -e
dir_netcls=\"/sys/fs/cgroup/net_cls\"
torsplitting=\"/sys/fs/cgroup/net_cls/splitted_processes\"
modprobe cls_cgroup
if [ ! -d \"\$dir_netcls\" ]; then
  mkdir \$dir_netcls
  mount -t cgroup -o net_cls none \$dir_netcls
  echo \"> Successfully added cgroup net_cls subsystem\"
fi
if [ ! -d \"\$torsplitting\" ]; then
  mkdir /sys/fs/cgroup/net_cls/splitted_processes
  echo 1118498  > /sys/fs/cgroup/net_cls/splitted_processes/net_cls.classid
  echo \"> Successfully added Mark for net_cls subsystem\"
else
  echo \"> Mark for net_cls subsystem already present\"
fi
# add Lightning pid(s) to cgroup
pgrep -x lnd | xargs -I % sh -c 'echo % >> /sys/fs/cgroup/net_cls/splitted_processes/tasks' > /dev/null
pgrep -x lightningd | xargs -I % sh -c 'echo % >> /sys/fs/cgroup/net_cls/splitted_processes/tasks' > /dev/null

count=\$(cat /sys/fs/cgroup/net_cls/splitted_processes/tasks | wc -l)
if [ \$count -eq 0 ];then
  echo \"> ERR: no pids added to file\"
  exit 1
else
  echo \"> \${count} Process(es) successfully excluded\"
fi
" > /etc/wireguard/splitting.sh

  if [ -f /etc/wireguard/splitting.sh ]; then
    echo "> /etc/wireguard/splitting.sh created.";echo
  else
    echo "> ERR: /etc/wireguard/splitting.sh was not created. Please check for errors.";
    exit 1
  fi

  # run it once
  if [ -f /etc/wireguard/splitting.sh ]; then
      echo "> splitting.sh created, executing...";
      # run
      bash /etc/wireguard/splitting.sh
      echo "> Split-tunneling successfully executed";echo
  else
      echo "> ERR: splitting.sh execution failed";echo
      exit 1
  fi


  # enable systemd service
  # create systemd file
  echo "Creating splitting systemd service..."
  # LND
  if [ ! -f /etc/systemd/system/splitting.service ] && [ -f /etc/systemd/system/lnd.service ]; then
      echo "[Unit]
Description=Splitting Lightning Traffic after Restart
# Make sure it starts when lightning service is running (thats why restart settings are crucial here)
Requires=lnd.service
After=lnd.service
StartLimitInterval=200
StartLimitBurst=5
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/bash /etc/wireguard/splitting.sh
[Install]
WantedBy=multi-user.target
" > /etc/systemd/system/splitting.service
  elif  [ ! -f /etc/systemd/system/splitting.service ] && [ -f /etc/systemd/system/lightningd.service ]; then
      echo "[Unit]
Description=Splitting Lightning Traffic after Restart
# Make sure it starts when lightning service is running (thats why restart settings are crucial here)
Requires=lightningd.service
After=lightningd.service
StartLimitInterval=200
StartLimitBurst=5
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/bash /etc/wireguard/splitting.sh
[Install]
WantedBy=multi-user.target
" > /etc/systemd/system/splitting.service
  fi

  # enable and start splitting.service
  if [ -f /etc/systemd/system/splitting.service ]; then
    systemctl daemon-reload > /dev/null
    if systemctl enable splitting.service > /dev/null &&
       systemctl start splitting.service > /dev/null; then
       echo "> splitting.service: systemd service enabled and started";echo
    else
       echo "> ERR: splitting.service could not be enabled or started. Please check for errors.";echo
    fi
  else
    echo "> ERR: splitting.service was not created. Please check for errors.";echo
    exit 1
  fi
fi


sleep 2


#Creating Killswitch to prevent any leakage
if [ $isDocker ]; then
  echo "Applying KillSwitch to Docker setup..."
  #Get main interface  
  mainif=$(ip route | grep default | cut -d' ' -f5)

  #Get docker umbrel lnd/cln ip address

  dockerlndip=$(grep LND_IP /home/umbrel/umbrel/.env | cut -d= -f2)
  if [ -d /home/umbrel/umbrel/app-data/core-lightning ]; then
    dockerclnip=$(grep APP_CORE_LIGHTNING_IP /home/umbrel/umbrel/app-data/core-lightning/exports.sh | cut -d "\"" -f2)
  else
    dockerclnip=""
  fi
  
  result=""
  if [ ${dockerclnip} = "" ]; then
    result=${dockerlndip}
  else
    result="${dockerlndip}, ${dockerclnip}"
  fi

  if [ ! -z $mainif ] ; then

    if [ -f /etc/nftables.conf  ]; then 
    echo "table inet tunnelsatsv2 {
  set killswitch_tunnelsats {
		type ipv4_addr
		elements = { $result }
	}
  #block traffic from lighting containers
  chain forward {
    type filter hook forward priority filter; policy accept;
    oifname $mainif ip saddr @killswitch_tunnelsats counter  drop
  }
}" >>  /etc/nftables.conf
    else
      echo "#!/sbin/nft -f
  table inet tunnelsatsv2 {
  set killswitch_tunnelsats {
		type ipv4_addr
		elements = { $result }
	}
  #block traffic from lighting containers
  chain forward {
    type filter hook forward priority filter; policy accept;
    oifname $mainif ip saddr @killswitch_tunnelsats counter  drop
  }
}" >  /etc/nftables.conf
    fi
    
    # check application
    check=$(grep -c "tunnelsatsv2" /etc/nftables.conf)
    if [ $check -ne 0 ]; then
      echo "> KillSwitch applied";echo
    else
      echo "> ERR: KillSwitch not applied. Please check /etc/nftables.conf";echo
      exit 1
    fi
    
  else
    echo "> ERR: not able to get default routing interface.  Please check for errors.";echo
    exit 1
  fi


  ## create and enable nftables service
  echo "Initializing nftables..."
  systemctl daemon-reload > /dev/null
  if systemctl enable nftables > /dev/null && systemctl start nftables > /dev/null; then


      if [ ! -d /etc/systemd/system/umbrel-startup.service.d ]; then
          mkdir /etc/systemd/system/umbrel-startup.service.d > /dev/null
      fi 
      echo "[Unit]
    Description=Forcing wg-quick to start after umbrel startup scripts
    # Make sure kill switch is in place before starting umbrel containers
    Requires=nftables.service
    After=nftables.service
    " > /etc/systemd/system/umbrel-startup.service.d/tunnelsats_killswitch.conf 
    
    #Start nftables service
    systemctl daemon-reload
    systemctl start nftables > /dev/null; 
    if [ $? -eq 0 ]; then
      echo "> nftables systemd service started";echo
    else 
      echo "> ERR: nftables service could not be started. Please check for errors.";echo
      #We exit here to prevent potential ip leakage
      exit 1
    fi

  else
    echo "> ERR: nftables service could not be enabled. Please check for errors.";echo
    exit 1
  fi
fi

sleep 2

#Add Monitor which connects the docker-tunnelsats network to the lightning container
if [ $isDocker ]; then
  # create file
  echo "Creating tunnelsats-docker-network.sh file in /etc/wireguard/..."
  echo "#!/bin/sh
  #set -e
  lightningcontainer=\$(docker ps --format 'table {{.Image}} {{.Names}} {{.Ports}}' | grep 9735 | awk '{print \$2}'

  checkdockernetwork=\$(docker network ls  2> /dev/null | grep -c \"docker-tunnelsats\")

  if [ \$checkdockernetwork -ne 0 ] && [ -z \$lightningcontainer ]
    docker network connect docker-tunnelsats \$lightningcontainer
  fi

  " > /etc/wireguard/tunnelsats-docker-network.sh 
  if [ -f /etc/wireguard/tunnelsats-docker-network.sh ]; then
    echo "> /etc/wireguard/tunnelsats-docker-network.sh created.";echo
  else
    echo "> ERR: /etc/wireguard/tunnelsats-docker-network.sh was not created. Please check for errors.";
    exit 1
  fi

  # run it once
  if [ -f /etc/wireguard/tunnelsats-docker-network.sh ]; then
      echo "> tunnelsats-docker-network.sh created, executing...";
      # run
      bash /etc/wireguard/tunnelsats-docker-network.sh
      echo "> tunnelsats-docker-network.sh successfully executed";echo
  else
      echo "> ERR: tunnelsats-docker-network.sh execution failed";echo
      exit 1
  fi

  # enable systemd service
  # create systemd file
  echo "Creating tunnelsats-docker-network.sh systemd service..."
  if [ ! -f /etc/systemd/system/tunnelsats-docker-network.sh ]; then
    # if we are on Umbrel || Start9 (Docker solutions), create a timer to restart and re-check Tor/ssh pids
    if  $isDocker then
      echo "[Unit]
  Description=Adding Lightning Container to the tunnel
  StartLimitInterval=200
  StartLimitBurst=5
  [Service]
  Type=oneshot
  ExecStart=/bin/bash /etc/wireguard/tunnelsats-docker-network.sh
  [Install]
  WantedBy=multi-user.target
  " > /etc/systemd/system/tunnelsats-docker-network.service

      echo "[Unit]
  Description=5min timer for tunnelsats-docker-network.service
  [Timer]
  OnBootSec=60
  OnUnitActiveSec=300
  Persistent=true
  [Install]
  WantedBy=timers.target
      " > /etc/systemd/system/tunnelsats-docker-network.timer
      
      if [ -f /etc/systemd/system/tunnelsats-docker-network.service ]; then
        echo "> tunnelsats-docker-network.service created"
      else
        echo "> ERR: tunnelsats-docker-network.service not created. Please check for errors.";echo
      fi
      if [ -f /etc/systemd/system/tunnelsats-docker-network.timer ]; then
        echo "> tunnelsats-docker-network.timer created";echo
      else
        echo "> ERR: tunnelsats-docker-network.timer not created. Please check for errors.";echo
      fi

    fi
  fi

fi
# enable and start tunnelsats-docker-network.service
if [ -f /etc/systemd/system/tunnelsats-docker-network.service ]; then
  systemctl daemon-reload > /dev/null
  if systemctl enable tunnelsats-docker-network.service > /dev/null &&
     systemctl start tunnelsats-docker-network.service > /dev/null; then
    echo "> tunnelsats-docker-network.service: systemd service enabled and started";echo
  else
    echo "> ERR: tunnelsats-docker-network.service could not be enabled or started. Please check for errors.";echo
  fi
    # Docker: enable timer
  if [ -f /etc/systemd/system/tunnelsats-docker-network.timer ]; then
    if systemctl enable tunnelsats-docker-network.timer > /dev/null &&
       systemctl start tunnelsats-docker-network.timer > /dev/null; then
      echo "> tunnelsats-docker-network.timer: systemd timer enabled and started";echo
    else
      echo "> ERR: tunnelsats-docker-network.timer: systemd timer could not be enabled or started. Please check for errors.";echo
    fi
  fi
else
  echo "> ERR: tunnelsats-docker-network.service was not created. Please check for errors.";echo
  exit 1
fi

sleep 2






## create and enable wireguard service
echo "Initializing the service..."
systemctl daemon-reload > /dev/null
if systemctl enable wg-quick@tunnelsatsv2 > /dev/null; then

  if [ $isDocker ] && [ -f /etc/systemd/system/umbrel-startup.service ]; then
     mkdir /etc/systemd/system/wg-quick@tunnelsatsv2.service.d > /dev/null
       echo "[Unit]
Description=Forcing wg-quick to start after umbrel startup scripts
# Make sure to start vpn after umbrel start up to have lnd containers available
Requires=umbrel-startup.service
After=umbrel-startup.service
" > /etc/systemd/system/wg-quick@tunnelsatsv2.service.d/tunnelsatsv2.conf 
  fi
  systemctl daemon-reload
  systemctl start wg-quick@tunnelsatsv2 > /dev/null; 
  if [ $? -eq 0 ]; then
    echo "> wireguard systemd service enabled and started";echo
  else 
    echo "> ERR: wireguard service could not be started. Please check for errors.";echo
  fi
else
  echo "> ERR: wireguard service could not be enabled. Please check for errors.";echo
fi

sleep 2

#Check if tunnel works
echo "Verifying tunnel ..."
if [ ! $isDocker ]; then
  ipHome=$(curl --silent https://api.ipify.org)
  ipVPN=$(cgexec -g net_cls:splitted_processes curl --silent https://api.ipify.org)
  if [ "$ipHome" != "$ipVPN" ]; then
      echo "> Tunnel is active
      Your ISP external IP: ${ipHome} 
      Your Tunnelsats external IP: ${ipVPN}";echo
  else
    echo "> ERR: Tunnelsats VPN Interface not successfully activated, check debug logs";echo
    exit 1
  fi
  
else #Docker

  if docker pull curlimages/curl &> /dev/null; then
      echo "> Tunnel Verification not checked bc appropriate/curl not available on your system ";echo
  else
    ipHome=$(curl --silent https://api.ipify.org)
    ipVPN=$(docker run -ti --rm --net=docker-tunnelsats appropriate/curl https://api.ipify.org &> /dev/null)
  fi
  
  if [ "$ipHome" != "$ipVPN" ]; then
      echo "> Tunnel is active
      Your ISP external IP: ${ipHome} 
      Your Tunnelsats external IP: ${ipVPN}";echo
  else
      echo "> ERR: Tunnelsats VPN Interface not successfully activated, check debug logs";echo
      exit 1
  fi
fi

## UFW firewall configuration
vpnExternalPort=$(grep "#VPNPort" /etc/wireguard/tunnelsatsv2.conf | awk '{ print $3 }')
vpnInternalPort="9735"
echo "Checking for firewalls and adjusting settings if applicable...";
checkufw=$(ufw version 2> /dev/null | grep -c "Canonical")
if [ $checkufw -gt 0 ]; then
   ufw disable > /dev/null
   ufw allow $vpnInternalPort comment '# VPN Tunnelsats' > /dev/null
   ufw --force enable > /dev/null
   echo "> ufw detected. VPN port rule added";echo
else
   echo "> ufw not detected";echo
fi


# Instructions
vpnExternalIP=$(grep "Endpoint" /etc/wireguard/tunnelsatsv2.conf | awk '{ print $3 }' | cut -d ":" -f1)

echo "These are your personal VPN credentials for your lightning configuration.";echo

echo "LND:
#########################################
[Application Options]
listen=0.0.0.0:9735
externalip=${vpnExternalIP}:${vpnExternalPort}
[Tor]
tor.streamisolation=false
tor.skip-proxy-for-clearnet-targets=true
#########################################";echo

echo "CLN:
#########################################
bind-addr=0.0.0.0:9735
announce-addr=${vpnExternalIP}:${vpnExternalPort}
always-use-proxy=false
#########################################";echo

echo "Please save them in a file or write them down for later use.

A more detailed guide is available at: https://blckbx.github.io/tunnelsats/

Afterwards please restart LND / CLN for changes to take effect.
VPN setup completed!";echo

# the end
exit 0
