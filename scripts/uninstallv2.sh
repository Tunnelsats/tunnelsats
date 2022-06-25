#!/bin/bash
# This script uninstalls/removes the changes made by setup.sh script
# Use with care
#
# Usage: sudo bash uninstall.sh

# check if sudo
if [ "$EUID" -ne 0 ]
then echo "Please run as root (with sudo)";echo
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
#       TunnelSats v2        #
#      Uninstall Script      #
##############################";echo


# remove splitting.timer systemd (v1)
if [ -f /etc/systemd/system/splitting.timer ]; then
  echo "Removing splitting systemd timer...";
  systemctl stop splitting.timer > /dev/null
  systemctl disable splitting.timer > /dev/null
  rm /etc/systemd/system/splitting.timer > /dev/null
  echo "> splitting.timer: removed";echo
fi

# remove splitting.service systemd
if [ -f /etc/systemd/system/splitting.service ]; then
  echo "Removing splitting systemd service...";
  systemctl stop splitting.service > /dev/null
  systemctl disable splitting.service > /dev/null
  rm /etc/systemd/system/splitting.service > /dev/null
  echo "> splitting.service: removed";echo
fi

sleep 2

# remove timer and systemd services
if [ $isDocker ]; then
 
  if [ -f /etc/systemd/system/tunnelsats-docker-network.timer ]; then
    echo "Removing tunnelsats docker network timer..."
    systemctl stop tunnelsats-docker-network.timer > /dev/null
    systemctl disable tunnelsats-docker-network.timer > /dev/null
    rm /etc/systemd/system/tunnelsats-docker-network.timer > /dev/null
    echo "> tunnelsats docker network timer removed";echo
  fi
  
  if [ -f /etc/systemd/system/tunnelsats-docker-network.service ]; then
    echo "Removing tunnelsats docker network service..."
    systemctl stop tunnelsats-docker-network.service > /dev/null
    systemctl disable tunnelsats-docker-network.service > /dev/null
    rm /etc/systemd/system/tunnelsats-docker-network.service > /dev/null
    echo "> tunnelsats docker network timer removed";echo
  fi

fi

sleep 2


# remove ufw setting (port rule)
checkufw=$(ufw version 2> /dev/null | grep -c Canonical)
if [ $checkufw -eq 1 ]; then
  vpnExternalPort="$(grep "#VPNPort" /etc/wireguard/tunnelsatsv2.conf | awk '{ print $3 }')" > /dev/null
  echo "Checking firewall and removing VPN port..."
  ufw disable > /dev/null
  ufw delete allow from any to any port $vpnExternalPort comment '# VPN Tunnelsats' > /dev/null
  ufw --force enable > /dev/null
  echo "> VPN rule removed";echo
fi

sleep 2

# remove wg-quick@tunnelsats service
if [ -f /lib/systemd/system/wg-quick@.service ]; then
  echo "Removing wireguard systemd service..."
  # remove v1
  if [ -f /etc/wireguard/tunnelsats.conf ]; then
    wg-quick down tunnelsats > /dev/null
    systemctl stop wg-quick@tunnelsats > /dev/null
    systemctl disable wg-quick@tunnelsats > /dev/null
  fi
  
  if wg-quick down tunnelsatsv2 > /dev/null &&
     systemctl stop wg-quick@tunnelsatsv2 > /dev/null &&
     systemctl disable wg-quick@tunnelsatsv2 > /dev/null &&
     [ ! -f /etc/systemd/systemd/wg-quick@tunnelsatsv2 ]; then
    echo "> wireguard systemd service disabled and removed";echo
  else
    echo "> ERR: could not remove /etc/systemd/systemd/wg-quick@tunnelsatsv2. Please check manually.";echo
  fi
fi

sleep 2


