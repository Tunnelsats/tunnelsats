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

echo ""
echo "--------------------------------"
echo "Passed: $pass_count"
echo "Failed: $fail_count"
echo "--------------------------------"

if [[ "$fail_count" -gt 0 ]]; then
    exit 1
fi
