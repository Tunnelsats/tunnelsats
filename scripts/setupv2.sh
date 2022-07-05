#!/bin/bash
# This script setup the environment needed for VPN usage on lightning network nodes
# Use with care
#
# Usage: sudo bash setup.sh

#VERSION NUMBER of setupv2.sh
#Update if your make a significant change
##########UPDATE IF YOU MAKE A NEW RELEASE#############
major=0
minor=0 
patch=6


#Helper
function valid_ipv4()
{
    local  ip=$1
    local  stat=1

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
            && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

# check if sudo
if [ "$EUID" -ne 0 ]
  then echo "Please run as root (with sudo)"
  exit 1
fi

# check if docker
isDocker=0
if [ "$(hostname)" == "umbrel" ] || \
   [ -f /home/umbrel/umbrel/lnd/lnd.conf ] || \
   [ -d /home/umbrel/umbrel/app-data/lightning ] || \
   [ -d /home/umbrel/umbrel/app-data/core-lightning ] || \
   [ -d /embassy-data/package-data/volumes/lnd ]; then
  isDocker=1
fi

# intro
echo -e "
###############################
         TunnelSats v2        
         Setup Script         
         Version:             
         v$major.$minor.$patch
###############################";echo


# Check which implementation the user wants to tunnel

lnImplementation=""

while true
do
    read -p "Which lightning implementation do you want to tunnel? Supported are LND and CLN for now ⚡️:" answer


  case $answer in
      lnd|LND* ) echo "> Setting up Tunneling for LND on port 9735 ";echo
                 lnImplementation="lnd"
                 break;;

      cln|CLN* )  echo "> Setting up Tunneling for CLN on port 9735 ";echo
                  lnImplementation="cln"
                  break;;
             * ) echo "Enter LND or CLN, please.";;
  esac
done



# check for downloaded tunnelsatsv2.conf, exit if not available
# get current directory
directory=$(dirname -- "$(readlink -fn -- "$0")")
echo "Looking for WireGuard config file..."
if [ ! -f "$directory"/tunnelsatsv2.conf ]; then
  echo "> ERR: tunnelsatsv2.conf not found. Please place it where this script is located.";echo
  exit 1
else
  echo "> tunnelsatsv2.conf found, proceeding.";echo
fi


# RaspiBlitz: deactivate config checks
if [ "$(hostname)" == "raspberrypi" ] && [ "$lnImplementation" == "lnd" ]; then
    if [ -f /home/admin/config.scripts/lnd.check.sh ]; then
        mv /home/admin/config.scripts/lnd.check.sh /home/admin/config.scripts/lnd.check.bak
        echo "RaspiBlitz detected, lnd conf safety check removed";echo
    fi
elif [ "$(hostname)" == "raspberrypi" ] && [ "$lnImplementation" == "cln" ]; then
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
if [ $isDocker -eq 0 ]; then
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
if [ $checkwg -eq 0 ]; then
    echo "Installing wireguard..."
    
    # Debian 10 Buster workaround / RaspiBlitz / myNode
    codename=$(lsb_release -c 2> /dev/null | awk '{print $2}')
    if [ "$codename" == "buster" ]; then
    	if apt-get install -y -t buster-backports wireguard > /dev/null; then
 	    echo "> wireguard installed";echo
        else
	    echo "> failed to install wireguard";echo
	    exit 1
	fi	
    else  # everyone else
    	if apt-get install -y wireguard > /dev/null; then
        	echo "> wireguard installed";echo
    	else
        	echo "> failed to install wireguard";echo
        	exit 1
    	fi
    fi
    
else
    echo "> wireguard found";echo
fi

sleep 2