# remove wg-quick@tunnelsatsv2.service.d
if [ -d /etc/systemd/system/wg-quick@tunnelsatsv2.service.d  ] && [ $isDocker ]; then
  echo "Removing wg-quick@tunnelsatsv2.service.d..."
  if rm -r /etc/systemd/system/wg-quick@tunnelsatsv2.service.d; then
    echo "> /etc/systemd/system/wg-quick@tunnelsatsv2.service.d removed";echo
  else
    echo "> ERR: could not remove /etc/systemd/systemd/wg-quick@tunnelsatsv2.service.d. Please check manually.";echo
  fi
fi

sleep 2


#remove docker-tunnelsats network
if [ $isDocker ]; then
  #Disconnect all containers from the network first
  #Removing rules from routing table
  echo "Removing tunnelsats specific routing rules..."  
  ip route flush table 51820

  echo "Disconnecting containers from docker-tunnelsats network..."  
  docker inspect docker-tunnelsats | jq .[].Containers | grep Name | sed 's/[\",]//g' | awk '{print $2}' | xargs -I % sh -c 'docker network disconnect docker-tunnelsats  %'
  
  checkdockernetwork=$(docker network ls  2> /dev/null | grep -c "docker-tunnelsats")
  if [ $checkdockernetwork -ne 0 ]; then 
    echo "Removing docker-tunnelsats network..."  
    if docker network rm "docker-tunnelsats" > /dev/null; then
      echo "> docker-tunnelsats network removed";echo
    else
      echo "> ERR: could not remove docker-tunnelsats network. Please check manually.";echo
    fi
  fi
fi

sleep 2

# remove killswitch requirement for umbrel startup
if [ -f /etc/systemd/system/umbrel-startup.service.d/tunnelsats_killswitch.conf  ] && [ $isDocker ]; then
  echo "Removing tunnelsats_killswitch.conf..."
  if rm /etc/systemd/system/umbrel-startup.service.d/tunnelsats_killswitch.conf ; then
    rm -r /etc/systemd/system/umbrel-startup.service.d > /dev/null
    echo "> /etc/systemd/system/umbrel-startup.service.d/tunnelsats_killswitch.conf  removed";echo
  else
    echo "> ERR: could not remove /etc/systemd/system/umbrel-startup.service.d/tunnelsats_killswitch.conf . Please check manually.";echo
  fi
fi

sleep 2

#reset lnd
if [ ! $isDocker ] && [ -f /etc/systemd/system/lnd.service.bak ]; then
  if mv /etc/systemd/system/lnd.service.bak /etc/systemd/system/lnd.service; then
    echo "> lnd.service prior to tunnelsats successfully reset";echo
  else 
    echo "> ERR: Not able to reset /etc/systemd/system/lnd.service Please check manually.";echo
  fi
fi


#reset lightningd
if [ ! $isDocker ] && [ -f /etc/systemd/system/lightnind.service.bak ]; then
  if mv /etc/systemd/system/lightnind.service.bak /etc/systemd/system/lightingd.service; then
    echo "> lightningd.service prior to tunnelsats successfully reset";echo
  else 
    echo "> ERR: Not able to reset /etc/systemd/system/lightningd.service Please check manually.";echo
  fi
fi


# remove netcls subgroup
if [ ! $isDocker ]; then
    echo "Removing net_cls subgroup..."
    # v1
    if [ -f /sys/fs/cgroup/net_cls/tor_splitting/tasks ]; then
        cgdelete net_cls:/tor_splitting 2> /dev/null
    fi

    if cgdelete net_cls:/splitted_processes 2> /dev/null; then
        echo "> Control Group Splitted Processes removed";echo
    else
        echo "> ERR: Could not remove cgroup.";echo
    fi
fi


#Flush nftables and enable old nftables.conf
#Flush table if exist to avoid redundant rules
if nft list table inet tunnelsatsv2 &> /dev/null; then
    echo "> Flushing tunnelsats nftable rules";echo
    nft flush table inet tunnelsatsv2
fi

if [  -f /etc/nftablespriortunnelsats.backup ]; then
     mv /etc/nftablespriortunnelsats.backup /etc/nftables.conf 
      echo "> Prior nftables.conf now active. To enable it restart nftables.service or restart system ";echo
