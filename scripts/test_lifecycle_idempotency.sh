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

# ---------------------------------------------------------------------------
# TEST GROUP 10: Ownership-scoped runtime hooks (table 51820)
# The real config is generated by configure_wireguard and its PostUp/PostDown hooks are
# replayed the way wg-quick executes them, against a stateful fake `ip` binary.
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 10: Ownership-Scoped Runtime Hooks ---"

# Generates the production WireGuard config (and route guard) for platform $1 into directory $2.
generate_tunnel_config() {
    local platform="$1" dir="$2"
    cat > "$dir/source.conf" <<'CONF'
[Interface]
PrivateKey = aaaaaa=
Address = 10.9.0.2/32
#VPNPort = 23456

[Peer]
PublicKey = bbbbbb=
Endpoint = de1.tunnelsats.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONF
    PLATFORM_T="$platform" DIR_T="$dir" run_case /dev/null <<'EOF' >/dev/null 2>&1
source "$SCRIPT_UNDER_TEST"
PLATFORM="$PLATFORM_T"; LN_IMPL="lnd"; WG_DIR="$DIR_T"; CONFIG_FILE="$DIR_T/source.conf"
# Optional: NODE_USER_T / NODE_UID_T model the detected node user and its uid (`id -u`).
# Optional: DOCKER_SUBNET_T models a custom docker-tunnelsats subnet returned by docker network inspect.
node_user="${NODE_USER_T:-}"
id() { [[ "$1" == "-u" && -n "${NODE_UID_T:-}" ]] && { echo "$NODE_UID_T"; return 0; }; return 1; }
resolve_wg_target_path() { echo "$DIR_T/tunnelsatsv2.conf"; }
docker() {
    if [[ -n "${DOCKER_SUBNET_T:-}" && "$1 $2" == "network inspect" ]]; then
        echo "${DOCKER_SUBNET_T} 6c3d330ad9f50000"
        return 0
    fi
    return 1
}
ip() { [[ "$1" == "route" ]] && echo "192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.10"; return 0; }
sysctl() { echo 0; }
configure_wireguard
EOF
}

# Creates fake ip/nft/iptables/sysctl/ping binaries in $1. `ip` keeps table 51820 in $ROUTES
# (file absent = table does not exist) and logs every call to $HOOK_LOG.
make_fake_net_bin() {
    local bin="$1" tool
    cat > "$bin/ip" <<'FAKEIP'
#!/bin/bash
echo "IP:$*" >> "$HOOK_LOG"
[[ "$1" == "-4" ]] && shift
args="$*"
# Blackhole policy rules live in $RULES in `ip -4 rule show` format ("21818:<TAB>from X blackhole").
# IP_FAIL_RULE_ADD=1 / IP_FAIL_RULE_DEL=1 / IP_FAIL_RULE_SHOW=1 simulate kernel/permission failures.
rules="${RULES:-/dev/null}"
case "$args" in
    "rule show")
        [[ "${IP_FAIL_RULE_SHOW:-0}" == 1 ]] && { echo "RTNETLINK answers: Operation not permitted" >&2; exit 2; }
        [[ -f "$rules" ]] && cat "$rules"
        exit 0 ;;
    "rule add "*" blackhole priority "*)
        [[ "${IP_FAIL_RULE_ADD:-0}" == 1 ]] && { echo "RTNETLINK answers: Operation not permitted" >&2; exit 2; }
        set -- $args
        case "$3" in
            from) line="$7:"$'\t'"from $4 blackhole" ;;
            uidrange) line="$7:"$'\t'"from all uidrange $4 blackhole" ;;
            *) exit 2 ;;
        esac
        if [[ -f "$rules" ]] && grep -qxF -- "$line" "$rules"; then
            echo "RTNETLINK answers: File exists" >&2; exit 2
        fi
        echo "$line" >> "$rules"
        exit 0 ;;
    "rule del priority "*" blackhole")
        [[ "${IP_FAIL_RULE_DEL:-0}" == 1 ]] && { echo "RTNETLINK answers: Operation not permitted" >&2; exit 2; }
        set -- $args
        case "$5" in
            from) line="$4:"$'\t'"from $6 blackhole" ;;
            uidrange) line="$4:"$'\t'"from all uidrange $6 blackhole" ;;
            *) exit 2 ;;
        esac
        n=$([[ -f "$rules" ]] && grep -nxF -- "$line" "$rules" | head -n 1 | cut -d: -f1)
        if [[ -z "$n" ]]; then echo "RTNETLINK answers: No such file or directory" >&2; exit 2; fi
        sed -i "${n}d" "$rules"
        exit 0 ;;
