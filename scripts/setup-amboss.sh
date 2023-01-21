#!/bin/bash

function helpmessage() {
    echo "Setting up Amboss Health - Make sure you have registered your node prior to setting this up"
    echo "setup-amboss.sh on docker-ts|non-docker-ts|citadel-ts|clearnet|tor|docker-tor|docker-clearnet"
    echo "setup-amboss.sh status"
    echo "setup-amboss.sh off"
}

# check if sudo
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (with sudo)"
    exit 1
fi

# command info
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "-help" ]; then
    helpmessage
    exit 1
fi

###################
# SWITCH ON
###################

if [ "$1" = "1" ] || [ "$1" = "on" ] && [ $# -eq 2 ]; then

    user="root"
    scriptPath="/root"

    echo "Creating Amboss Health Service"

    system=$(echo "$2" | awk '{print tolower($0)}')

    if [ "$system" = "docker-ts" ]; then
        wget -q -O $scriptPath/amboss-health.sh "https://raw.githubusercontent.com/Tunnelsats/tunnelsats/main/scripts/amboss-health-tunnelsats-docker.sh"
    elif [ "$system" = "non-docker-ts" ]; then
        scriptPath="/home/bitcoin"
        wget -q -O $scriptPath/amboss-health.sh "https://raw.githubusercontent.com/Tunnelsats/tunnelsats/main/scripts/amboss-health-tunnelsats-non-docker.sh"
        user="bitcoin"
    elif [ "$system" = "citadel-ts" ]; then
        wget -q -O - "https://raw.githubusercontent.com/Tunnelsats/tunnelsats/main/scripts/amboss-health-tunnelsats-docker.sh" | sed 's/docker-tunnelsats/a-docker-tunnelsats/g' >$HOME/amboss-health.sh
    elif [ "$system" = "clearnet" ]; then
        wget -q -O $scriptPath/amboss-health.sh "https://raw.githubusercontent.com/Tunnelsats/tunnelsats/main/scripts/amboss-health-clearnet.sh"
        user="bitcoin"
    elif [ "$system" = "tor" ]; then
        wget -q -O $scriptPath/amboss-health.sh "https://raw.githubusercontent.com/Tunnelsats/tunnelsats/main/scripts/amboss-health-tor.sh"
        user="bitcoin"
    elif [ "$system" = "docker-tor" ]; then
        wget -q -O $scriptPath/amboss-health.sh "https://raw.githubusercontent.com/Tunnelsats/tunnelsats/main/scripts/amboss-health-docker-tor.sh"
    elif [ "$system" = "docker-clearnet" ]; then
        wget -q -O $scriptPath/amboss-health.sh "https://raw.githubusercontent.com/Tunnelsats/tunnelsats/main/scripts/amboss-health-docker-clearnet.sh"
    else
        helpmessage
        exit 1
    fi

    chmod +x $scriptPath/amboss-health.sh

    # Create systemd service

    echo "[Unit]
Description=Adding Amboss Health Service
StartLimitInterval=400
StartLimitBurst=5
[Service]
Type=simple
RestartSec=60
User=$user
ExecStart=$scriptPath/amboss-health.sh
[Install]
WantedBy=multi-user.target
" >/etc/systemd/system/tunnelsats-amboss-health.service

    echo "[Unit]
Description=5min timer for tunnelsats-docker-network.service
[Timer]
OnBootSec=60
OnUnitActiveSec=300
Persistent=true
[Install]
WantedBy=timers.target
" >/etc/systemd/system/tunnelsats-amboss-health.timer

    # enable and start tunnelsats-amboss-health.service
    if [ -f /etc/systemd/system/tunnelsats-amboss-health.service ]; then
        systemctl daemon-reload >/dev/null
        if systemctl enable tunnelsats-amboss-health.service >/dev/null &&
            systemctl start tunnelsats-amboss-health.service >/dev/null; then
            echo "> tunnelsats-amboss-health.service : systemd service enabled and started"
        else
            echo "> ERR: tunnelsats-amboss-health.service  could not be enabled or started. Please check for errors."
            echo
            exit 1
        fi
        if [ -f /etc/systemd/system/tunnelsats-amboss-health.timer ]; then
            if systemctl enable tunnelsats-amboss-health.timer >/dev/null &&
                systemctl start tunnelsats-amboss-health.timer >/dev/null; then
                echo "> tunnelsats-amboss-health.timer: systemd timer enabled and started"
                echo
            else
                echo "> ERR: tunnelsats-amboss-health.timer: systemd timer could not be enabled or started. Please check for errors."
                echo
                exit 1
            fi
        fi
    fi
    echo "> Amboss-Health Monitoring is installed and running ✅"

    exit 0
fi

###################
# SWITCH STATUS
###################

if [ "$1" = "2" ] || [ "$1" = "status" ] && [ $# -eq 1 ]; then

    if [ -f /etc/systemd/system/tunnelsats-amboss-health.service ] && [ -f /etc/systemd/system/tunnelsats-amboss-health.timer ]; then
        echo "> Amboss-Health Monitoring is installed ✅"
        status=$(systemctl status tunnelsats-amboss-health.service | grep -c "status=0/SUCCESS")
        if [ $status -eq 1 ]; then
            echo "> Amboss-Health Monitoring is running ✅"
        else
            echo "> Amboss-Health Monitoring is not running lets restart"
            systemctl restart tunnelsats-amboss-health.service >/dev/null
            systemctl restart tunnelsats-amboss-health.timer >/dev/null
            status=$(systemctl status tunnelsats-amboss-health.service | grep -c "status=0/SUCCESS")
            if [ $status -eq 0 ]; then
                echo "> Amboss-Health Monitoring did not start successfully check with \"sudo systemctl status tunnelsats-amboss-health\" ✅"
            fi
        fi
    else
        echo "> Amboss-Health Monitoring is not installed ⚠️"
        helpmessage
    fi
    exit 0
fi

###################
# SWITCH OFF
###################

if [ "$1" = "3" ] || [ "$1" = "off" ] && [ $# -eq 1 ]; then

    scriptPath="/root"
    rm $scriptPath/amboss-health.sh 2>/dev/null
    scriptPath="/home/bitcoin"
    rm $scriptPath/amboss-health.sh 2>/dev/null
    systemctl disable tunnelsats-amboss-health.service 2>/dev/null
    systemctl disable tunnelsats-amboss-health.service 2>/dev/null
    rm /etc/systemd/system/tunnelsats-amboss-health.service 2>/dev/null
    rm /etc/systemd/system/tunnelsats-amboss-health.timer 2>/dev/null

    echo "> Amboss-Health Monitoring is successfully uninstalled ✅"

    exit 0
fi

helpmessage