fi

sleep 2

# uninstall cgroup-tools, nftables, wireguard
kickoffs='✅Yes ⛔️Cancel'
if [ $isDocker ]; then
  PS3='Do you really want to uninstall nftables and wireguard via apt remove? '
else
  PS3='Do you really want to uninstall cgroup-tools, nftables and wireguard via apt remove? '
fi

select kickoff in $kickoffs
do
   if [ $kickoff == '⛔️Cancel' ]
   then
     echo
     break
   else
     echo
     if [[ $isDocker ]] && apt-get remove -yqq nftables wireguard-tools || apt-get remove -yqq cgroup-tools nftables wireguard-tools; then
       echo "> Packages removed";echo
     else
       echo "> ERR: packages could not be removed. Please check manually.";echo
     fi
   fi
break
done


# Make sure to disable hybrid mode to prevent IP leakage
echo "Trying to automatically detect setup and deactivate hybrid mode..."
# check setup
path="null"
imp="null"
if [ -f /mnt/hdd/lnd/lnd.conf ]; then #RaspiBlitz
  path="/mnt/hdd/lnd/lnd.conf"
  imp="lnd"
elif [ -f /mnt/hdd/app-data/.lightning/config ]; then
  path="/mnt/hdd/app-data/.lightning/config"
  imp="cln"
elif [ -f /home/umbrel/umbrel/lnd/lnd.conf ]; then #Umbrel < 0.5
  path="/home/umbrel/umbrel/lnd/lnd.conf"
  imp="lnd"
elif [ -f /home/umbrel/umbrel/app-data/lightning/data/lnd/lnd.conf ]; then #Umbrel 0.5+
  path="/home/umbrel/umbrel/app-data/lightning/data/lnd/lnd.conf"
  imp="lnd"
elif [ -f /data/lnd/lnd.conf ]; then #RaspiBolt
  path="/data/lnd/lnd.conf"
  imp="lnd"
elif [ -f /embassy-data/package-data/volumes/lnd/data/main/lnd.conf ]; then #Start9
 path="/embassy-data/package-data/volumes/lnd/data/main/lnd.conf"
 imp="lnd"
elif [ -f /mnt/hdd/mynode/lnd/lnd.conf ]; then #myNode
 path="/mnt/hdd/mynode/lnd/lnd.conf"
 imp="lnd"
fi

# RaspiBlitz: try to recover cl/lnd.check.sh and run it once
if [ $(hostname) = "raspberrypi" ] && [ -f /etc/systemd/system/lnd.service ]; then
    echo "RaspiBlitz: Trying to restore safety check 'lnd.check.sh'..."
    if [ -f /home/admin/config.scripts/lnd.check.bak ]; then
      mv /home/admin/config.scripts/lnd.check.bak /home/admin/config.scripts/lnd.check.sh
      bash /home/admin/config.scripts/lnd.check.sh > /dev/null
      echo "> Safety check for lnd.conf found and restored";echo
    else
      echo "> Backup of 'lnd.check.sh' not found";echo
    fi
elif [ $(hostname) = "raspberrypi" ] && [ -f /etc/systemd/system/lightningd.service ]; then
  if [ -f /home/admin/config.scripts/cl.check.bak ]; then
    mv /home/admin/config.scripts/cl.check.bak /home/admin/config.scripts/cl.check.sh
    bash /home/admin/config.scripts/cl.check.sh
    echo "> Safety check for cln config found and restored";echo
  else
    echo "> Backup of 'cl.check.sh' not found";echo
  fi    
fi

# try to modify lnd config file
success=0
if [ $path != "null" ] && [ $imp = "lnd" ]; then

  check=$(grep -c "tor.skip-proxy-for-clearnet-targets=true" $path > /dev/null)
  if [ $check -gt 0 ]; then
    lines=$(grep -n "tor.skip-proxy-for-clearnet-targets=true" $path > /dev/null)
    for i in $lines
    do
      sed '{i}d' $path > /dev/null
    done
  fi
  
  # recheck again
  checkAgain=$(grep -c "tor.skip-proxy-for-clearnet-targets=true" $path > /dev/null)
  if [ ! $checkAgain ]; then
    success=1
    echo "> Hybrid Mode deactivated.";echo
  else
    echo "> Could not deactivate hybrid mode!! Please check your LND configuration file and set 'tor.skip-proxy-for-clearnet-targets=false' before restarting!!";echo
  fi
  
