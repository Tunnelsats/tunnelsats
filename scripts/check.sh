#!/bin/bash
# This script checks the system environment for compatibility with TunnelSats esp. on unknown hosts
# Usage: sudo bash check.sh
#
#VERSION NUMBER of check.sh
#Update if your make a significant change
##########UPDATE IF YOU MAKE A NEW RELEASE#############
major=0
minor=0
patch=1

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

# check kernel version (min 5.10.102+ required)
kernelMajor=$(uname -r | cut -d '.' -f1)
kernelMinor=$(uname -r | cut -d '.' -f2)
kernelPatch=$(uname -r | cut -d '.' -f3 | cut -d '-' -f1)

echo "Checking kernel version..."
#echo -e "Current kernel:\nmajor: ${kernelMajor}\nminor: ${kernelMinor}\npatch: ${kernelPatch}"
#echo

#if [[ $(uname -r) =~ ^5.10.102.* ]]; then
#    echo "> kernel version ✅"

if [[ $kernelMajor -ge 5 ]] &&
    ( ([[ $kernelMinor -ge 10 ]] && [[ $kernelPatch -ge 102 ]]) ||
        [[ $kernelMinor -ge 11 ]] ); then
    echo "> ✅ kernel version ok"
    echo
else
    echo "> ❌ kernel version 5.10.102+ required"
    echo
fi

# check nftable version (min 0.9.6+ required)
echo "Checking nftables version..."
nftablesVersion=""
if nft -v &>/dev/null; then
    #nftables installed
    nftablesVersion=$(nft -v | awk '{print $2}' | cut -d 'v' -f2)
else
    #nftables not installed, check availbale apt version
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
# 0.9.6
elif ([[ $nftMinor -ge 9 ]] && [[ $nftPatch -ge 6 ]] ||
    [[ $nftMinor -ge 10 ]]); then
    echo "> ✅ nftables version ok"
    echo
else
    echo "> ❌ nftables version 0.9.6+ required"
    echo
fi