#Create Docker Tunnelsat Network which stays persistent over restarts
if [ $isDocker -eq 1 ]; then 
  
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
  ip route flush table 51820 &> /dev/null


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
echo "Copy wireguard conf file to /etc/wireguard and apply network rules..."
inputDocker="\n
[Interface]\n
FwMark = 0x3333\n
Table = off\n
\n
PostUp = ip rule add from \$(docker network inspect \"docker-tunnelsats\" | grep Subnet | awk '{print \$2}' | sed 's/[\",]//g') table 51820\n
PostUp = ip rule add from all table main suppress_prefixlength 0\n
PostUp = ip route add blackhole default metric 3 table 51820\n
PostUp = ip route add default dev %i metric 2 table 51820\n
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
[Interface]\n
FwMark = 0x3333\n
Table = off\n
\n
PostUp = ip rule add from all fwmark 0xdeadbeef table 51820;ip rule add from all table main suppress_prefixlength 0\n
PostUp = ip route add default dev %i table 51820;\n
PostUp = sysctl -w net.ipv4.conf.all.rp_filter=0\n
PostUp = sysctl -w net.ipv6.conf.all.disable_ipv6=1\n
PostUp = sysctl -w net.ipv6.conf.default.disable_ipv6=1\n
\n
PostUp = nft add table ip %i\n
PostUp = nft add chain ip %i prerouting '{type filter hook prerouting priority mangle; policy accept;}'; nft add rule ip %i prerouting meta mark set ct mark\n
PostUp = nft add chain ip %i mangle '{type route hook output priority mangle; policy accept;}'; nft add rule ip %i mangle meta mark != 0x3333 meta cgroup 1118498 meta mark set 0xdeadbeef\n
PostUp = nft add chain ip %i nat'{type nat hook postrouting priority srcnat; policy accept;}'; nft insert rule ip %i nat fib saddr type != local oif != %i ct mark 0xdeadbeef drop;nft add rule ip %i nat oif != \"lo\" ct mark 0xdeadbeef masquerade\n
PostUp = nft add chain ip %i postroutingmangle'{type filter hook postrouting priority mangle; policy accept;}'; nft add rule ip %i postroutingmangle meta mark 0xdeadbeef ct mark set meta mark\n
\n
PostDown = nft delete table ip %i\n
PostDown = ip rule del from all table  main suppress_prefixlength 0; ip rule del not from all fwmark 0xdeadbeef table 51820\n
PostDown = ip route flush table 51820\n
PostDown = sysctl -w net.ipv4.conf.all.rp_filter=1\n
"

directory=$(dirname -- "$(readlink -fn -- "$0")")
if [ -f "$directory"/tunnelsatsv2.conf ]; then
  cp "$directory"/tunnelsatsv2.conf /etc/wireguard/
  if [ -f /etc/wireguard/tunnelsatsv2.conf ]; then
    echo "> tunnelsatsv2.conf copied to /etc/wireguard/"
  else
    echo "> ERR: tunnelsatsv2.conf not found in /etc/wireguard/. Please check for errors.";echo
  fi   

  line=$(grep -n "#VPNPort" /etc/wireguard/tunnelsatsv2.conf | cut -d ":" -f1)
  if [ "$line" != "" ]; then
    line="$(($line+1))"
    
    if [ $isDocker -eq 1 ]; then
      echo -e $inputDocker 2> /dev/null >> /etc/wireguard/tunnelsatsv2.conf
    else
      echo -e $inputNonDocker 2> /dev/null >> /etc/wireguard/tunnelsatsv2.conf
    fi
  fi
  # check
  check=$(grep -c "FwMark" /etc/wireguard/tunnelsatsv2.conf)
  if [ $check -gt 0 ]; then
    echo "> network rules applied";echo
  else
    echo "> ERR: network rules not applied";echo
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
modprobe cls_cgroup
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
" > /etc/wireguard/tunnelsats-create-cgroup.sh

chmod +x /etc/wireguard/tunnelsats-create-cgroup.sh

  if [ -f /etc/wireguard/tunnelsats-create-cgroup.sh ]; then
    echo "> /etc/wireguard/tunnelsats-create-cgroup.sh created.";echo
  else
    echo "> ERR: /etc/wireguard/tunnelsats-create-cgroup.sh was not created. Please check for errors.";
    exit 1
  fi

  # run it once
  if [ -f /etc/wireguard/tunnelsats-create-cgroup.sh ]; then
      echo "> tunnelsats-create-cgroup.sh created, executing...";
      # run
      bash /etc/wireguard/tunnelsats-create-cgroup.sh
      echo "> Created tunnelsats cgroup successfully";echo
  else
      echo "> ERR: tunnelsats-create-cgroup.sh execution failed";echo
      exit 1
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
    ExecStart=/usr/bin/bash /etc/wireguard/tunnelsats-create-cgroup.sh
    [Install]
    WantedBy=multi-user.target
    " > /etc/systemd/system/tunnelsats-create-cgroup.service

  # enable and start tunnelsats-create-cgroup.service
  if [ -f /etc/systemd/system/tunnelsats-create-cgroup.service ]; then
    systemctl daemon-reload > /dev/null
    if systemctl enable tunnelsats-create-cgroup.service > /dev/null && \
       systemctl start tunnelsats-create-cgroup.service > /dev/null; then
       echo "> tunnelsats-create-cgroup.service: systemd service enabled and started";echo
    else
       echo "> ERR: tunnelsats-create-cgroup.service could not be enabled or started. Please check for errors.";echo
    fi
  else
    echo "> ERR: tunnelsats-create-cgroup.service was not created. Please check for errors.";echo
    exit 1
  fi

    #Adding tunnelsats-create-cgroup requirement to lnd/cln
  if [ "$lnImplementation" == "lnd"  ]; then
      if [ ! -d /etc/systemd/system/lnd.service.d ]; then
          mkdir /etc/systemd/system/lnd.service.d > /dev/null
      fi 
      echo "#Don't edit this file its generated by tunnelsats scripts
      [Unit]
    Description=lnd needs cgroup before it can start
    Requires=tunnelsats-create-cgroup.service
    After=tunnelsats-create-cgroup.service
    " > /etc/systemd/system/lnd.service.d/tunnelsats-cgroup.conf 
    
    systemctl daemon-reload

  

  elif [ "$lnImplementation" == "cln"  ]; then

     if [ ! -d /etc/systemd/system/lightningd.service.d ]; then
          mkdir /etc/systemd/system/lightningd.service.d > /dev/null
      fi 
      echo "#Don't edit this file its generated by tunnelsats scripts
      [Unit]
    Description=lightningd needs cgroup before it can start
    Requires=tunnelsats-create-cgroup.service
    After=tunnelsats-create-cgroup.service
    " > /etc/systemd/system/lightningd.service.d/tunnelsats-cgroup.conf 


    systemctl daemon-reload
   
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
  
  " > /etc/wireguard/tunnelsats-splitting-processes.sh 

  chmod +x /etc/wireguard/tunnelsats-splitting-processes.sh
  
  if [ -f /etc/wireguard/tunnelsats-splitting-processes.sh ]; then
    echo "> /etc/wireguard/tunnelsats-splitting-processes.sh created"
    chmod +x /etc/wireguard/tunnelsats-splitting-processes.sh
  else
    echo "> ERR: /etc/wireguard/tunnelsats-splitting-processes.sh was not created. Please check for errors."
    exit 1
  fi

  # run it once
  if [ -f /etc/wireguard/tunnelsats-splitting-processes.sh ]; then
      echo "> tunnelsats-splitting-processes.sh created, executing...";
      # run
      bash /etc/wireguard/tunnelsats-splitting-processes.sh
      echo "> tunnelsats-splitting-processes.sh successfully executed";echo
  else
      echo "> ERR: tunnelsats-splitting-processes.sh execution failed";echo
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
  " > /etc/systemd/system/tunnelsats-splitting-processes.service

      echo "[Unit]
  Description=1min timer for tunnelsats-splitting-processes.service
  [Timer]
  OnBootSec=10
  OnUnitActiveSec=10
  Persistent=true
  [Install]
  WantedBy=timers.target
      " > /etc/systemd/system/tunnelsats-splitting-processes.timer
      
      if [ -f /etc/systemd/system/tunnelsats-splitting-processes.service ]; then
        echo "> tunnelsats-splitting-processes.service created"
      else
        echo "> ERR: tunnelsats-splitting-processes.service not created. Please check for errors.";echo
	    exit 1
      fi
      if [ -f /etc/systemd/system/tunnelsats-splitting-processes.timer ]; then
        echo "> tunnelsats-splitting-processes.timer created"
      else
        echo "> ERR: tunnelsats-splitting-processes.timer not created. Please check for errors.";echo
	    exit 1
      fi

  fi  

  # enable and start tunnelsats-docker-network.service
  if [ -f /etc/systemd/system/tunnelsats-splitting-processes.service ]; then
    systemctl daemon-reload > /dev/null
    if systemctl enable tunnelsats-splitting-processes.service > /dev/null && \
      systemctl start tunnelsats-splitting-processes.service > /dev/null; then
      echo "> tunnelsats-splitting-processes.servicee: systemd service enabled and started"
    else
      echo "> ERR: tunnelsats-splitting-processes.service could not be enabled or started. Please check for errors.";echo
      exit 1
    fi
      # Docker: enable timer
    if [ -f /etc/systemd/system/tunnelsats-splitting-processes.timer ]; then
      if systemctl enable tunnelsats-splitting-processes.timer > /dev/null && \
        systemctl start tunnelsats-splitting-processes.timer > /dev/null; then
        echo "> tunnelsats-splitting-processes.timer: systemd timer enabled and started";echo
      else
        echo "> ERR: tunnelsats-splitting-processes.timer: systemd timer could not be enabled or started. Please check for errors.";echo
        exit 1
      fi
    fi
  else
    echo "> ERR: tunnelsats-splitting-processes.service was not created. Please check for errors.";echo
    exit 1
  fi


fi

sleep 2



#Start lightning implementation in cggroup when non docker
#changing respective .service file

if [ $isDocker -eq 0 ]; then

  if [ "$lnImplementation" == "lnd"  ]; then

   if  [ ! -f /etc/systemd/system/lnd.service.bak ]; then
      cp /etc/systemd/system/lnd.service /etc/systemd/system/lnd.service.bak
   fi

   #Check if lnd.service already has cgexec command included

    check=$(grep -c "cgexec" /etc/systemd/system/lnd.service)

    if [ $check -eq 0 ]; then 


      if sed -i 's/ExecStart=/ExecStart=\/usr\/bin\/cgexec -g net_cls:splitted_processes /g' /etc/systemd/system/lnd.service ; then
          echo "> lnd.service updated now starts in cgroup tunnelsats";echo
          echo "> backup saved under /etc/systemd/system/lnd.service.bak";echo
          systemctl daemon-reload 
      else
          echo "> ERR: not able to change /etc/systemd/system/lnd.service. Please check for errors.";echo
      fi

    else
          echo "> /etc/systemd/system/lnd.service already  starts in cgroup tunnelsats";echo
    fi

  elif [ "$lnImplementation" == "cln"  ]; then

    if  [ ! -f /etc/systemd/system/lightningd.service.bak ]; then
      cp /etc/systemd/system/lightningd.service /etc/systemd/system/lightningd.service.bak
    fi

    #Check if lightningd.service already has cgexec command included

    check=$(grep -c "cgexec" /etc/systemd/system/lightningd.service)

    if [ $check -eq 0 ]; then 


        if sed -i 's/ExecStart=/ExecStart=\/usr\/bin\/cgexec -g net_cls:splitted_processes /g' /etc/systemd/system/lightningd.service ; then
          echo "> lightningd.service updated now starts in cgroup tunnelsats";echo
          echo "> backup saved under /etc/systemd/system/lightningd.service.bak";echo
          systemctl daemon-reload 
        else
          echo "> ERR: not able to change /etc/systemd/system/lightningd.service. Please check for errors.";echo
        fi
    else
        echo "> /etc/systemd/system/lightningd.service already starts in cgroup tunnelsats";echo
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

  dockerlndip=$(grep LND_IP /home/umbrel/umbrel/.env | cut -d= -f2)
  if [ -d /home/umbrel/umbrel/app-data/core-lightning ]; then
    dockerclnip=$(grep APP_CORE_LIGHTNING_DAEMON_IP /home/umbrel/umbrel/app-data/core-lightning/exports.sh | cut -d "\"" -f2)
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

  if [ -n "$mainif" ] ; then

    if [ -f /etc/nftables.conf ] && [ ! -f /etc/nftablespriortunnelsats.backup ]; then

      echo "> Info: tunnelsats replaces the whole /etc/nftables.conf, backup was saved to /etc/nftablespriortunnelsats.backup"

      mv /etc/nftables.conf /etc/nftablespriortunnelsats.backup
  
   fi
   #Flush table if exist to avoid redundant rules
   if nft list table ip tunnelsatsv2 &> /dev/null; then
      nft flush table ip tunnelsatsv2
   fi

        echo "#!/sbin/nft -f
    table ip tunnelsatsv2 {
    set killswitch_tunnelsats {
      type ipv4_addr
      elements = { $dockertunnelsatsip, $result }
    }
    #block traffic from lighting containers
    chain forward {
      type filter hook forward priority filter; policy accept;
      oifname $mainif ip daddr != $localsubnet ip saddr @killswitch_tunnelsats counter  drop
    }
  }" >  /etc/nftables.conf
    
    
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
    systemctl reload nftables > /dev/null; 
    if [ $? -eq 0 ]; then
      echo "> nftables systemd service started"
    else 
      echo "> ERR: nftables service could not be started. Please check for errors.";echo
      #We exit here to prevent potential ip leakage
      exit 1
    fi

  else
    echo "> ERR: nftables service could not be enabled. Please check for errors.";echo
    exit 1
  fi

  #Check if kill switch is in place
  checkKillSwitch=$(nft list chain ip tunnelsatsv2 forward | grep -c "oifname")
  if [ $checkKillSwitch -eq 0 ]; then
    echo "> ERR: Killswitch failed to activate. Please check for errors.";echo
    exit 1
  else
      echo "> Killswitch successfully activated";echo
  fi
fi

sleep 2

#Add Monitor which connects the docker-tunnelsats network to the lightning container
if [ $isDocker -eq 1 ]; then
  # create file
  echo "Creating tunnelsats-docker-network.sh file in /etc/wireguard/..."
  echo "#!/bin/sh
  set -e
  lightningcontainer=\$(docker ps --format 'table {{.Image}} {{.Names}} {{.Ports}}' | grep 9735 | awk '{print \$2}')
  checkdockernetwork=\$(docker network ls  2> /dev/null | grep -c \"docker-tunnelsats\")
  if [ \$checkdockernetwork -ne 0 ] && [ ! -z \$lightningcontainer ]; then
    if ! docker inspect \$lightningcontainer | grep -c \"tunnelsats\" > /dev/null; then
    docker network connect --ip 10.9.9.9 docker-tunnelsats \$lightningcontainer  &> /dev/null
    fi
  fi
  " > /etc/wireguard/tunnelsats-docker-network.sh 
  
  if [ -f /etc/wireguard/tunnelsats-docker-network.sh ]; then
    echo "> /etc/wireguard/tunnelsats-docker-network.sh created"
    chmod +x /etc/wireguard/tunnelsats-docker-network.sh
  else
    echo "> ERR: /etc/wireguard/tunnelsats-docker-network.sh was not created. Please check for errors."
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
    if [ $isDocker -eq 1 ]; then
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
	    exit 1
      fi
      if [ -f /etc/systemd/system/tunnelsats-docker-network.timer ]; then
        echo "> tunnelsats-docker-network.timer created"
      else
        echo "> ERR: tunnelsats-docker-network.timer not created. Please check for errors.";echo
	    exit 1
      fi

    fi

  fi

  # enable and start tunnelsats-docker-network.service
  if [ -f /etc/systemd/system/tunnelsats-docker-network.service ]; then
    systemctl daemon-reload > /dev/null
    if systemctl enable tunnelsats-docker-network.service > /dev/null && \
      systemctl start tunnelsats-docker-network.service > /dev/null; then
      echo "> tunnelsats-docker-network.service: systemd service enabled and started"
    else
      echo "> ERR: tunnelsats-docker-network.service could not be enabled or started. Please check for errors.";echo
      exit 1
    fi
      # Docker: enable timer
    if [ -f /etc/systemd/system/tunnelsats-docker-network.timer ]; then
      if systemctl enable tunnelsats-docker-network.timer > /dev/null && \
        systemctl start tunnelsats-docker-network.timer > /dev/null; then
        echo "> tunnelsats-docker-network.timer: systemd timer enabled and started";echo
      else
        echo "> ERR: tunnelsats-docker-network.timer: systemd timer could not be enabled or started. Please check for errors.";echo
        exit 1
      fi
    fi
  else
    echo "> ERR: tunnelsats-docker-network.service was not created. Please check for errors.";echo
    exit 1
  fi

fi

sleep 2


## create and enable wireguard service
echo "Initializing the service..."
systemctl daemon-reload > /dev/null
if systemctl enable wg-quick@tunnelsatsv2 > /dev/null; then

  if [ $isDocker -eq 1 ] && [ -f /etc/systemd/system/umbrel-startup.service ]; then
    if [ ! -d /etc/systemd/system/wg-quick@tunnelsatsv2.service.d ]; then
      mkdir /etc/systemd/system/wg-quick@tunnelsatsv2.service.d > /dev/null
    fi
    echo "[Unit]
Description=Forcing wg-quick to start after umbrel startup scripts
# Make sure to start vpn after umbrel start up to have lnd containers available
Requires=umbrel-startup.service
After=umbrel-startup.service
" > /etc/systemd/system/wg-quick@tunnelsatsv2.service.d/tunnelsatsv2.conf 
  fi
  systemctl daemon-reload
  systemctl restart wg-quick@tunnelsatsv2 > /dev/null; 
  if [ $? -eq 0 ]; then
    echo "> wireguard systemd service enabled and started";echo
  else 
    echo "> ERR: wireguard service could not be started. Please check for errors.";echo
    exit 1
  fi
else
  echo "> ERR: wireguard service could not be enabled. Please check for errors.";echo
  exit 1
fi

sleep 2

#Check if tunnel works
echo "Verifying tunnel ..."
if [ $isDocker -eq 0 ]; then
  ipHome=$(curl --silent https://api.ipify.org)
  ipVPN=$(cgexec -g net_cls:splitted_processes curl --silent https://api.ipify.org)
  if [ "$ipHome" != "$ipVPN" ] && valid_ipv4 $ipHome  &&  valid_ipv4 $ipVPN ; then
      echo "> Tunnel is  active ✅
      Your ISP external IP: ${ipHome} 
      Your Tunnelsats external IP: ${ipVPN}";echo
  else
    echo "> ERR: Tunnelsats VPN Interface not successfully activated, check debug logs";echo
    exit 1
  fi
  
else #Docker

  if docker pull curlimages/curl > /dev/null; then
    ipHome=$(curl --silent https://api.ipify.org)
    ipVPN=$(docker run -ti --rm --net=docker-tunnelsats curlimages/curl https://api.ipify.org 2> /dev/null)
    if [ "$ipHome" != "$ipVPN" ] && valid_ipv4 $ipHome  &&  valid_ipv4 $ipVPN  ; then
      echo "> Tunnel is active ✅
      Your ISP external IP: ${ipHome} 
      Your TunnelSats external IP: ${ipVPN}";echo
    else
      echo "> ERR: TunnelSats VPN interface not successfully activated, please check debug logs";echo
      exit 1
    fi    
  else
    echo "> Tunnel verification not checked. curlimages/curl not available for your system ";echo
    exit 1
  fi
fi

## UFW firewall configuration
vpnExternalPort=$(grep "#VPNPort" /etc/wireguard/tunnelsatsv2.conf | awk '{ print $3 }')
vpnInternalPort="9735"
checkufw=$(ufw version 2> /dev/null | grep -c "Canonical")
if [ $checkufw -gt 0 ]; then
   echo "Checking for firewalls and adjusting settings if applicable...";
   ufw disable > /dev/null
   ufw allow $vpnInternalPort comment '# VPN Tunnelsats' > /dev/null
   ufw --force enable > /dev/null
   echo "> ufw detected. VPN port rule added";echo
fi

sleep 2

# Instructions
vpnExternalIP=$(grep "Endpoint" /etc/wireguard/tunnelsatsv2.conf | awk '{ print $3 }' | cut -d ":" -f1)

echo "______________________________________________________________________

These are your personal VPN credentials for your lightning configuration.";echo

# echo "INFO: Tunnel⚡️Sats only support one lightning process on a single node.
# Meaning that running lnd and cln simultaneously via the tunnel will not work.
# Only the process which listens on 9735 will be reachable via the tunnel";echo 


if [ "$lnImplementation" == "lnd"  ]; then 

  echo "LND:
  #########################################
  [Application Options]
  listen=0.0.0.0:9735
  externalip=${vpnExternalIP}:${vpnExternalPort}
  [Tor]
  tor.streamisolation=false
  tor.skip-proxy-for-clearnet-targets=true
  #########################################";echo

fi 

if [ "$lnImplementation" == "cln"  ]; then 

  echo "CLN:
  ###############################################################################
  Umbrel 0.5+
  (edit /home/umbrel/umbrel/app-data/core-lightning/docker-compose.yml file 
  in section 'lightningd' - 'command' as follows):
  comment out the following line: 
  #- --bind-addr=${APP_CORE_LIGHTNING_DAEMON_IP}:9735
  add the following lines:
  - --bind-addr=0.0.0.0:9735
  - --announce-addr=${vpnExternalIP}:${vpnExternalPort}
  - --always-use-proxy=false

  Native CLN (config file):
  bind-addr=0.0.0.0:9735
  announce-addr=${vpnExternalIP}:${vpnExternalPort}
  always-use-proxy=false
  ###############################################################################";echo

fi

echo "Please save them in a file or write them down for later use.

A more detailed guide is available at: https://blckbx.github.io/tunnelsats/
Afterwards please restart LND / CLN for changes to take effect.
VPN setup completed!";echo


if [ $isDocker -eq 0 ]; then

    echo "Restart lnd|cln afterwards via the command:
    sudo systemctl restart lightningd.service|lnd.service";echo
  else
     echo "Restart lnd|cln on umbrel afterwards via the command:
      sudo /home/umbrel/umbrel/scripts/stop (umbrel)
      sudo /home/umbrel/umbrel/scripts/start (umbrel)";echo
fi


# the end
exit 0
