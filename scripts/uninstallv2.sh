#!/bin/bash
# This script uninstalls/removes the changes made by setup.sh script
# Use with care
#
# Usage: sudo bash uninstall.sh

# check if sudo
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (with sudo)";echo
    exit 1
fi


# intro
echo "
##############################
#       TunnelSats v2        #
#      Uninstall Script      #
##############################";echo


# Restart required: Ask user if we should proceed anyway

while true
do
   read -p "CAUTION! Uninstalling TunnelSats requires a mandatory restart of your lightning implementation. Do you really want to proceed? (Y/N) " answer


  case $answer in
   [yY]* ) echo "> OK, proceeding... ";echo
           break;;

   [nN]* ) echo "> Exiting process.";echo
            exit 1
            break;;
   * )     echo "Just enter Y or N, please.";;
  esac
done


# check if docker
isDocker=0
if [ "$(hostname)" == "umbrel" ] || \
   [ -f /home/umbrel/umbrel/lnd/lnd.conf ] || \
   [ -d /home/umbrel/umbrel/app-data/lightning ] || \
   [ -d /home/umbrel/umbrel/app-data/core-lightning ] || \
   [ -d /embassy-data/package-data/volumes/lnd ]; then
    isDocker=1
fi


# get VPN data
if [ -f /etc/wireguard/tunnelsatsv2.conf ]; then
    vpnExternalIP=$(grep "Endpoint" /etc/wireguard/tunnelsatsv2.conf | awk '{ print $3 }' | cut -d ":" -f1)
    vpnExternalPort=$(grep "#VPNPort" /etc/wireguard/tunnelsatsv2.conf | awk '{ print $3 }')
fi


