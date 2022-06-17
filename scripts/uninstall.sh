# This script uninstalls/removes the changes made by setup.sh script
# Use with care
#
# Usage: sudo bash uninstall.sh

# check if sudo
if [ "$EUID" -ne 0 ]
  then echo "Please run as root (with sudo)";echo
  exit 1
fi

echo "
##############################
#         TunnelSats         #
#      Uninstall Script      #
##############################";echo

# RaspiBlitz, redo safety check and run it
if [ $(hostname) = "raspberrypi" ] && [ -f /mnt/hdd/lnd/lnd.conf ]; then 
    echo "RaspiBlitz: Trying to restore safety check 'lnd.check.sh'..."
    if [ -f /home/admin/config.scripts/lnd.check.bak ]; then
      mv /home/admin/config.scripts/lnd.check.bak /home/admin/config.scripts/lnd.check.sh
      echo "> Safety check for lnd.conf found and restored";echo
    else
      echo "> Backup of 'lnd.check.sh' not found";echo
    fi
fi

# remove splitting.timer systemd
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

# remove ufw setting (port rule)
checkufw=$(ufw version 2> /dev/null | grep -c Canonical)
if [ $checkufw -eq 1 ]; then
  vpnExternalPort="$(grep "#VPNPort" /etc/wireguard/tunnelsats.conf | awk '{ print $3 }')" > /dev/null
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
  
  if wg-quick down tunnelsats > /dev/null &&
     systemctl stop wg-quick@tunnelsats > /dev/null &&
     systemctl disable wg-quick@tunnelsats > /dev/null &&
     [ ! -f /etc/systemd/systemd/wg-quick@tunnelsats ]; then
    echo "> wireguard systemd service disabled and removed";echo
  else
    echo "> ERR: could not remove /etc/systemd/systemd/wg-quick@tunnelsats. Please check manually.";echo
  fi
fi

sleep 2

# removing /etc/wireguard/*
if [ -d /etc/wireguard/ ]; then
  echo "Removing wireguard directory..."
  rm -rf /etc/wireguard/ > /dev/null
  if [ ! -d /etc/wireguard/ ]; then
    echo "> /etc/wireguard/ directory removed";echo
  else
    echo "> ERR: could not remove directory /etc/wireguard/. Please check manually.";echo
  fi
fi

sleep 2

# remove netcls subgroup
echo "Removing netcls subgroup..."
if cgdelete net_cls:/splitted_processes 2> /dev/null; then
    echo "> Control Group Splitted Processes removed";echo
else
    echo "> ERR: Could not remove cgroup.";echo
fi

sleep 2

# uninstall cgroup-tools, nftables, wireguard
echo "Uninstalling packages: cgroup-tools, nftables, wireguard-tools ..."
if apt-get remove -yqq cgroup-tools nftables wireguard-tools; then
  echo "> Packages removed";echo
else
  echo "> ERR: packages could not be removed. Please check manually.";echo
fi

sleep 2




echo "VPN setup uninstalled";echo

# the end
exit 0
