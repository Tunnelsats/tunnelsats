#!/bin/bash
# This script checks the system environment for compatibility with TunnelSats esp. on unknown hosts
# Usage: sudo bash check.sh
#
#VERSION NUMBER of check.sh
#Update if your make a significant change
##########UPDATE IF YOU MAKE A NEW RELEASE#############
major=0
minor=0
patch=5

# check if sudo
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (with sudo)"
    exit 1
fi

# intro
echo -e "
###############################
         TunnelSats v2
         Compatibility
         Check Script
         Version:
         v$major.$minor.$patch
###############################"
echo

# global const
rating=0

# check kernel version (min 5.10.102+ required)
kernelMajor=$(uname -r | cut -d '.' -f1)
kernelMinor=$(uname -r | cut -d '.' -f2)
kernelPatch=$(uname -r | cut -d '.' -f3 | cut -d '-' -f1)

echo "Checking kernel version..."
#echo -e "Current kernel:\nmajor: ${kernelMajor}\nminor: ${kernelMinor}\npatch: ${kernelPatch}"
#echo

# requirement kernel version 5.10.102+
if [[ $kernelMajor -gt 5 ]]; then
    echo "> ✅ kernel version ok"
    echo
    ((rating++))
elif [[ $kernelMajor -ge 5 ]] && 
       ( ([[ $kernelMinor -ge 10 ]] && [[ $kernelPatch -ge 102 ]]) ||
        [[ $kernelMinor -ge 11 ]]); then
    echo "> ✅ kernel version ok"
    echo
    ((rating++))
else
    echo "> ❌ kernel version 5.10.102+ required"
    echo
    ((rating--))
fi

# requirement nftable version 0.9.6+
echo "Checking nftables version..."
nftablesVersion=""
if nft -v &>/dev/null; then
    #nftables installed
    nftablesVersion=$(nft -v | awk '{print $2}' | cut -d 'v' -f2)
else
    #nftables not installed, check available apt version
    nftablesVersion=$(apt search nftables | grep "^nftables" | awk '{print $2}' | cut -d '-' -f1)
fi

# slice version
nftMajor=$(echo "${nftablesVersion}" | cut -d '.' -f1)
nftMinor=$(echo "${nftablesVersion}" | cut -d '.' -f2)
nftPatch=$(echo "${nftablesVersion}" | cut -d '.' -f3)

#echo -e "Current nftables:\nmajor: ${nftMajor}\nminor: ${nftMinor}\npatch: ${nftPatch}"
#echo

# 1.x.x OK
if [[ $nftMajor -ge 1 ]]; then
    echo "> ✅ nftables version ok"
    echo
    ((rating++))    
# 0.9.6
elif ([[ $nftMinor -ge 9 ]] && [[ $nftPatch -ge 6 ]] ||
    [[ $nftMinor -ge 10 ]]); then
    echo "> ✅ nftables version ok"
    echo
    ((rating++))  
else
    echo "> ❌ nftables version 0.9.6+ required"
    echo
    ((rating--))
fi

# requirement: systemd.services or docker processes + related naming convention
echo "Looking for systemd services..."
if [[ -f /etc/systemd/system/lnd.service ]]; then
    echo "> ✅ lnd.service found"
    echo
    ((rating++))
elif [[ -f /etc/systemd/system/lightningd.service ]]; then
    echo "> ✅ lightningd.service found"
    echo
    ((rating++))
else
    echo "> ❌ no systemd.services found, let's check for docker..."
    echo
    echo "Looking for docker processes..."
    dockerProcess=$(docker ps --format 'table {{.Image}} {{.Names}} {{.Ports}}' | grep -E "0.0.0.0:9735|0.0.0.0:9736" | awk '{print $2}')
    if [[ ${dockerProcess} == *lnd* ]]; then
        echo "> ✅ found a possible lnd container"
        echo
        ((rating+=1))
    elif [[ ${dockerProcess} == *clightning* ]]; then
        echo "> ✅ found a possible cln container"
        echo
        ((rating++))
    else
        echo "> ❌ no suitable containers found"
        echo
        ((rating--))
    fi
fi


# result message
# max points: 3
if [ $rating -lt 0 ]; then
    rating=0
fi

echo "Result:"
echo "rating points: ${rating}"
if [ $rating -le 0 ]; then
    echo "> Sorry, your setup is likely not compatible with Tunnel Sats."
elif [ $rating -gt 0 ] && [ $rating -lt 3 ]; then
    echo "> Your setup is likely compatible with Tunnel Sats. Please check if missing requirements can be "
elif [ $rating -eq 3 ]; then
    echo "> Congrats! Your setup matches Tunnel Sats requirements perfectly!"
fi