# Make sure to disable hybrid mode to prevent IP leakage
while true
do
    read -p "Which lightning implementation was set to hybrid mode at TunnelSats installation? (LND|CLN) " answer


  case $answer in
   lnd|LND* ) 
        # RaspiBlitz: try to recover lnd.check.sh
        if [ "$(hostname)" == "raspberrypi" ] && [ -f /etc/systemd/system/lnd.service ]; then
            echo "RaspiBlitz: Removing dependendency lnd.service.d ..."
            if [ -f  /etc/systemd/system/lnd.service.d/tunnelsats-cgroup.conf ] && ! rm /etc/systemd/system/lnd.service.d/tunnelsats-cgroup.conf &> /dev/null; then
               echo "> ERR: Failed to remove dependency /etc/systemd/system/lnd.service.d/tunnelsats-cgroup.conf";echo
               exit 1
            fi
            systemctl daemon-reload &> /dev/null


            echo "RaspiBlitz: Trying to restore with safety check 'lnd.check.sh'..."
            if [ -f /home/admin/config.scripts/lnd.check.bak ]; then
                mv /home/admin/config.scripts/lnd.check.bak /home/admin/config.scripts/lnd.check.sh
                if bash /home/admin/config.scripts/lnd.check.sh > /dev/null; then
                    echo "> Safety check for lnd.conf found and restored";echo
                fi
            else
                echo "> Backup of 'lnd.check.sh' not found, proceeding with manual deactivation...";echo
            fi
        fi

        # do it manually
        path=""
        if [ -f /mnt/hdd/lnd/lnd.conf ]; then path="/mnt/hdd/lnd/lnd.conf"; fi 
        if [ -f /home/umbrel/umbrel/lnd/lnd.conf ]; then path="/home/umbrel/umbrel/lnd/lnd.conf"; fi
        if [ -f /home/umbrel/umbrel/app-data/lightning/data/lnd/lnd.conf ]; then path="/home/umbrel/umbrel/app-data/lightning/data/lnd/lnd.conf"; fi
        if [ -f /data/lnd/lnd.conf ]; then path="/data/lnd/lnd.conf"; fi 
        if [ -f /embassy-data/package-data/volumes/lnd/data/main/lnd.conf ]; then path="/embassy-data/package-data/volumes/lnd/data/main/lnd.conf"; fi
        if [ -f /mnt/hdd/mynode/lnd/lnd.conf ]; then path="/mnt/hdd/mynode/lnd/lnd.conf"; fi

        if [ "$path" != "" ]; then
            check=$(grep -c "tor.skip-proxy-for-clearnet-targets" "$path")
            if [ $check -ne 0 ]; then
                sed -i "tor.skip-proxy-for-clearnet-targets/d" "$path"
                
                # recheck again
                checkAgain=$(grep -c "tor.skip-proxy-for-clearnet-targets" "$path")
                if [ $checkAgain -ne 0 ]; then
                    echo "> CAUTION: Could not deactivate hybrid mode!! Please check your CLN configuration file and set all 'tor.skip-proxy-for-clearnet-targets=true' to 'false' before restarting!!";echo
                else
                    echo "> Hybrid Mode deactivated successfully.";echo
                fi
            fi
        fi
        break;;

   cln|CLN* )     # check CLN (RaspiBlitz)
        # RaspiBlitz: try to recover cl.check.sh
        if [ "$(hostname)" == "raspberrypi" ] && [ -f /etc/systemd/system/lightningd.service ]; then
            echo "RaspiBlitz: Removing dependendency lightningd.service.d ..."
            if [ -f  /etc/systemd/system/lightningd.service.d/tunnelsats-cgroup.conf ] && ! rm /etc/systemd/system/lightningd.service.d/tunnelsats-cgroup.conf &> /dev/null; then
               echo "> ERR: Failed to remove dependency /etc/systemd/system/lightningd.service.d/tunnelsats-cgroup.conf";echo
               exit 1
            fi
            systemctl daemon-reload &> /dev/null

            echo "RaspiBlitz: Trying to restore with safety check 'cl.check.sh'..."
            if [ -f /home/admin/config.scripts/cl.check.bak ]; then
                mv /home/admin/config.scripts/cl.check.bak /home/admin/config.scripts/cl.check.sh
                if bash /home/admin/config.scripts/cl.check.sh; then
                    echo "> Safety check for cln config found and restored";echo
                fi
            else
                echo "> Backup of 'cl.check.sh' not found, proceeding with manual deactivation...";echo
            fi    
        fi

        # do it manually
        path=""
        if [ -f /mnt/hdd/app-data/.lightning/config ]; then path="/mnt/hdd/app-data/.lightning/config"; fi
        if [ -f /home/umbrel/umbrel/app-data/core-lightning/docker-compose.yml ]; then path="/home/umbrel/umbrel/app-data/core-lightning/docker-compose.yml"; fi
        if [ -f /data/cln/config ]; then path="/data/cln/config"; fi

        if [ "$path" != "" ]; then
            check=$(grep -c "always-use-proxy=false" "$path")
            if [ $check -ne 0 ]; then
                sed -i "s/always-use-proxy=false/always-use-proxy=true/g" "$path" > /dev/null
                sed -i "s/always-use-proxy=0/always-use-proxy=1/g" "$path" > /dev/null
                
                # recheck again
                checkAgain=$(grep -c "always-use-proxy=false" "$path")
                if [ $checkAgain -ne 0 ]; then
                    echo "> CAUTION: Could not deactivate hybrid mode!! Please check your CLN configuration file and set 'always-use-proxy=false' to 'true' before restarting!!";echo
                else
                    echo "> Hybrid Mode deactivated successfully.";echo
                fi
            fi
             
            # Umbrel 0.5: restore default configuration
            if [ "$path" == "/home/umbrel/umbrel/app-data/core-lightning/docker-compose.yml" ]; then
                uncomment=$(grep -n "#- --bind-addr=\${APP_CORE_LIGHTNING_DAEMON_IP}:9735" "$path" | cut -d ':' -f1)
                if [ "$uncomment" != "" ]; then
                    sed -i "s/#- --bind-addr/- --bind-addr/g" "$path" > /dev/null
                fi
                deleteBind=$(grep -n "bind-addr=0\.0\.0\.0\:9735" "$path" | cut -d ':' -f1)
                if [ "$deleteBind" != "" ]; then
                    sed -i "${deleteBind}d" "$path" > /dev/null
                fi
                deleteAnnounceAddr=$(grep -n "announce-addr=" "$path" | cut -d ':' -f1)
                if [ "$deleteAnnounceAddr" != "" ]; then
                    sed -i "${deleteAnnounceAddr}d" "$path" > /dev/null
                fi                    
                echo "> Umbrel 0.5+: hybrid mode deactivated and configuration restored";echo
            fi
        fi
    fi
    break;;
   * )     echo "Just enter LND or CLN, please.";;
  esac
