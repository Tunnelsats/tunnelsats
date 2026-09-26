#!/bin/bash
# Tests for lifecycle ordering, container resolution, network attachment,
# scoped routing ownership, and fail-closed error handling in tunnelsats.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/tunnelsats.sh"

pass_count=0
fail_count=0

assert_equals() {
    local expected="$1"
    local actual="$2"
    local desc="$3"

    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $desc"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc (expected '$expected', got '$actual')"
        fail_count=$((fail_count + 1))
    fi
}

assert_status() {
    local expected_status="$1"
    local actual_status="$2"
    local desc="$3"

    if [[ "$expected_status" -eq "$actual_status" ]]; then
        echo "PASS: $desc (exit=$actual_status)"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc (expected exit=$expected_status, got exit=$actual_status)"
        fail_count=$((fail_count + 1))
    fi
}

echo "=== Running Lifecycle, Network & Routing Tests ==="

# ---------------------------------------------------------------------------
# TEST GROUP 1: Shared Docker Container Resolution
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 1: Container Resolution ---"

test_container_resolution_lnd() {
    local output
    output=$(bash -c "
        source \"$SCRIPT_UNDER_TEST\"
        LN_IMPL=\"lnd\"
        docker() {
            cat << 'EOF'
cid1 lightning_lnd_1
cid2 lightning-lnd-1
cid3 lnd-1
cid4 umbrel_lnd_1
cid5 lnd
cid6 lnd-app
cid7 lightning-app-1
cid8 rtl-app
cid9 lnd_ui_1
EOF
        }
        get_lightning_docker_containers
    ")
    
    local expected=$'cid1\ncid2\ncid3\ncid4\ncid5'
    assert_equals "$expected" "$output" "LND resolver matches daemons (including lnd-1, lightning-lnd-1) and excludes apps/UIs"
}
test_container_resolution_lnd

test_container_resolution_cln() {
    local output
    output=$(bash -c "
        source \"$SCRIPT_UNDER_TEST\"
        LN_IMPL=\"cln\"
        docker() {
            cat << 'EOF'
cid10 core-lightning_lightningd_1
cid11 core-lightning-lightningd-1
cid12 lightning_cln_1
cid13 lightningd
cid14 core-lightning_app_1
cid15 cln-web
cid16 lightning_cln_ui
EOF
        }
        get_lightning_docker_containers
    ")
    
    local expected=$'cid10\ncid11\ncid12\ncid13'
    assert_equals "$expected" "$output" "CLN resolver matches daemons (including lightning_cln_1) and excludes apps/UIs"
}
test_container_resolution_cln

# ---------------------------------------------------------------------------
# TEST GROUP 2: Lifecycle Stop Ordering & Failure Handling
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 2: Lifecycle Stop Ordering ---"

test_daemon_stopped_independently_of_wireguard() {
    local log_file=$(mktemp)
    local status
    set +e
    bash -c "
        source \"$SCRIPT_UNDER_TEST\"
        PLATFORM=\"umbrel\"
        LN_IMPL=\"lnd\"
        WG_INTERFACE=\"tunnelsatsv2\"

        # WireGuard is inactive/failed
        systemctl() {
            if [[ \"\$1\" == \"is-active\" ]]; then
                return 1
            fi
            return 0
        }

        # Mock docker: container is running
        docker() {
            if [[ \"\$1\" == \"ps\" ]]; then
                echo \"cid_lnd1 lightning_lnd_1\"
                return 0
            fi
            if [[ \"\$1\" == \"stop\" ]]; then
                echo \"DOCKER_STOP_CALLED:\$*\" >> \"$log_file\"
                return 0
            fi
            return 0
        }

        stop_lightning_daemon_for_safe_restart
    " &>/dev/null
    status=$?
    set -e

    assert_status 0 "$status" "stop_lightning_daemon_for_safe_restart succeeds when WireGuard is inactive"
    if grep -q "DOCKER_STOP_CALLED:stop cid_lnd1" "$log_file"; then
        echo "PASS: Daemon container was stopped even when WireGuard was inactive"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: Daemon container was not stopped when WireGuard was inactive"
        fail_count=$((fail_count + 1))
    fi
    rm -f "$log_file"
}
test_daemon_stopped_independently_of_wireguard

test_daemon_stop_failure_aborts() {
    local status
    set +e
    bash -c "
        source \"$SCRIPT_UNDER_TEST\"
        PLATFORM=\"umbrel\"
        LN_IMPL=\"lnd\"
        WG_INTERFACE=\"tunnelsatsv2\"

        docker() {
            if [[ \"\$1\" == \"ps\" ]]; then
                echo \"cid_lnd1 lightning_lnd_1\"
                return 0
            fi
            if [[ \"\$1\" == \"stop\" ]]; then
                return 1
            fi
            return 0
        }

        stop_lightning_daemon_for_safe_restart
    " &>/dev/null
    status=$?
    set -e

    assert_status 1 "$status" "Daemon container stop failure aborts immediately (fail-closed)"
}
test_daemon_stop_failure_aborts

test_wireguard_stop_failure_aborts() {
    local status
    set +e
    bash -c "
        source \"$SCRIPT_UNDER_TEST\"
        PLATFORM=\"umbrel\"
        LN_IMPL=\"lnd\"
        WG_INTERFACE=\"tunnelsatsv2\"

        docker() {
            if [[ \"\$1\" == \"ps\" ]]; then
                return 0
            fi
            return 0
        }

        systemctl() {
            if [[ \"\$1\" == \"is-active\" ]]; then
                return 0 # WireGuard is active
            fi
            if [[ \"\$1\" == \"stop\" ]]; then
                return 1 # Stopping WireGuard fails
            fi
            return 0
        }

        stop_lightning_daemon_for_safe_restart
    " &>/dev/null
    status=$?
    set -e

    assert_status 1 "$status" "WireGuard stop failure aborts immediately without ignoring errors"
}
test_wireguard_stop_failure_aborts

# ---------------------------------------------------------------------------
# TEST GROUP 3: Docker Network Attachment & Verification
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 3: Docker Network Attachment & Verification ---"

test_docker_network_attachment_with_ip() {
    local tmp_wg=$(mktemp -d)
    local tmp_sys=$(mktemp -d)
    local log_file=$(mktemp)
    bash -c "
        source \"$SCRIPT_UNDER_TEST\"
        PLATFORM=\"umbrel\"
        LN_IMPL=\"lnd\"
        WG_INTERFACE=\"tunnelsatsv2\"
        WG_DIR=\"$tmp_wg\"
        SYSTEMD_DIR=\"$tmp_sys\"

        docker() {
            if [[ \"\$1\" == \"network\" && \"\$2\" == \"ls\" ]]; then
                echo \"docker-tunnelsats\"
                return 0
            fi
            if [[ \"\$1\" == \"ps\" ]]; then
                echo \"cid_umbrel_lnd_1 lightning-lnd-1\"
                return 0
            fi
            if [[ \"\$1\" == \"inspect\" ]]; then
                # Not yet connected
                return 0
            fi
            if [[ \"\$1\" == \"network\" && \"\$2\" == \"connect\" ]]; then
                echo \"CONNECT_CALLED:\$*\" >> \"$log_file\"
                return 0
            fi
            return 0
        }

        ip() { return 0; }
        systemctl() { return 0; }
        chmod() { return 0; }
        bash() { return 0; }

        setup_docker_network
    " &>/dev/null

    if grep -q "CONNECT_CALLED:network connect --ip 10.9.9.9 docker-tunnelsats cid_umbrel_lnd_1" "$log_file"; then
        echo "PASS: setup_docker_network connects resolved container with --ip 10.9.9.9"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: setup_docker_network did not connect container with expected arguments"
        fail_count=$((fail_count + 1))
    fi
    rm -rf "$tmp_wg" "$tmp_sys" "$log_file"
}
test_docker_network_attachment_with_ip

test_verify_installation_fails_if_container_ip_wrong() {
    local status
    set +e
    bash -c "
        source \"$SCRIPT_UNDER_TEST\"
        PLATFORM=\"umbrel\"
        LN_IMPL=\"lnd\"
        WG_INTERFACE=\"tunnelsatsv2\"
        stopped_docker_containers=\"cid_wrong_ip\"

        systemctl() { return 0; }
        wg() { return 0; }

        docker() {
            if [[ \"\$1\" == \"ps\" ]]; then
                echo \"cid_wrong_ip\"
                return 0
            fi
            if [[ \"\$1\" == \"inspect\" ]]; then
                echo \"172.17.0.2\" # Wrong IP
                return 0
            fi
            return 0
        }

        verify_installation
    " &>/dev/null
    status=$?
    set -e

    assert_status 1 "$status" "verify_installation aborts if container IP is not 10.9.9.9"
}
test_verify_installation_fails_if_container_ip_wrong

test_verify_installation_passes_if_container_ip_correct() {
    local status
    set +e
    bash -c "
        source \"$SCRIPT_UNDER_TEST\"
        PLATFORM=\"umbrel\"
        LN_IMPL=\"lnd\"
        WG_INTERFACE=\"tunnelsatsv2\"
        stopped_docker_containers=\"cid_correct\"

        systemctl() { return 0; }
        wg() { return 0; }

        docker() {
            if [[ \"\$1\" == \"ps\" ]]; then
                echo \"cid_correct\"
                return 0
            fi
            if [[ \"\$1\" == \"inspect\" ]]; then
                echo \"10.9.9.9\" # Correct IP
                return 0
            fi
            return 0
        }

        verify_installation
    " &>/dev/null
    status=$?
    set -e

    assert_status 0 "$status" "verify_installation succeeds when container is on 10.9.9.9"
}
test_verify_installation_passes_if_container_ip_correct

# ---------------------------------------------------------------------------
# TEST GROUP 4: Scoped Routing Ownership & Conflict Abort
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 4: Scoped Routing Ownership ---"

test_cleanup_aborts_on_conflicting_wg_interface() {
    local status
    set +e
    bash -c "
        source \"$SCRIPT_UNDER_TEST\"
        WG_INTERFACE=\"tunnelsatsv2\"

        wg() {
            if [[ \"\$1\" == \"show\" && \"\$2\" == \"interfaces\" ]]; then
                echo \"tunnelsatsv2 wg0\"
                return 0
            fi
            return 0
        }

        ip() {
            if [[ \"\$*\" == *\"route show table 51820\"* ]]; then
                echo \"default dev wg0 scope link\"
                return 0
            fi
            return 0
        }

        check_and_cleanup_routing_table \"tunnelsatsv2\"
    " &>/dev/null
    status=$?
    set -e

    assert_status 1 "$status" "check_and_cleanup_routing_table aborts if active wg0 owns table 51820"
}
test_cleanup_aborts_on_conflicting_wg_interface

test_cleanup_aborts_on_foreign_routes() {
    local status
    set +e
    bash -c "
        source \"$SCRIPT_UNDER_TEST\"
        WG_INTERFACE=\"tunnelsatsv2\"

        wg() {
            if [[ \"\$1\" == \"show\" && \"\$2\" == \"interfaces\" ]]; then
                echo \"tunnelsatsv2\"
                return 0
            fi
            return 0
        }

        ip() {
            if [[ \"\$*\" == *\"route show table 51820\"* ]]; then
                echo \"192.168.50.0/24 dev eth0 scope link\"
                return 0
            fi
            return 0
        }

        check_and_cleanup_routing_table \"tunnelsatsv2\"
    " &>/dev/null
    status=$?
    set -e

    assert_status 1 "$status" "check_and_cleanup_routing_table aborts if table 51820 has foreign routes"
}
test_cleanup_aborts_on_foreign_routes

test_cleanup_only_deletes_prioritized_rules() {
    local rules_file=$(mktemp)
    local log_file=$(mktemp)
    echo "21820: from all lookup main suppress_prefixlength 0" > "$rules_file"
    echo "32764: from all lookup main suppress_prefixlength 0" >> "$rules_file"

    bash -c "
        source \"$SCRIPT_UNDER_TEST\"
        WG_INTERFACE=\"tunnelsatsv2\"

        wg() { return 0; }

        ip() {
            if [[ \"\$*\" == *\"route show table 51820\"* ]]; then
                echo \"default dev tunnelsatsv2 metric 2\"
                return 0
            fi
            if [[ \"\$*\" == *\"rule show\"* ]]; then
                cat \"$rules_file\"
                return 0
            fi
            if [[ \"\$1\" == \"rule\" && \"\$2\" == \"del\" ]]; then
                echo \"RULE_DEL:\$*\" >> \"$log_file\"
                sed -i '/21820:/d' \"$rules_file\"
                return 0
            fi
            return 0
        }

        check_and_cleanup_routing_table \"tunnelsatsv2\"
    " &>/dev/null

    if grep -q "RULE_DEL:rule del priority 21820" "$log_file" && ! grep -q "RULE_DEL:rule del.*32764" "$log_file"; then
        echo "PASS: check_and_cleanup_routing_table strictly deletes priority 21820 rule and preserves other VPN rules"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: check_and_cleanup_routing_table did not preserve unowned rules"
        fail_count=$((fail_count + 1))
    fi
    rm -f "$rules_file" "$log_file"
}
test_cleanup_only_deletes_prioritized_rules

# ---------------------------------------------------------------------------
# TEST GROUP 5: Fail-Closed Emergency nftables Rules
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 5: Emergency Fail-Closed nftables ---"

test_failclosed_covers_forward_and_output() {
    local output status
    set +e
    output=$(bash -c "
        source \"$SCRIPT_UNDER_TEST\"
        WG_INTERFACE=\"tunnelsatsv2\"
        PLATFORM=\"umbrel\"
        LN_IMPL=\"lnd\"

        systemctl() {
            if [[ \"\$1\" == \"enable\" ]]; then return 0; fi
            if [[ \"\$1\" == \"start\" && \"\$2\" == wg-quick@* ]]; then
                return 1 # WireGuard start fails
            fi
            return 0
        }

        nft() {
            echo \"NFT_CALLED:\$*\"
            return 0
        }

        ip() { return 0; }
        check_and_cleanup_routing_table() { return 0; }

        enable_services
    " 2>&1)
    status=$?
    set -e

    assert_status 1 "$status" "enable_services fails closed when WireGuard start fails"

    if echo "$output" | grep -q "NFT_CALLED:add chain ip tunnelsats_failclosed forward" && \
       echo "$output" | grep -q "NFT_CALLED:add rule ip tunnelsats_failclosed forward ip saddr 10.9.9.0/25 fib daddr type != local counter drop"; then
        echo "PASS: Emergency fail-closed drop covers forwarded Docker traffic"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: Emergency fail-closed did not configure Docker forward chain drop"
        fail_count=$((fail_count + 1))
    fi
}
test_failclosed_covers_forward_and_output

# Helper: run a snippet (from stdin) in an isolated bash with the production script sourced.
# LOG is exported so mocks can record calls.
run_case() {
    local log="$1"
    SCRIPT_UNDER_TEST="$SCRIPT_UNDER_TEST" LOG="$log" bash -s
}

assert_log_contains() {
    local log="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" "$log"; then
        echo "PASS: $desc"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc (missing '$needle')"
        fail_count=$((fail_count + 1))
    fi
}

assert_log_not_contains() {
    local log="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" "$log"; then
        echo "FAIL: $desc (unexpected '$needle')"
        fail_count=$((fail_count + 1))
    else
        echo "PASS: $desc"
        pass_count=$((pass_count + 1))
    fi
}

# ---------------------------------------------------------------------------
# TEST GROUP 6: CLN daemon naming coverage
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 6: CLN Daemon Naming ---"

test_cln_resolver_matches_bare_core_lightning() {
    local output
    output=$(run_case /dev/null <<'EOF'
source "$SCRIPT_UNDER_TEST"
LN_IMPL="cln"
docker() {
    cat << 'LIST'
c1 core-lightning
c2 core-lightning-1
c3 core-lightning_1
c4 core-lightning_tor_1
c5 core-lightning_app_proxy_1
c6 core-lightning-rtl_web_1
c7 clightning
LIST
}
get_lightning_docker_containers
EOF
)
    assert_equals $'c1\nc2\nc3\nc7' "$output" "CLN resolver matches bare core-lightning/clightning daemons and excludes tor/app_proxy/web sidecars"
}
test_cln_resolver_matches_bare_core_lightning

# ---------------------------------------------------------------------------
# TEST GROUP 7: Single-owner static tunnel IP
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 7: Single-Owner Static Tunnel IP ---"

test_setup_attaches_only_stopped_daemon_and_releases_stale_holder() {
    local tmp_wg tmp_sys log
    tmp_wg=$(mktemp -d); tmp_sys=$(mktemp -d); log=$(mktemp)
    WG_DIR_T="$tmp_wg" SYSTEMD_DIR_T="$tmp_sys" run_case "$log" <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
PLATFORM="umbrel"; LN_IMPL="lnd"; WG_INTERFACE="tunnelsatsv2"
WG_DIR="$WG_DIR_T"; SYSTEMD_DIR="$SYSTEMD_DIR_T"
stopped_docker_containers="cid_live"
docker() {
    case "$1" in
        network)
            [[ "$2" == "ls" ]] && { echo "docker-tunnelsats"; return 0; }
            echo "DOCKER:$*" >> "$LOG"; return 0 ;;
        ps) printf 'cid_live lightning_lnd_1\ncid_old lnd\n'; return 0 ;;
        inspect)
            if [[ "$3" == *State.Running* ]]; then echo "false"; return 0; fi
            [[ "$4" == "cid_old" ]] && echo "attached 10.9.9.9 "
            return 0 ;;
    esac
    return 0
}
ip() { return 0; }
systemctl() { return 0; }
bash() { return 0; }
setup_docker_network
EOF
    assert_log_contains "$log" "DOCKER:network disconnect -f docker-tunnelsats cid_old" "Stale stopped container holding 10.9.9.9 is released"
    assert_log_contains "$log" "DOCKER:network connect --ip 10.9.9.9 docker-tunnelsats cid_live" "Only the stopped-for-restart daemon is attached with 10.9.9.9"
    assert_log_not_contains "$log" "DOCKER:network connect --ip 10.9.9.9 docker-tunnelsats cid_old" "Stale container is never attached to 10.9.9.9"
    rm -rf "$tmp_wg" "$tmp_sys" "$log"
}
test_setup_attaches_only_stopped_daemon_and_releases_stale_holder

test_attach_reattaches_container_with_wrong_address() {
    local log status
    log=$(mktemp)
    set +e
    run_case "$log" <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
LN_IMPL="lnd"
docker() {
    case "$1" in
        network) echo "DOCKER:$*" >> "$LOG"; return 0 ;;
        ps) echo "cid_a lightning_lnd_1"; return 0 ;;
        inspect) echo "attached  10.9.9.3"; return 0 ;;
    esac
    return 0
}
attach_container_to_tunnel_network cid_a
EOF
    status=$?
    set -e
    assert_status 0 "$status" "attach_container_to_tunnel_network succeeds for container attached with another address"
    assert_log_contains "$log" "DOCKER:network disconnect -f docker-tunnelsats cid_a" "Container with non-10.9.9.9 address is detached first"
    assert_log_contains "$log" "DOCKER:network connect --ip 10.9.9.9 docker-tunnelsats cid_a" "Container is reattached with 10.9.9.9 (verification can pass)"
    rm -f "$log"
}
test_attach_reattaches_container_with_wrong_address

test_attach_noop_when_static_ip_already_configured_on_stopped_container() {
    local log
    log=$(mktemp)
    run_case "$log" <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
LN_IMPL="lnd"
docker() {
    case "$1" in
        network) echo "DOCKER:$*" >> "$LOG"; return 0 ;;
        ps) echo "cid_a lightning_lnd_1"; return 0 ;;
        inspect) echo "attached 10.9.9.9 "; return 0 ;;  # stopped: static IPAM set, live IP empty
    esac
    return 0
}
attach_container_to_tunnel_network cid_a
EOF
    assert_log_not_contains "$log" "DOCKER:network" "Stopped container with static 10.9.9.9 is left untouched (no duplicate connect)"
    rm -f "$log"
}
test_attach_noop_when_static_ip_already_configured_on_stopped_container

test_attach_refuses_to_evict_running_holder() {
    local log status
    log=$(mktemp)
    set +e
    run_case "$log" <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
LN_IMPL="lnd"
docker() {
    case "$1" in
        network) echo "DOCKER:$*" >> "$LOG"; return 0 ;;
        ps) printf 'cid_a lightning_lnd_1\ncid_b lnd\n'; return 0 ;;
        inspect)
            if [[ "$3" == *State.Running* ]]; then echo "true"; return 0; fi
            [[ "$4" == "cid_b" ]] && echo "attached 10.9.9.9 10.9.9.9"
            return 0 ;;
    esac
    return 0
}
attach_container_to_tunnel_network cid_a
EOF
    status=$?
    set -e
    assert_status 1 "$status" "attach_container_to_tunnel_network refuses when a running container holds 10.9.9.9"
    assert_log_not_contains "$log" "DOCKER:network disconnect -f docker-tunnelsats cid_b" "Running holder is never evicted"
    rm -f "$log"
}
test_attach_refuses_to_evict_running_holder

test_stop_aborts_on_multiple_running_daemons_before_stopping() {
    local log status
    log=$(mktemp)
    set +e
    run_case "$log" <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
PLATFORM="umbrel"; LN_IMPL="lnd"; WG_INTERFACE=""
docker() {
    case "$1" in
        ps) printf 'cid_a lightning_lnd_1\ncid_b lnd\n'; return 0 ;;
        stop) echo "DOCKER:$*" >> "$LOG"; return 0 ;;
    esac
    return 0
}
stop_lightning_daemon_for_safe_restart
EOF
    status=$?
    set -e
    assert_status 1 "$status" "stop_lightning_daemon_for_safe_restart aborts when multiple daemons would compete for 10.9.9.9"
    assert_log_not_contains "$log" "DOCKER:stop" "No daemon is stopped when aborting on ambiguity"
    rm -f "$log"
}
test_stop_aborts_on_multiple_running_daemons_before_stopping

test_generated_monitor_attaches_single_target() {
    local tmp_wg tmp_sys tmp_bin log
    tmp_wg=$(mktemp -d); tmp_sys=$(mktemp -d); tmp_bin=$(mktemp -d); log=$(mktemp)
    WG_DIR_T="$tmp_wg" SYSTEMD_DIR_T="$tmp_sys" run_case /dev/null <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
PLATFORM="umbrel"; LN_IMPL="lnd"; WG_INTERFACE="tunnelsatsv2"
WG_DIR="$WG_DIR_T"; SYSTEMD_DIR="$SYSTEMD_DIR_T"
docker() {
    case "$1" in
        network) [[ "$2" == "ls" ]] && echo "docker-tunnelsats"; return 0 ;;
        ps) echo "cid_live lightning_lnd_1"; return 0 ;;
        inspect) echo "attached 10.9.9.9 10.9.9.9"; return 0 ;;
    esac
    return 0
}
ip() { return 0; }
systemctl() { return 0; }
bash() { return 0; }
setup_docker_network
EOF
    # Fake docker binary: one running daemon (not attached) and one stale stopped container holding 10.9.9.9
    cat > "$tmp_bin/docker" <<EOF
#!/bin/bash
case "\$1" in
  network)
    if [ "\$2" = "ls" ]; then echo "docker-tunnelsats"; exit 0; fi
    echo "DOCKER:\$*" >> "$log"; exit 0 ;;
  ps)
    if [ "\$2" = "-a" ]; then printf 'cid_live lightning_lnd_1\ncid_old lnd\n'; else echo "cid_live lightning_lnd_1"; fi
    exit 0 ;;
  inspect)
    case "\$3" in *State.Running*) echo false; exit 0 ;; esac
    [ "\$4" = "cid_old" ] && echo "attached 10.9.9.9 "
    exit 0 ;;
esac
exit 0
EOF
    chmod +x "$tmp_bin/docker"
    local status
    set +e
    PATH="$tmp_bin:$PATH" sh "$tmp_wg/tunnelsats-docker-network.sh" &>/dev/null
    status=$?
    set -e
    assert_status 0 "$status" "Generated monitor script runs successfully"
    assert_log_contains "$log" "DOCKER:network disconnect -f docker-tunnelsats cid_old" "Monitor releases 10.9.9.9 from stale stopped container"
    assert_log_contains "$log" "DOCKER:network connect --ip 10.9.9.9 docker-tunnelsats cid_live" "Monitor attaches only the running daemon"
    assert_log_not_contains "$log" "connect --ip 10.9.9.9 docker-tunnelsats cid_old" "Monitor never attaches stale container"
    rm -rf "$tmp_wg" "$tmp_sys" "$tmp_bin" "$log"
}
test_generated_monitor_attaches_single_target

test_generated_monitor_keeps_owner_while_no_daemon_running() {
    local tmp_wg tmp_sys tmp_bin log
    tmp_wg=$(mktemp -d); tmp_sys=$(mktemp -d); tmp_bin=$(mktemp -d); log=$(mktemp)
    WG_DIR_T="$tmp_wg" SYSTEMD_DIR_T="$tmp_sys" run_case /dev/null <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
PLATFORM="umbrel"; LN_IMPL="lnd"; WG_INTERFACE="tunnelsatsv2"
WG_DIR="$WG_DIR_T"; SYSTEMD_DIR="$SYSTEMD_DIR_T"
docker() {
    case "$1" in
        network) [[ "$2" == "ls" ]] && echo "docker-tunnelsats"; return 0 ;;
        ps) echo "cid_live lightning_lnd_1"; return 0 ;;
        inspect) echo "attached 10.9.9.9 10.9.9.9"; return 0 ;;
    esac
    return 0
}
ip() { return 0; }
systemctl() { return 0; }
bash() { return 0; }
setup_docker_network
EOF
    # Installer window: daemon stopped (owns static 10.9.9.9), newer stale stopped container listed first
    cat > "$tmp_bin/docker" <<EOF
#!/bin/bash
case "\$1" in
  network)
    if [ "\$2" = "ls" ]; then echo "docker-tunnelsats"; exit 0; fi
    echo "DOCKER:\$*" >> "$log"; exit 0 ;;
  ps)
    if [ "\$2" = "-a" ]; then printf 'cid_stale_newer lnd\ncid_installer lightning_lnd_1\n'; fi
    exit 0 ;;
  inspect)
    case "\$3" in *State.Running*) echo false; exit 0 ;; esac
    [ "\$4" = "cid_installer" ] && echo "attached 10.9.9.9 "
    exit 0 ;;
esac
exit 0
EOF
    chmod +x "$tmp_bin/docker"
    local status
    set +e
    PATH="$tmp_bin:$PATH" sh "$tmp_wg/tunnelsats-docker-network.sh" &>/dev/null
    status=$?
    set -e
    assert_status 0 "$status" "Monitor exits cleanly while no daemon is running"
    assert_log_not_contains "$log" "DOCKER:network" "Monitor never reassigns 10.9.9.9 away from the stopped owner (no disconnect/connect)"
    rm -rf "$tmp_wg" "$tmp_sys" "$tmp_bin" "$log"
}
test_generated_monitor_keeps_owner_while_no_daemon_running

test_select_target_prefers_current_owner_over_newest_stopped() {
    local output
    output=$(run_case /dev/null <<'EOF' 2>/dev/null
source "$SCRIPT_UNDER_TEST"
LN_IMPL="lnd"; stopped_docker_containers=""
docker() {
    case "$1" in
        ps) [[ "$2" == "-a" ]] && printf 'cid_stale_newer lnd\ncid_owner lightning_lnd_1\n'; return 0 ;;
        inspect) [[ "$4" == "cid_owner" ]] && echo "attached 10.9.9.9 "; return 0 ;;
    esac
    return 0
}
select_tunnel_target_container
EOF
)
    assert_equals "cid_owner" "$output" "select_tunnel_target_container prefers the stopped container already owning 10.9.9.9"
}
test_select_target_prefers_current_owner_over_newest_stopped

# ---------------------------------------------------------------------------
# TEST GROUP 8: Selector-scoped policy rule cleanup
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 8: Selector-Scoped Rule Cleanup ---"

test_cleanup_preserves_foreign_rules_on_shared_priorities() {
    local rules_file log
    rules_file=$(mktemp); log=$(mktemp)
    printf '21820:\tfrom all lookup 100\n21821:\tfrom 192.168.1.0/24 lookup 200\n21821:\tfrom 10.9.9.0/25 lookup 51820\n' > "$rules_file"
    RULES="$rules_file" run_case "$log" <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
WG_INTERFACE="tunnelsatsv2"
wg() { return 0; }
ip() {
    if [[ "$*" == *"route show table 51820"* ]]; then return 0; fi
    if [[ "$1" == "rule" && "$2" == "show" ]]; then cat "$RULES"; return 0; fi
    if [[ "$1" == "rule" && "$2" == "del" ]]; then
        echo "RULE_DEL:$*" >> "$LOG"
        [[ "$*" == *"from 10.9.9.0/25 table 51820"* ]] && sed -i '/10.9.9.0\/25 lookup 51820/d' "$RULES"
        return 0
    fi
    return 0
}
check_and_cleanup_routing_table "tunnelsatsv2"
EOF
    assert_log_contains "$log" "RULE_DEL:rule del priority 21821 from 10.9.9.0/25 table 51820" "Owned Docker rule is deleted by full selector"
    assert_log_not_contains "$log" "RULE_DEL:rule del priority 21820" "Foreign rule at priority 21820 (table 100) is preserved"
    if grep -q "lookup 100" "$rules_file" && grep -q "lookup 200" "$rules_file"; then
        echo "PASS: Foreign rules sharing TunnelSats priorities remain installed"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: Foreign rules sharing TunnelSats priorities were removed"
        fail_count=$((fail_count + 1))
    fi
    rm -f "$rules_file" "$log"
}
test_cleanup_preserves_foreign_rules_on_shared_priorities

# ---------------------------------------------------------------------------
# TEST GROUP 9: Install failure rollback
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 9: Install Failure Rollback ---"

test_rollback_restores_previous_tunnel_then_restarts_daemon() {
    local log tmp status
    log=$(mktemp); tmp=$(mktemp -d)
    echo "old" > "$tmp/backup"; echo "new" > "$tmp/tunnelsatsv2.conf"
    set +e
    TMPD="$tmp" run_case "$log" <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
PLATFORM="umbrel"; LN_IMPL="lnd"; WG_INTERFACE="tunnelsatsv2"
stopped_docker_containers="cid_live"; stopped_wireguard_interface="tunnelsatsv2"
WG_CONFIG_PATH="$TMPD/tunnelsatsv2.conf"; WG_CONFIG_BACKUP="$TMPD/backup"
systemctl() { echo "SYSTEMCTL:$*" >> "$LOG"; [[ "$1" == "is-active" ]] && return 1; return 0; }
wg() { return 0; }
ip() { [[ "$1 $2" == "rule show" ]] && echo "21821:	from 10.9.9.0/25 lookup 51820"; return 0; }
docker() {
    case "$1" in
        start) echo "DOCKER:$*" >> "$LOG"; return 0 ;;
        ps) echo "cid_live lightning_lnd_1"; return 0 ;;
        inspect) echo "attached 10.9.9.9 "; return 0 ;;
    esac
    return 0
}
trap rollback_failed_install EXIT
exit 1
EOF
    status=$?
    set -e
    assert_status 1 "$status" "Rollback preserves the original failure exit code"
    assert_equals "old" "$(cat "$tmp/tunnelsatsv2.conf")" "Rollback restores the previous WireGuard config from backup"
    assert_log_contains "$log" "SYSTEMCTL:start wg-quick@tunnelsatsv2" "Rollback restarts the previous tunnel"
    assert_log_contains "$log" "DOCKER:start cid_live" "Daemon is restarted once the previous tunnel is verified"
    rm -rf "$log" "$tmp"
}
test_rollback_restores_previous_tunnel_then_restarts_daemon

test_rollback_keeps_daemon_stopped_without_previous_tunnel() {
    local log status
    log=$(mktemp)
    set +e
    run_case "$log" <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
PLATFORM="umbrel"; LN_IMPL="lnd"; WG_INTERFACE="tunnelsatsv2"
stopped_docker_containers="cid_live"; stopped_wireguard_interface=""
systemctl() { [[ "$1" == "is-active" ]] && return 1; echo "SYSTEMCTL:$*" >> "$LOG"; return 0; }
wg() { return 0; }
docker() { echo "DOCKER:$*" >> "$LOG"; return 0; }
trap rollback_failed_install EXIT
exit 1
EOF
    status=$?
    set -e
    assert_status 1 "$status" "Rollback without previous tunnel exits with failure"
    assert_log_not_contains "$log" "DOCKER:start" "Daemon stays stopped when no previous tunnel exists (fail-closed)"
    rm -f "$log"
}
test_rollback_keeps_daemon_stopped_without_previous_tunnel

test_rollback_keeps_daemon_stopped_if_tunnel_restore_fails() {
    local log status
    log=$(mktemp)
    set +e
    run_case "$log" <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
PLATFORM="baremetal"; LN_IMPL="lnd"; WG_INTERFACE="tunnelsatsv2"
restarted_systemd_service="lnd.service"; stopped_wireguard_interface="tunnelsatsv2"
systemctl() {
    echo "SYSTEMCTL:$*" >> "$LOG"
    [[ "$1" == "is-active" ]] && return 1
    [[ "$1" == "start" && "$2" == wg-quick@* ]] && return 1
    return 0
}
wg() { return 1; }
trap rollback_failed_install EXIT
exit 1
EOF
    status=$?
    set -e
    assert_status 1 "$status" "Rollback with failed tunnel restore exits with failure"
    assert_log_not_contains "$log" "SYSTEMCTL:start lnd.service" "Daemon stays stopped when previous tunnel cannot be restored (fail-closed)"
    rm -f "$log"
}
test_rollback_keeps_daemon_stopped_if_tunnel_restore_fails

echo ""
echo "--------------------------------"
echo "Passed: $pass_count"
echo "Failed: $fail_count"
echo "--------------------------------"

if [[ "$fail_count" -gt 0 ]]; then
    exit 1
fi