fi

# check CLN (Umbrel 0.5)
umbrelPath="/home/umbrel/umbrel/app-data/core-lightning/docker-compose.yml"
if [ -f $umbrelPath ]; then

  line=$(grep -n "\- \-\-always-use-proxy=false" $umbrelPath | cut -d ':' -f1> /dev/null)
  if [ "${line}" != "" ]; then
    sed -i 's/always-use-proxy=false/always-use-proxy=true/g' $umbrelPath > /dev/null
  fi 
  
  # recheck again
  checkAgain=$(grep -c "always-use-proxy=true" $umbrelPath > /dev/null)
  if [ $checkAgain ]; then
    success=1
    echo "> Hybrid Mode deactivated.";echo
  else
    echo "> Could not deactivate hybrid mode!! Please check your CLN configuration file and set 'always-use-proxy=true' before restarting!!";echo
  fi
  
fi

# check CLN (RaspiBlitz) - recovery via cl.check.sh failed
if [ $path = "/mnt/hdd/app-data/.lightning/config" ] && [ $imp = "cln" ]; then
  
  line=$(grep -n "always-use-proxy=false" $path > /dev/null)
  if [ "${line}" != "" ]; then
    sed -i 's/always-use-proxy=false/always-use-proxy=true/g' $path > /dev/null
  fi
  
  # recheck again
  checkAgain=$(grep -c "always-use-proxy=true" $path > /dev/null)
  if [ $checkAgain ]; then
    success=1
    echo "> Hybrid Mode deactivated.";echo
  else
    echo "> Could not deactivate hybrid mode!! Please check your CLN configuration file and set 'always-use-proxy=true' before restarting!!";echo
  fi  
  
fi


# ask user if we should restart nonDocker automatically
if [ $success ]; then
  
    kickoffs='Yes No'
    PS3='Do you want to automatically restart lightning service now? '

    select kickoff in $kickoffs
    do
       if [ $kickoff == 'No' ]
       then
         echo "Please check your lightning configuration file and remove/restore previous settings.Afterwards please restart the lightning implementation or reboot the system.";echo
         break
       else
         
         if [ $isDocker ]; then
         
           echo "Restarting docker services..."
           systemctl daemon-reload > /dev/null
           systemctl restart docker > /dev/null
           echo "> Restarted docker.service to ensure clean setup"

           # Restart containers
           if  [ -f /home/umbrel/umbrel/scripts/start ]; then
             /home/umbrel/umbrel/scripts/start > /dev/null
             echo "> Restarted umbrel containers";echo  
           fi
           
         else #nonDocker
         
           if [ $imp = "lnd" ] && [ -f /etc/systemd/system/lnd.service ]; then

             if systemctl restart lnd.service > /dev/null; then
               echo "> lnd.service successfully restarted";echo
             else
               echo "> ERR: lnd.service could not be restarted.";echo
             fi

           elif [ $imp = "cln" ] && [ -f /etc/systemd/system/lightningd.service ]; then

             if systemctl restart lightningd.service > /dev/null; then
               echo "> lightningd.service successfully restarted";echo
             else 
               echo "> ERR: lightningd.service could not be restarted.";echo
             fi

           elif [ $imp = "cln" ] && [ -f /etc/systemd/system/cln.service ]; then

             if systemctl restart cln.service > /dev/null; then
               echo "> cln.service successfully restarted";echo
             else
              echo "> ERR: cln.service could not be restarted.";echo
            fi

           fi
         fi
       fi
    break
    done

fi


echo "VPN setup uninstalled!";echo

# the end
exit 0