done


# forced lightning restart
echo "Restarting lightning implementation now..."
if [ $isDocker -eq 1 ]; then
 
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
            
    # RaspiBolt / RaspiBlitz / Bare Metal LND
    if [ -f /etc/systemd/system/lnd.service ]; then
         echo "Restarting lnd.service ..."
         if systemctl restart lnd.service > /dev/null; then
            echo "> lnd.service successfully restarted";echo
         else
            echo "> ERR: lnd.service could not be restarted.";echo
         fi

    # RaspiBlitz CLN
    elif [ -f /etc/systemd/system/lightningd.service ]; then
         echo "Restarting lighningd.service ..."
         if systemctl restart lightningd.service > /dev/null; then
            echo "> lightningd.service successfully restarted";echo
         else 
            echo "> ERR: lightningd.service could not be restarted.";echo
         fi

     # RaspiBolt / Bare Metal CLN
     elif [ -f /etc/systemd/system/cln.service ]; then
        echo "Restarting cln.service ..."
        if systemctl restart cln.service > /dev/null; then
            echo "> cln.service successfully restarted";echo
        else
            echo "> ERR: cln.service could not be restarted.";echo
        fi
    fi
fi




# remove splitting services
if [ $isDocker -eq 0 ]; then

    # remove tunnelsats-splitting-processes.timer systemd (v1)
    if [ -f /etc/systemd/system/tunnelsats-splitting-processes.timer ]; then
        echo "Removing tunnelsats-splitting-processes systemd timer...";
        systemctl stop tunnelsats-splitting-processes.timer > /dev/null
        systemctl disable tunnelsats-splitting-processes.timer > /dev/null
        rm /etc/systemd/system/tunnelsats-splitting-processes.timer > /dev/null
        echo "> tunnelsats-splitting-processes.timer: removed";echo
    fi

    # remove tunnelsats-splitting-processes.service systemd
    if [ -f /etc/systemd/system/tunnelsats-splitting-processes.service ]; then
        echo "Removing tunnelsats-splitting-processes systemd service...";
        systemctl stop tunnelsats-splitting-processes.service > /dev/null
        systemctl disable tunnelsats-splitting-processes.service > /dev/null
        rm /etc/systemd/system/tunnelsats-splitting-processes.service > /dev/null
        echo "> tunnelsats-splitting-processes.service: removed";echo
    fi


     # remove tunnelsats-create-cgroup.service systemd
    if [ -f /etc/systemd/system/tunnelsats-create-cgroup.service ]; then
        echo "Removing tunnelsats-create-cgroup systemd service...";
        systemctl stop tunnelsats-create-cgroup.service > /dev/null
        systemctl disable tunnelsats-create-cgroup.service > /dev/null
        rm /etc/systemd/system/tunnelsats-create-cgroup.service > /dev/null
        echo "> tunnelsats-create-cgroup.service: removed";echo
    fi




else
 
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



# remove wg-quick@tunnelsats service
if [ -f /lib/systemd/system/wg-quick@.service ]; then
    echo "Removing wireguard systemd service..."
    # remove v1
    if [ -f /etc/systemd/system/multi-user.target.wants/wg-quick@tunnelsats.service ]; then
        systemctl stop wg-quick@tunnelsats > /dev/null
        systemctl disable wg-quick@tunnelsats > /dev/null
    fi
    
    if [ -f /etc/systemd/system/multi-user.target.wants/wg-quick@tunnelsatsv2.service ]; then
        if systemctl stop wg-quick@tunnelsatsv2 > /dev/null && \
            systemctl disable wg-quick@tunnelsatsv2 > /dev/null; then 
            echo "> wireguard systemd service disabled and removed";echo
        else
            echo "> ERR: could not remove /etc/systemd/systemd/wg-quick@tunnelsatsv2. Please check manually.";echo
        fi
    fi
fi

sleep 2


# remove wg-quick@tunnelsatsv2.service.d
if [ -d /etc/systemd/system/wg-quick@tunnelsatsv2.service.d  ] && [ $isDocker -eq 1 ]; then
    echo "Removing wg-quick@tunnelsatsv2.service.d..."
    if rm -r /etc/systemd/system/wg-quick@tunnelsatsv2.service.d; then
        echo "> /etc/systemd/system/wg-quick@tunnelsatsv2.service.d removed";echo
    else
        echo "> ERR: could not remove /etc/systemd/systemd/wg-quick@tunnelsatsv2.service.d. Please check manually.";echo
    fi
