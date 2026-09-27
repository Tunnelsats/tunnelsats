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
resolve_wg_target_path() { echo "$DIR_T/tunnelsatsv2.conf"; }
docker() { return 1; }
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
args="$*"
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
    for tool in nft iptables sysctl ping; do
        printf '#!/bin/bash\necho "%s:$*" >> "$HOOK_LOG"\nexit 0\n' "${tool^^}" > "$bin/$tool"
    done
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
    export HOOK_LOG="$dir/hooks.log" ROUTES="$dir/table51820"

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

    unset HOOK_LOG ROUTES
    rm -rf "$dir" "$bin"
}
test_runtime_hooks_scope umbrel "Docker"
test_runtime_hooks_scope baremetal "Non-Docker"

test_refused_postup_reports_unarmed_failclosed() {
    local dir bin status err
    dir=$(mktemp -d); bin=$(mktemp -d)
    generate_tunnel_config umbrel "$dir"
    make_fake_net_bin "$bin"
    # nft rejects the drop rules
    printf '#!/bin/bash\necho "NFT:$*" >> "$HOOK_LOG"\n[[ "$*" == *"add rule"* ]] && exit 1\nexit 0\n' > "$bin/nft"
    chmod +x "$bin/nft"
    export HOOK_LOG="$dir/hooks.log" ROUTES="$dir/table51820"
    printf 'default dev wg1 scope link \n' > "$ROUTES"
    set +e; err=$(run_wg_hooks PostUp "$dir/tunnelsatsv2.conf" "$bin" 2>&1 >/dev/null); status=$?; set -e
    if [[ "$status" -ne 0 ]]; then
        echo "PASS: Refused PostUp still fails when the emergency drop cannot be armed (exit=$status)"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: PostUp succeeded despite foreign routes and failed emergency drop"
        fail_count=$((fail_count + 1))
    fi
    if [[ "$err" == *"could NOT be armed"* ]] && [[ "$err" != *"(Lightning traffic blocked)"* ]]; then
        echo "PASS: Guard reports that the emergency drop is NOT armed instead of claiming traffic is blocked"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: Guard did not report the failed emergency drop (stderr: $err)"
        fail_count=$((fail_count + 1))
    fi
    assert_log_not_contains "$HOOK_LOG" "IP:rule add" "No policy rule is added when the refused start cannot arm the drop"
    unset HOOK_LOG ROUTES
    rm -rf "$dir" "$bin"
}
test_refused_postup_reports_unarmed_failclosed

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
