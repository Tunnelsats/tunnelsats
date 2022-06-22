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

  checkdockernetwork=$(docker network ls  2> /dev/null | grep -c "docker-tunnelsats")
  #the subnet needs a bigger subnetmask (25) than the normal umbrel_mainet subnetmask of 24
  #otherwise the network will not be chosen as the gateway for outside connection
  dockersubnet="10.9.9.0/25"

  if [ $checkdockernetwork -eq 0 ];
    docker network create "docker-tunnelsats" --subnet $dockersubnet -o "com.docker.network.driver.mtu"="1420" &> /dev/null
    if [ $? -eq 0 ];
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




# edit tunnelsats.conf, add PostUp/Down rules
# and copy to destination folder
echo "Applying network rules to wireguard conf file..."
inputDocker="
FwMark = 0x3333
Table = off

PostUp = ip rule add from \$(docker network inspect \"docker-tunnelsats\" | grep Subnet | awk '{print \$2}' | sed 's/[\",]//g') table 51820;ip rule add from all table main suppress_prefixlength 0
PostUp = ip route add blackhole default metric 3 table 51820;
PostUp = ip route add default dev %i metric 2 table 51820
PostUp = sysctl -w net.ipv4.conf.all.rp_filter=0
PostUp = sysctl -w net.ipv6.conf.all.disable_ipv6=1
PostUp = sysctl -w net.ipv6.conf.default.disable_ipv6=1
PostUp = docker network connect \"docker-tunnelsats\" \$(docker ps --format 'table {{.Image}}\t{{.Names}}\t{{.Ports}}' | grep 9735 | awk '{print \$2}')

PostDown = ip rule del from \$(docker network inspect \"docker-tunnelsats\" | grep Subnet | awk '{print \$2}' | sed 's/[\",]//g') table 51820
PostDown = ip rule del from all table  main suppress_prefixlength 0
PostDown = ip route flush table 51820
PostDown = sysctl -w net.ipv4.conf.all.rp_filter=1
PostDown = docker network disconnect docker-tunnelsats \$(docker ps --format 'table {{.Image}}\t{{.Names}}\t{{.Ports}}' | grep 9735 | awk '{print \$2}')
"
inputNonDocker="
FwMark = 0x3333
Table = off

PostUp = ip rule add from all fwmark 0xdeadbeef table 51820;ip rule add from all table main suppress_prefixlength 0
PostUp = ip route add default dev %i table 51820;
PostUp = sysctl -w net.ipv4.conf.all.rp_filter=0
PostUp = sysctl -w net.ipv6.conf.all.disable_ipv6=1
PostUp = sysctl -w net.ipv6.conf.default.disable_ipv6=1

#Firewall nftable rules
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
  line=$(grep -n "#VPNPort" | cut -d ":" -f1)
  line="$(($line+1))"
  if [ $line != "" ]; then
    if [ $isDocker ]; then
      sed -i "${line}i${inputDocker}" $directory/tunnelsatsv2.conf
    else
      sed -i "${line}i${inputNonDocker}" $directory/tunnelsatsv2.conf
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
    if [ -f /etc/wireguard/splitting.sh ];then
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

    sleep 2

fi


#Creating Killswitch to prevent any leakage

#Get main interface
mainif=$(ip route | grep default | cut -d' ' -f5)

if [ $isDocker ]; then

  if [ ! -z $mainif ] ; then

    if [ -f /etc/nftables.conf  ]; then 
    echo "table inet tunnelsatsv2 {
    #block traffic until the setup is up
    chain output {
      type filter hook output priority filter; policy accept;
      oifname mainif ip daddr != $(hostname -I | awk '{print $1}' | cut -d"." -f1-3).0/24 fib daddr type != local drop
    }
      " >  /etc/nftables.conf
    else
      echo "#!/sbin/nft -f
      table inet tunnelsatsv2 {
      #block traffic until the setup is up
      chain output {
      type filter hook output priority filter; policy accept;
      oifname mainif ip daddr != $(hostname -I | awk '{print $1}' | cut -d"." -f1-3).0/24 fib daddr type != local drop
      }

      " >>  /etc/nftables.conf

  else
    echo "> ERR: not able to get default routing interface.  Please check for errors.";echo
    exit 1
  fi
fi

## create and enable nftables service
echo "Initializing the service..."
systemctl daemon-reload > /dev/null
if  sudo systemctl enable nftables > /dev/null; then

  if [ $isDocker ]; then

    if [ -d /etc/systemd/system/umbrel-startup.service.d ]
        mkdir /etc/systemd/system/umbrel-startup.service.d > /dev/null
    fi 
       echo "[Unit]
    Description=Forcing wg-quick to start after umbrel startup scripts
    # Make sure kill switch is in place before starting umbrel containers
    Requires=nftables.service
    After=nftables.service
    " > /etc/systemd/system/umbrel-startup.service.d/tunnelsats_killswitch.conf 
  fi


else
  echo "> ERR: nftables service could not be enabled. Please check for errors.";echo
  exit 1
fi





## create and enable wireguard service
echo "Initializing the service..."
systemctl daemon-reload > /dev/null
if systemctl enable wg-quick@tunnelsatsv2 > /dev/null; then

  if [ $isDocker ]; then
     mkdir /etc/systemd/system/wg-quick@tunnelsatsv2.service.d > /dev/null
       echo "[Unit]
    Description=Forcing wg-quick to start after umbrel startup scripts
    # Make sure to start vpn after umbrel start up to have lnd containers available
    Requires=umbrel-startup.service
    After=umbrel-startup.service
    ExecStartPost=/usr/sbin/nft delete table inet tunnelsatsv2
    " > /etc/systemd/system/wg-quick@tunnelsatsv2.service.d/tunnelsatsv2.conf 
  fi

  systemctl start wg-quick@tunnelsatsv2 > /dev/null; 
  if [ $? -eq 0 ]; then
    echo "> wireguard systemd service enabled and started";echo
  else 
    echo "> ERR: wireguard service could not be started. Please check for errors.";echo
  fi
else
  echo "> ERR: wireguard service could not be enabled. Please check for errors.";echo
fi


if [ ! $isDocker ]; then 
  #Check if tunnel works
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
else

  docker pull appropriate/curl
  if [ $? -ne 0 ]; then
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