esac
case "$1 $2" in
    "route show")
        if [[ "$args" == *"table 51820"* ]]; then
            if [[ ! -f "$ROUTES" ]]; then
                echo "Error: ipv4: FIB table does not exist." >&2; echo "Dump terminated" >&2; exit 2
            fi
            cat "$ROUTES"
        fi
        exit 0 ;;
    "route flush")
        [[ "$args" == *"table 51820"* ]] && : > "$ROUTES"
        exit 0 ;;
    "route add")
        [[ "$args" == *"table 51820"* ]] || exit 0
        spec="${args#route add }"; spec="${spec/ table 51820/}"
        case "$spec" in
            "blackhole default metric 3") line="blackhole default metric 3 " ;;
            "default dev "*) set -- $spec; line="default dev $3 scope link${5:+ metric $5}" ;;
            *) line="$spec" ;;
        esac
        if [[ -f "$ROUTES" ]] && grep -qxF -- "$line" "$ROUTES"; then
            echo "RTNETLINK answers: File exists" >&2; exit 2
        fi
        echo "$line" >> "$ROUTES"
        exit 0 ;;
    "route del")
        spec="${args#route del }"; spec="${spec/ table 51820/}"
        [[ -f "$ROUTES" ]] || exit 2
        case "$spec" in
            "blackhole default metric 3") pat='^blackhole default metric 3 *$' ;;
            "default dev "*) set -- $spec; pat="^default dev $3( |$)" ;;
            *) exit 2 ;;
        esac
        n=$(grep -nE "$pat" "$ROUTES" | head -n 1 | cut -d: -f1)
        if [[ -z "$n" ]]; then echo "RTNETLINK answers: No such process" >&2; exit 2; fi
        sed -i "${n}d" "$ROUTES"
        exit 0 ;;
    "rule del") exit 2 ;;
esac
exit 0
FAKEIP
    for tool in iptables sysctl ping; do
        printf '#!/bin/bash\necho "%s:$*" >> "$HOOK_LOG"\nexit 0\n' "${tool^^}" > "$bin/$tool"
    done
    cat > "$bin/nft" <<'FAKENFT'
#!/bin/bash
# Stateful nft for table "ip tunnelsats_failclosed", kept in $NFT_STATE (absent = no table).
# NFT_FAIL_RULES=1 makes nft reject "add rule" (e.g. nf_tables failed to load).
echo "NFT:$*" >> "$HOOK_LOG"
state="${NFT_STATE:-/dev/null}"
args="$*"
case "$args" in
    "add table ip tunnelsats_failclosed") touch "$state"; exit 0 ;;
    "add chain ip tunnelsats_failclosed "*) [[ -f "$state" ]] || exit 1; echo "chain ${args#add chain ip tunnelsats_failclosed }" >> "$state"; exit 0 ;;
    "add rule ip tunnelsats_failclosed "*)
        [[ "${NFT_FAIL_RULES:-0}" == 1 ]] && { echo "Error: Could not process rule: No such file or directory" >&2; exit 1; }
        [[ -f "$state" ]] || exit 1
        echo "rule ${args#add rule ip tunnelsats_failclosed }" >> "$state"; exit 0 ;;
    "list table ip tunnelsats_failclosed") [[ -f "$state" ]] || { echo "Error: No such file or directory" >&2; exit 1; }; cat "$state"; exit 0 ;;
    "delete table ip tunnelsats_failclosed") [[ -f "$state" ]] || exit 1; rm -f "$state"; exit 0 ;;