fi

sleep 2


#remove docker-tunnelsats network
if [ $isDocker -eq 1 ]; then
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
if [ $isDocker -eq 1 ] && [ -f /etc/systemd/system/umbrel-startup.service.d/tunnelsats_killswitch.conf  ]; then
    echo "Removing tunnelsats_killswitch.conf..."
    if rm /etc/systemd/system/umbrel-startup.service.d/tunnelsats_killswitch.conf ; then
        rm -r /etc/systemd/system/umbrel-startup.service.d > /dev/null
        echo "> /etc/systemd/system/umbrel-startup.service.d/tunnelsats_killswitch.conf  removed";echo
    else
        echo "> ERR: could not remove /etc/systemd/system/umbrel-startup.service.d/tunnelsats_killswitch.conf. Please check manually.";echo
    fi
fi

sleep 2

#reset lnd
if [ $isDocker -eq 0 ] && [ -f /etc/systemd/system/lnd.service.bak ]; then
    if mv /etc/systemd/system/lnd.service.bak /etc/systemd/system/lnd.service; then
        echo "> lnd.service prior to tunnelsats successfully reset";echo
    else 
        echo "> ERR: Not able to reset /etc/systemd/system/lnd.service Please check manually.";echo
    fi
fi


#reset lightningd
if [ $isDocker -eq 0 ] && [ -f /etc/systemd/system/lightnind.service.bak ]; then
    if mv /etc/systemd/system/lightnind.service.bak /etc/systemd/system/lightningd.service; then
        echo "> lightningd.service prior to tunnelsats successfully reset";echo
    else 
        echo "> ERR: Not able to reset /etc/systemd/system/lightningd.service Please check manually.";echo
    fi
fi


# remove netcls subgroup
if [ $isDocker -eq 0 ]; then
    echo "Removing net_cls subgroup..."
    # v1
    if [ -d /sys/fs/cgroup/net_cls/tor_splitting ]; then
        cgdelete net_cls:/tor_splitting 2> /dev/null
    fi

    if [ -d /sys/fs/cgroup/net_cls/splitted_processes ]; then
        cgdelete net_cls:/splitted_processes 2> /dev/null
        echo "> Control Group Splitted Processes removed";echo
    else
        echo "> ERR: Could not remove cgroup net_cls subgroup.";echo
    fi
fi


#Flush nftables and enable old nftables.conf
#Flush table if exist to avoid redundant rules
if [ $isDocker -eq 1 ]; then
  if nft list table inet tunnelsatsv2 &> /dev/null; then
      echo "Flushing tunnelsats nftable rules..."
      if nft flush table inet tunnelsatsv2 &> /dev/null; then echo "> Done";echo; fi
  fi

  if [ -f /etc/nftablespriortunnelsats.backup ]; then
      echo "Recovering old nftables ruleset..."
      if mv /etc/nftablespriortunnelsats.backup /etc/nftables.conf; then
          echo "> Prior nftables.conf now active. To enable it restart nftables.service or restart system.";echo
      fi
  fi
fi

sleep 2

# uninstall cgroup-tools, nftables, wireguard
while true
do
  if [ $isDocker -eq 1 ]; then
      read -p "Do you really want to uninstall nftables and wireguard via apt-get remove? (Y/N) " answer

  else
      read -p "Do you really want to uninstall cgroup-tools, nftables and wireguard via apt-get remove?(Y/N) " answer
  fi

  case $answer in
   [yY]* ) if [[ $isDocker -eq 1 ]] && apt-get remove -yqq nftables wireguard-tools || apt-get remove -yqq cgroup-tools nftables wireguard-tools; then
              echo "> Components removed";echo
           else
              echo "> ERR: components could not be removed. Please check manually.";echo
           fi
           break;;

   [nN]* )  echo "> leaving system as is, proceeding...";echo
            break;;
   * )     echo "Just enter Y or N, please.";;
  esac
done


echo "VPN setup uninstalled!";echo

# the end
exit 0