esac
exit 0
FAKENFT
    chmod +x "$bin"/*
}

# Replays the $1 (PostUp|PostDown) hooks of config $2 like wg-quick: comment stripping,
# %i substitution, one `(eval "$hook")` per hook under `set -e -o pipefail`.
run_wg_hooks() {
    local kind="$1" conf="$2" bin="$3"
    PATH="$bin:$PATH" KIND="$kind" CONF="$conf" bash -c '
        set -e -o pipefail
        shopt -s extglob
        hooks=()
        while IFS= read -r line || [[ -n "$line" ]]; do
            stripped="${line%%\#*}"
            key="${stripped%%=*}"; key="${key##*([[:space:]])}"; key="${key%%*([[:space:]])}"
            value="${stripped#*=}"; value="${value##*([[:space:]])}"; value="${value%%*([[:space:]])}"
            [[ "$key" == "$KIND" ]] && hooks+=("$value")
        done < "$CONF"
        for hook in "${hooks[@]}"; do
            hook="${hook//%i/tunnelsatsv2}"
            (eval "$hook")
        done
    '
}

assert_file_contains_line() {
    local file="$1" needle="$2" desc="$3"
    if [[ -f "$file" ]] && grep -qF -- "$needle" "$file"; then
        echo "PASS: $desc"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc (missing '$needle')"
        fail_count=$((fail_count + 1))
    fi
}

assert_file_not_contains_line() {
    local file="$1" needle="$2" desc="$3"
    if [[ -f "$file" ]] && grep -qF -- "$needle" "$file"; then
        echo "FAIL: $desc (unexpected '$needle')"
        fail_count=$((fail_count + 1))
    else
        echo "PASS: $desc"
        pass_count=$((pass_count + 1))
    fi
}

test_runtime_hooks_scope() {
    local platform="$1" label="$2" dir bin status
    dir=$(mktemp -d); bin=$(mktemp -d)
    generate_tunnel_config "$platform" "$dir"
    make_fake_net_bin "$bin"
    local conf="$dir/tunnelsatsv2.conf"
    export HOOK_LOG="$dir/hooks.log" ROUTES="$dir/table51820" NFT_STATE="$dir/nft_failclosed" RULES="$dir/rules"

    if [[ ! -f "$conf" ]]; then
        echo "FAIL: [$label] configure_wireguard did not generate a config"
        fail_count=$((fail_count + 1))
        rm -rf "$dir" "$bin"; return
    fi
    assert_log_not_contains "$conf" "route flush table 51820" "[$label] Generated hooks never flush table 51820"

    # 1) Clean start: no table yet
    rm -f "$ROUTES"; : > "$HOOK_LOG"
    set +e; run_wg_hooks PostUp "$conf" "$bin" &>/dev/null; status=$?; set -e
    assert_status 0 "$status" "[$label] PostUp succeeds on an empty table"
    assert_file_contains_line "$ROUTES" "default dev tunnelsatsv2" "[$label] PostUp installs the tunnel default route in table 51820"
    assert_log_contains "$HOOK_LOG" "NFT:delete table ip tunnelsats_failclosed" "[$label] Successful PostUp releases any emergency fail-closed drop"
    local route_line rule_line
    route_line=$(grep -n "IP:route add default dev tunnelsatsv2" "$HOOK_LOG" | head -n 1 | cut -d: -f1)
    rule_line=$(grep -n "IP:rule add .*table 51820" "$HOOK_LOG" | head -n 1 | cut -d: -f1)
    if [[ -n "$route_line" && -n "$rule_line" && "$route_line" -lt "$rule_line" ]]; then
        echo "PASS: [$label] Table 51820 routes exist before policy rules steer traffic into it"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: [$label] Policy rule added before table 51820 routes (route=$route_line rule=$rule_line)"
        fail_count=$((fail_count + 1))
    fi

    # 2) Restart with stale TunnelSats-owned routes only: idempotent
    : > "$HOOK_LOG"
    printf 'blackhole default metric 3 \n' > "$ROUTES"
    set +e; run_wg_hooks PostUp "$conf" "$bin" &>/dev/null; status=$?; set -e
    assert_status 0 "$status" "[$label] PostUp succeeds when only stale TunnelSats-owned routes exist"

    # 3) PostDown after another service started using table 51820 must keep its routes
    : > "$HOOK_LOG"
    printf 'blackhole default metric 3 \n10.20.0.0/16 dev wg1 scope link \n' > "$ROUTES"
    set +e; run_wg_hooks PostDown "$conf" "$bin" &>/dev/null; status=$?; set -e
    assert_status 0 "$status" "[$label] PostDown completes"
    assert_file_contains_line "$ROUTES" "10.20.0.0/16 dev wg1" "[$label] PostDown preserves foreign routes in table 51820"
    assert_file_not_contains_line "$ROUTES" "blackhole default metric 3" "[$label] PostDown removes the TunnelSats-owned blackhole"

    # 4) PostUp while another service owns routes in table 51820: refuse and fail closed
    : > "$HOOK_LOG"
    printf 'default dev wg1 scope link \n' > "$ROUTES"
    set +e; run_wg_hooks PostUp "$conf" "$bin" &>/dev/null; status=$?; set -e
    if [[ "$status" -ne 0 ]]; then
        echo "PASS: [$label] PostUp refuses to start when table 51820 holds foreign routes (exit=$status)"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: [$label] PostUp started despite foreign routes in table 51820"
        fail_count=$((fail_count + 1))
    fi
    assert_file_contains_line "$ROUTES" "default dev wg1" "[$label] Foreign route survives the refused PostUp"
    assert_log_not_contains "$HOOK_LOG" "IP:rule add" "[$label] No policy rule steers traffic into a foreign-owned table"
    assert_log_contains "$HOOK_LOG" "NFT:add rule ip tunnelsats_failclosed output meta cgroup 1118498 fib daddr type != local counter drop" "[$label] Refused PostUp arms the emergency fail-closed drop"
    assert_log_contains "$HOOK_LOG" "NFT:add rule ip tunnelsats_failclosed forward ip saddr 10.9.9.0/25 fib daddr type != local counter drop" "[$label] Emergency drop also covers forwarded Docker traffic"
    assert_log_contains "$HOOK_LOG" "NFT:list table ip tunnelsats_failclosed" "[$label] Emergency drop is verified with a real ruleset read"
    assert_log_not_contains "$HOOK_LOG" "blackhole priority" "[$label] Verified nft drop needs no blackhole rule fallback"

    # 5) Unreadable table state is unverified: fail closed
    : > "$HOOK_LOG"
    rm -f "$ROUTES"
    cat > "$bin/ip" <<'BROKENIP'
#!/bin/bash
echo "IP:$*" >> "$HOOK_LOG"
[[ "$1 $2" == "route show" ]] && { echo "Error: permission denied" >&2; exit 1; }
exit 0
BROKENIP
    chmod +x "$bin/ip"
    set +e; run_wg_hooks PostUp "$conf" "$bin" &>/dev/null; status=$?; set -e
    if [[ "$status" -ne 0 ]]; then
        echo "PASS: [$label] PostUp fails closed when table 51820 cannot be read (exit=$status)"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: [$label] PostUp started although table 51820 could not be verified"
        fail_count=$((fail_count + 1))
    fi
    assert_log_not_contains "$HOOK_LOG" "IP:rule add" "[$label] No policy rule is added when table state is unverified"

    unset HOOK_LOG ROUTES NFT_STATE RULES
    rm -rf "$dir" "$bin"
}
test_runtime_hooks_scope umbrel "Docker"
test_runtime_hooks_scope baremetal "Non-Docker"

# Replays PostUp of $1 with fake binaries $2; sets globals hook_status / hook_err.
replay_postup() {
    set +e; hook_err=$(run_wg_hooks PostUp "$1" "$2" 2>&1 >/dev/null); hook_status=$?; set -e
}

count_lines() {
    local file="$1" needle="$2"
    if [[ -f "$file" ]]; then grep -cxF -- "$needle" "$file" || true; else echo 0; fi
}

TAB=$'\t'

test_refused_postup_reports_unarmed_failclosed() {
    local dir bin
    dir=$(mktemp -d); bin=$(mktemp -d)
    generate_tunnel_config umbrel "$dir"
    make_fake_net_bin "$bin"
    # nft rejects the drop rules AND the kernel rejects the blackhole policy rules
    export HOOK_LOG="$dir/hooks.log" ROUTES="$dir/table51820" NFT_STATE="$dir/nft_failclosed" RULES="$dir/rules"
    export NFT_FAIL_RULES=1 IP_FAIL_RULE_ADD=1
    printf 'default dev wg1 scope link \n' > "$ROUTES"
    replay_postup "$dir/tunnelsatsv2.conf" "$bin"
    assert_status 3 "$hook_status" "Refused PostUp exits 3 when neither nft nor the blackhole rule fallback can be armed"
    if [[ "$hook_err" == *"could NOT be armed (nft and the blackhole ip rule fallback both failed)"* ]] && \
       [[ "$hook_err" != *"armed and verified"* ]]; then
        echo "PASS: Guard reports that no emergency block is armed instead of claiming traffic is blocked"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: Guard did not report the failed emergency block (stderr: $hook_err)"
        fail_count=$((fail_count + 1))
    fi
    assert_log_not_contains "$HOOK_LOG" "IP:rule add" "No policy rule into table 51820 is added when the refused start cannot arm the block"
    unset HOOK_LOG ROUTES NFT_STATE RULES NFT_FAIL_RULES IP_FAIL_RULE_ADD
    rm -rf "$dir" "$bin"
}
test_refused_postup_reports_unarmed_failclosed

test_failclosed_rule_fallback_docker() {
    local dir bin conf
    dir=$(mktemp -d); bin=$(mktemp -d)
    generate_tunnel_config umbrel "$dir"
    make_fake_net_bin "$bin"
    conf="$dir/tunnelsatsv2.conf"
    export HOOK_LOG="$dir/hooks.log" ROUTES="$dir/table51820" NFT_STATE="$dir/nft_failclosed" RULES="$dir/rules"
    export NFT_FAIL_RULES=1
    printf 'default dev wg1 scope link \n' > "$ROUTES"

    replay_postup "$conf" "$bin"
    assert_status 1 "$hook_status" "[Docker] nft failure: refused PostUp is armed via the blackhole rule fallback (exit 1)"
    assert_file_contains_line "$RULES" "21818:${TAB}from 10.9.9.0/25 blackhole" "[Docker] Fallback blackholes the Docker tunnel subnet ahead of the main table"
    assert_file_not_contains_line "$RULES" "21819:" "[Docker] No host uid rule on Docker platforms"
    assert_log_contains "$HOOK_LOG" "IP:-4 rule show" "[Docker] Fallback is verified with a real policy-rule read"
    if [[ "$hook_err" == *"routing-policy fallback armed and verified"* ]]; then
        echo "PASS: [Docker] Guard reports the verified fallback"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: [Docker] Guard did not report the verified fallback (stderr: $hook_err)"
        fail_count=$((fail_count + 1))
    fi

    # A repeated refusal must not stack duplicate rules
    replay_postup "$conf" "$bin"
    assert_status 1 "$hook_status" "[Docker] Repeated refusal stays armed"
    assert_equals "1" "$(count_lines "$RULES" "21818:${TAB}from 10.9.9.0/25 blackhole")" "[Docker] Repeated refusal adds no duplicate blackhole rule"

    # Tunnel comes up: our blackhole rule is released, foreign rules on the same priorities survive
    unset NFT_FAIL_RULES
    printf '21818:\tfrom 10.50.0.0/16 blackhole\n21818:\tfrom all lookup 100\n21819:\tfrom all uidrange 9999-9999 blackhole\n' >> "$RULES"
    rm -f "$ROUTES"; : > "$HOOK_LOG"
    replay_postup "$conf" "$bin"
    assert_status 0 "$hook_status" "[Docker] PostUp succeeds once table 51820 is free"
    assert_file_not_contains_line "$RULES" "21818:${TAB}from 10.9.9.0/25 blackhole" "[Docker] Successful PostUp releases the emergency blackhole rule"
    assert_file_contains_line "$RULES" "21818:${TAB}from 10.50.0.0/16 blackhole" "[Docker] Release keeps a foreign blackhole rule on priority 21818"
    assert_file_contains_line "$RULES" "21818:${TAB}from all lookup 100" "[Docker] Release keeps a foreign lookup rule on priority 21818"
    assert_file_contains_line "$RULES" "21819:${TAB}from all uidrange 9999-9999 blackhole" "[Docker] Release keeps a foreign UID blackhole rule on priority 21819"

    unset HOOK_LOG ROUTES NFT_STATE RULES
    rm -rf "$dir" "$bin"
}
test_failclosed_rule_fallback_docker

test_failclosed_rule_fallback_non_docker() {
    local dir bin conf
    dir=$(mktemp -d); bin=$(mktemp -d)
    NODE_USER_T=lnd NODE_UID_T=4242 generate_tunnel_config baremetal "$dir"
    make_fake_net_bin "$bin"
    conf="$dir/tunnelsatsv2.conf"
    assert_log_contains "$conf" "check %i 10.9.9.0/25 4242" "[Non-Docker] Guard hook carries the node user's uid"
    assert_log_contains "$conf" "release 10.9.9.0/25 4242" "[Non-Docker] Release hook carries the subnet and node user's uid"
    export HOOK_LOG="$dir/hooks.log" ROUTES="$dir/table51820" NFT_STATE="$dir/nft_failclosed" RULES="$dir/rules"
    export NFT_FAIL_RULES=1
    printf 'default dev wg1 scope link \n' > "$ROUTES"

    replay_postup "$conf" "$bin"
    assert_status 1 "$hook_status" "[Non-Docker] nft failure: refused PostUp is armed via the blackhole rule fallback (exit 1)"
    assert_file_contains_line "$RULES" "21819:${TAB}from all uidrange 4242-4242 blackhole" "[Non-Docker] Fallback blackholes the host Lightning daemon's uid"
    assert_file_contains_line "$RULES" "21818:${TAB}from 10.9.9.0/25 blackhole" "[Non-Docker] Fallback also blackholes the tunnel subnet"

    replay_postup "$conf" "$bin"
    assert_equals "1" "$(count_lines "$RULES" "21819:${TAB}from all uidrange 4242-4242 blackhole")" "[Non-Docker] Repeated refusal adds no duplicate uid rule"

    # Another service has its own UID-range blackhole at 21819: release must keep it
    printf '21819:\tfrom all uidrange 9999-9999 blackhole\n' >> "$RULES"
    unset NFT_FAIL_RULES
    rm -f "$ROUTES"
    replay_postup "$conf" "$bin"
    assert_status 0 "$hook_status" "[Non-Docker] PostUp succeeds once table 51820 is free"
    assert_file_not_contains_line "$RULES" "21818:${TAB}from 10.9.9.0/25 blackhole" "[Non-Docker] Successful PostUp releases the TunnelSats subnet blackhole"
    assert_file_not_contains_line "$RULES" "21819:${TAB}from all uidrange 4242-4242 blackhole" "[Non-Docker] Successful PostUp releases the TunnelSats node UID blackhole"
    assert_file_contains_line "$RULES" "21819:${TAB}from all uidrange 9999-9999 blackhole" "[Non-Docker] Release preserves a foreign UID blackhole rule at priority 21819"

    unset HOOK_LOG ROUTES NFT_STATE RULES
    rm -rf "$dir" "$bin"
}
test_failclosed_rule_fallback_non_docker

test_failclosed_rule_fallback_custom_subnet() {
    local dir bin conf
    dir=$(mktemp -d); bin=$(mktemp -d)
    DOCKER_SUBNET_T="172.28.9.0/24" generate_tunnel_config umbrel "$dir"
    make_fake_net_bin "$bin"
    conf="$dir/tunnelsatsv2.conf"
    assert_log_contains "$conf" "check %i 172.28.9.0/24" "[Custom Subnet] Guard check hook carries custom Docker subnet"
    assert_log_contains "$conf" "release 172.28.9.0/24" "[Custom Subnet] Guard release hook carries custom Docker subnet"
    export HOOK_LOG="$dir/hooks.log" ROUTES="$dir/table51820" NFT_STATE="$dir/nft_failclosed" RULES="$dir/rules"
    export NFT_FAIL_RULES=1
    printf 'default dev wg1 scope link \n' > "$ROUTES"

    replay_postup "$conf" "$bin"
    assert_status 1 "$hook_status" "[Custom Subnet] Refused PostUp arms fallback for custom subnet (exit 1)"
    assert_file_contains_line "$RULES" "21818:${TAB}from 172.28.9.0/24 blackhole" "[Custom Subnet] Fallback blackholes custom Docker subnet"

    unset NFT_FAIL_RULES
    rm -f "$ROUTES"
    replay_postup "$conf" "$bin"
    assert_status 0 "$hook_status" "[Custom Subnet] PostUp succeeds once table 51820 is free"
    assert_file_not_contains_line "$RULES" "21818:${TAB}from 172.28.9.0/24 blackhole" "[Custom Subnet] Successful PostUp releases custom subnet blackhole rule"

    unset HOOK_LOG ROUTES NFT_STATE RULES
    rm -rf "$dir" "$bin"
}
test_failclosed_rule_fallback_custom_subnet

test_failclosed_release_failure_propagates() {
    local dir bin conf
    dir=$(mktemp -d); bin=$(mktemp -d)
    generate_tunnel_config umbrel "$dir"
    make_fake_net_bin "$bin"
    conf="$dir/tunnelsatsv2.conf"
    export HOOK_LOG="$dir/hooks.log" ROUTES="$dir/table51820" NFT_STATE="$dir/nft_failclosed" RULES="$dir/rules"
    printf '21818:\tfrom 10.9.9.0/25 blackhole\n' > "$RULES"

    export IP_FAIL_RULE_DEL=1
    replay_postup "$conf" "$bin"
    assert_status 1 "$hook_status" "[Release Failure] PostUp fails when emergency blackhole rule cannot be deleted"
    unset IP_FAIL_RULE_DEL

    export IP_FAIL_RULE_SHOW=1
    replay_postup "$conf" "$bin"
    assert_status 1 "$hook_status" "[Release Failure] PostUp fails when policy rules cannot be read during release"
    unset IP_FAIL_RULE_SHOW

    unset HOOK_LOG ROUTES NFT_STATE RULES
    rm -rf "$dir" "$bin"
}
test_failclosed_release_failure_propagates

test_failclosed_rule_fallback_unresolved_uid() {
    local dir bin conf
    dir=$(mktemp -d); bin=$(mktemp -d)
    NODE_USER_T=root NODE_UID_T=0 generate_tunnel_config baremetal "$dir"
    make_fake_net_bin "$bin"
    conf="$dir/tunnelsatsv2.conf"
    assert_log_contains "$conf" "check %i 10.9.9.0/25 unresolved" "[Non-Docker] A root node user is never passed to the uid blackhole"
    export HOOK_LOG="$dir/hooks.log" ROUTES="$dir/table51820" NFT_STATE="$dir/nft_failclosed" RULES="$dir/rules"
    export NFT_FAIL_RULES=1
    printf 'default dev wg1 scope link \n' > "$ROUTES"
    replay_postup "$conf" "$bin"
    assert_status 3 "$hook_status" "[Non-Docker] Unknown node uid: the fallback cannot cover the host daemon, guard reports exit 3"
    assert_file_not_contains_line "$RULES" "21819:" "[Non-Docker] No uid rule is added for an unknown or root node user"
    unset HOOK_LOG ROUTES NFT_STATE RULES NFT_FAIL_RULES
    rm -rf "$dir" "$bin"
}
test_failclosed_rule_fallback_unresolved_uid

test_resolve_failclosed_host_uid() {
    local out
    out=$(run_case /dev/null <<'EOF'
source "$SCRIPT_UNDER_TEST"
id() { case "$2" in lnd) echo 4242 ;; root) echo 0 ;; *) return 1 ;; esac; }
PLATFORM=umbrel; node_user=lnd; printf '[%s]' "$(resolve_failclosed_host_uid)"
PLATFORM=baremetal; node_user=lnd; printf '[%s]' "$(resolve_failclosed_host_uid)"
PLATFORM=raspiblitz; node_user=root; printf '[%s]' "$(resolve_failclosed_host_uid)"
PLATFORM=mynode; node_user=ghost; printf '[%s]' "$(resolve_failclosed_host_uid)"
PLATFORM=baremetal; node_user=""; printf '[%s]' "$(resolve_failclosed_host_uid)"
EOF
)
    assert_equals "[][4242][unresolved][unresolved][unresolved]" "$out" "resolve_failclosed_host_uid: Docker=empty, node uid, root/unknown/unset=unresolved"
}
test_resolve_failclosed_host_uid

test_failclosed_release_after_uid_change_or_removal() {
    local dir bin status
    dir=$(mktemp -d); bin=$(mktemp -d)
    NODE_USER_T=lnd NODE_UID_T=4242 generate_tunnel_config baremetal "$dir"
    make_fake_net_bin "$bin"
    export HOOK_LOG="$dir/hooks.log" ROUTES="$dir/table51820" NFT_STATE="$dir/nft_failclosed" RULES="$dir/rules"
    export NFT_FAIL_RULES=1
    printf 'default dev wg1 scope link \n' > "$ROUTES"

    # Guard arms fallback for UID 4242; foreign UID 9999 also exists
    replay_postup "$dir/tunnelsatsv2.conf" "$bin"
    assert_status 1 "$hook_status" "[UID Change] Fallback armed for original UID 4242"
    printf '21819:\tfrom all uidrange 9999-9999 blackhole\n' >> "$RULES"

    # Later uninstall runs after the lnd account was removed (resolve_failclosed_host_uid -> unresolved)
    unset NFT_FAIL_RULES
    set +e
    PATH="$bin:$PATH" WG_DIR="$dir" run_case /dev/null <<'EOF' >/dev/null 2>&1
source "$SCRIPT_UNDER_TEST"
PLATFORM=baremetal; node_user=deleted_user
id() { return 1; }
ts_release_failclosed "$(resolve_failclosed_subnet)" "$(resolve_failclosed_host_uid)"
EOF
    status=$?
    set -e
    assert_status 0 "$status" "[UID Change] Release succeeds during uninstall even after node account is removed"
    assert_file_not_contains_line "$RULES" "21819:${TAB}from all uidrange 4242-4242 blackhole" "[UID Change] Previously armed UID 4242 blackhole is removed"
    assert_file_not_contains_line "$RULES" "21818:${TAB}from 10.9.9.0/25 blackhole" "[UID Change] Previously armed subnet blackhole is removed"
    assert_file_contains_line "$RULES" "21819:${TAB}from all uidrange 9999-9999 blackhole" "[UID Change] Foreign UID 9999 blackhole is still preserved"

    unset HOOK_LOG ROUTES NFT_STATE RULES
    rm -rf "$dir" "$bin"
}
test_failclosed_release_after_uid_change_or_removal

# Real kernel: arm and release the fallback in an unprivileged network namespace and check that
# the kernel really refuses to route Lightning traffic through the main table while it is armed.
test_failclosed_rule_fallback_real_kernel() {
    if ! command -v unshare >/dev/null 2>&1 || ! unshare -rn true 2>/dev/null; then
        echo "SKIP: unprivileged network namespaces unavailable (real-kernel fallback test)"
        return 0
    fi
    local dir shim out
    dir=$(mktemp -d); shim=$(mktemp -d)
    generate_tunnel_config umbrel "$dir"
    # nft unavailable (e.g. nf_tables failed to load): force the routing-policy fallback
    printf '#!/bin/bash\nexit 1\n' > "$shim/nft"; chmod +x "$shim/nft"
    out=$(GUARD="$dir/tunnelsats-route-guard.sh" SHIM="$shim" unshare -rn bash -c '
        export PATH="$SHIM:$PATH"
        ip link set lo up
        ip link add d0 type dummy && ip link set d0 up
        ip addr add 192.168.77.2/24 dev d0
        ip route add default via 192.168.77.1
        ip route add default dev d0 table 51820        # foreign owner of table 51820
        ip -4 rule add from all lookup 100 priority 21818
        echo 1 > /proc/sys/net/ipv4/ip_forward
        ip route get 1.1.1.1 from 10.9.9.5 iif d0 >/dev/null 2>&1 && echo fwd_before=routed || echo fwd_before=blocked
        bash "$GUARD" check tunnelsatsv2 10.9.9.0/25 >/dev/null 2>&1; echo "guard=$?"
        ip -4 rule show | grep -c "^21818:[[:space:]]*from 10.9.9.0/25 blackhole" | sed "s/^/armed=/"
        ip route get 1.1.1.1 from 10.9.9.5 iif d0 >/dev/null 2>&1 && echo fwd=routed || echo fwd=blocked
        ip route get 192.168.77.2 >/dev/null 2>&1 && echo local=ok || echo local=broken
        ip -4 rule add uidrange 0-0 blackhole priority 21819
        bash "$GUARD" release 10.9.9.0/25 >/dev/null 2>&1
        ip -4 rule show | grep -c "^21818:[[:space:]]*from 10.9.9.0/25 blackhole" | sed "s/^/left=/"
        ip -4 rule show | grep -c "^21818:[[:space:]]*from all lookup 100" | sed "s/^/foreign_lookup=/"
        ip -4 rule show | grep -c "^21819:[[:space:]]*from all uidrange 0-0 blackhole" | sed "s/^/foreign_uid=/"
        ip -4 rule del priority 21819 uidrange 0-0 blackhole
        ip route get 1.1.1.1 from 10.9.9.5 iif d0 >/dev/null 2>&1 && echo fwd_after=routed || echo fwd_after=blocked
    ' 2>&1 | tr '\n' ' ')
    assert_equals "fwd_before=routed guard=1 armed=1 fwd=blocked local=ok left=0 foreign_lookup=1 foreign_uid=1 fwd_after=routed " "$out" \
        "Real kernel: fallback blocks forwarded tunnel-subnet traffic, keeps local routes, and release removes only TunnelSats rules while preserving foreign rules"
    rm -rf "$dir" "$shim"
}
test_failclosed_rule_fallback_real_kernel

test_failed_guard_rewrite_keeps_previous_guard() {
    local dir status
    dir=$(mktemp -d)
    echo "PREVIOUS-GUARD" > "$dir/tunnelsats-route-guard.sh"
    set +e
    DIR_T="$dir" run_case /dev/null <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
WG_DIR="$DIR_T"
cat() { return 1; }   # simulate a failed write (e.g. disk full) while generating the guard
write_route_guard_script
EOF
    status=$?
    set -e
    assert_status 1 "$status" "write_route_guard_script reports a failed write"
    assert_equals "PREVIOUS-GUARD" "$(command cat "$dir/tunnelsats-route-guard.sh")" "Failed rewrite leaves the previous route guard intact (rollback config keeps working)"
    local leftovers
    leftovers=$(find "$dir" -name 'tunnelsats-route-guard.sh.*' | wc -l)
    assert_equals "0" "$leftovers" "No temporary guard files are left behind"
    rm -rf "$dir"
}
test_failed_guard_rewrite_keeps_previous_guard

# ---------------------------------------------------------------------------
# TEST GROUP 11: Ownership-scoped installer/uninstaller route cleanup
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 11: Ownership-Scoped Installer Route Cleanup ---"

test_install_cleanup_never_flushes_table() {
    local log status
    log=$(mktemp)
    set +e
    run_case "$log" <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
WG_INTERFACE="tunnelsatsv2"
wg() { return 0; }
ip() {
    echo "IP:$*" >> "$LOG"
    if [[ "$*" == "route show table 51820" ]]; then printf 'blackhole default metric 3 \ndefault dev tunnelsatsv2 scope link metric 2 \n'; return 0; fi
    if [[ "$1 $2" == "rule show" ]]; then return 0; fi
    return 0
}
check_and_cleanup_routing_table "tunnelsatsv2"
EOF
    status=$?
    set -e
    assert_status 0 "$status" "check_and_cleanup_routing_table accepts a table holding only TunnelSats-owned routes"
    assert_log_not_contains "$log" "IP:route flush" "Installer cleanup never flushes table 51820"
    assert_log_contains "$log" "IP:route del blackhole default metric 3 table 51820" "Installer cleanup removes the owned blackhole route"
    assert_log_contains "$log" "IP:route del default dev tunnelsatsv2 table 51820" "Installer cleanup removes the owned tunnel default route"
    rm -f "$log"
}
test_install_cleanup_never_flushes_table

test_install_cleanup_accepts_absent_table() {
    local status
    set +e
    run_case /dev/null <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
wg() { return 0; }
ip() {
    if [[ "$*" == "route show table 51820" ]]; then echo "Error: ipv4: FIB table does not exist." >&2; echo "Dump terminated" >&2; return 2; fi
    return 0
}
check_and_cleanup_routing_table "tunnelsatsv2"
EOF
    status=$?
    set -e
    assert_status 0 "$status" "check_and_cleanup_routing_table treats a non-existent table 51820 as empty"
}
test_install_cleanup_accepts_absent_table

test_install_cleanup_fails_closed_on_unreadable_table() {
    local log status
    log=$(mktemp)
    set +e
    run_case "$log" <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
wg() { return 0; }
ip() {
    echo "IP:$*" >> "$LOG"
    if [[ "$*" == "route show table 51820" ]]; then echo "Error: permission denied" >&2; return 1; fi
    return 0
}
check_and_cleanup_routing_table "tunnelsatsv2"
EOF
    status=$?
    set -e
    assert_status 1 "$status" "check_and_cleanup_routing_table aborts when table 51820 cannot be read (fail-closed)"
    assert_log_not_contains "$log" "IP:route del" "No route is touched while table ownership is unverified"
    rm -f "$log"
}
test_install_cleanup_fails_closed_on_unreadable_table

test_uninstall_cleanup_preserves_foreign_routes() {
    local log status
    log=$(mktemp)
    set +e
    run_case "$log" <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
wg() { return 0; }
ip() {
    echo "IP:$*" >> "$LOG"
    if [[ "$*" == "route show table 51820" ]]; then printf 'blackhole default metric 3 \n10.20.0.0/16 dev wg1 scope link \n'; return 0; fi
    return 0
}
cleanup_owned_routing_state "tunnelsatsv2"
EOF
    status=$?
    set -e
    assert_status 0 "$status" "Uninstall routing cleanup does not abort when another service uses table 51820"
    assert_log_not_contains "$log" "IP:route flush" "Uninstall routing cleanup never flushes table 51820"
    assert_log_contains "$log" "IP:route del blackhole default metric 3 table 51820" "Uninstall routing cleanup removes only the owned blackhole"
    rm -f "$log"
}
test_uninstall_cleanup_preserves_foreign_routes

# ---------------------------------------------------------------------------
# TEST GROUP 12: Verification of an intentionally stopped Lightning daemon
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 12: Verification Of Intentionally Stopped Daemon ---"

# Docker mock for an Umbrel node whose LND container is stopped (not by the installer).
# Network attachment state is persisted in $STATE so connect -> inspect is consistent.
STOPPED_DAEMON_DOCKER_MOCK='
docker() {
    case "$1" in
        network)
            [[ "$2" == "ls" ]] && { echo "docker-tunnelsats"; return 0; }
            if [[ "$2" == "connect" ]]; then echo "attached 10.9.9.9 " > "$STATE"; echo "DOCKER:$*" >> "$LOG"; fi
            return 0 ;;
        ps) [[ "$2" == "-a" ]] && echo "cid_stopped lightning_lnd_1"; return 0 ;;
        inspect)
            if [[ "$3" == *State.Running* ]]; then echo "false"; return 0; fi
            if [[ "$3" == *IPAMConfig* ]]; then cat "$STATE" 2>/dev/null; return 0; fi
            return 0 ;;
        start|stop) echo "DOCKER:$*" >> "$LOG"; return 0 ;;
    esac
    return 0
}'

test_install_verifies_intentionally_stopped_daemon() {
    local tmp log status
    tmp=$(mktemp -d); log=$(mktemp)
    set +e
    TMPD="$tmp" STATE="$tmp/attach" MOCK="$STOPPED_DAEMON_DOCKER_MOCK" run_case "$log" <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
PLATFORM="umbrel"; LN_IMPL="lnd"; WG_INTERFACE="tunnelsatsv2"
WG_DIR="$TMPD"; SYSTEMD_DIR="$TMPD"
eval "$MOCK"
ip() { return 0; }
wg() { return 0; }
systemctl() { return 0; }
bash() { return 0; }
stop_lightning_daemon_for_safe_restart
setup_docker_network
verify_installation
EOF
    status=$?
    set -e
    assert_status 0 "$status" "Install verification accepts an intentionally stopped daemon attached with static 10.9.9.9"
    assert_log_contains "$log" "DOCKER:network connect --ip 10.9.9.9 docker-tunnelsats cid_stopped" "Stopped daemon is attached to docker-tunnelsats"
    assert_log_not_contains "$log" "DOCKER:start" "Installer never starts a daemon that was stopped before installation"
    rm -rf "$tmp" "$log"
}
test_install_verifies_intentionally_stopped_daemon

test_verify_rejects_stopped_target_without_attachment() {
    local tmp status
    tmp=$(mktemp -d)
    set +e
    STATE="$tmp/attach" MOCK="$STOPPED_DAEMON_DOCKER_MOCK" run_case /dev/null <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
PLATFORM="umbrel"; LN_IMPL="lnd"; WG_INTERFACE="tunnelsatsv2"
tunnel_target_container="cid_stopped"
eval "$MOCK"
wg() { return 0; }
systemctl() { return 0; }
verify_installation
EOF
    status=$?
    set -e
    assert_status 1 "$status" "Verification fails when the stopped target is not attached with 10.9.9.9"
    rm -rf "$tmp"
}
test_verify_rejects_stopped_target_without_attachment

test_verify_rejects_restarted_container_not_running() {
    local status
    set +e
    run_case /dev/null <<'EOF' &>/dev/null
source "$SCRIPT_UNDER_TEST"
PLATFORM="umbrel"; LN_IMPL="lnd"; WG_INTERFACE="tunnelsatsv2"
stopped_docker_containers="cid_restarted"; tunnel_target_container="cid_restarted"
docker() {
    case "$1" in
        ps) return 0 ;;
        inspect) echo "attached 10.9.9.9 "; return 0 ;;
    esac
    return 0
}
wg() { return 0; }
systemctl() { return 0; }
verify_installation
EOF
    status=$?
    set -e
    assert_status 1 "$status" "Verification still requires containers the installer restarted to be running"
}
test_verify_rejects_restarted_container_not_running

echo ""
echo "--------------------------------"
echo "Passed: $pass_count"
echo "Failed: $fail_count"
echo "--------------------------------"

if [[ "$fail_count" -gt 0 ]]; then
    exit 1
fi
