#!/bin/bash
# Test script for IPv6 handling in configure_wireguard (scripts/tunnelsats.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/tunnelsats.sh"

pass_count=0
fail_count=0

pass() {
    echo "PASS: $1"
    pass_count=$((pass_count + 1))
}

fail() {
    echo "FAIL: $1"
    fail_count=$((fail_count + 1))
}

run_configure_wireguard() {
    local allowed_ips="$1"
    local ipv6_sysctl="$2"
    local platform="${3:-baremetal}"
    local tmp_dir="$4"

    cat > "$tmp_dir/input.conf" <<EOF
[Interface]
PrivateKey = aaaaaa=
Address = 10.9.0.10/32
DNS = 8.8.8.8

[Peer]
PublicKey = bbbbbb=
Endpoint = vpn.tunnelsats.com:51820
AllowedIPs = ${allowed_ips}
PersistentKeepalive = 25
EOF

    SCRIPT_UNDER_TEST="$SCRIPT_UNDER_TEST" TMP_DIR="$tmp_dir" IPV6_SYSCTL="$ipv6_sysctl" PLATFORM_T="$platform" bash -c '
        set -e
        source "$SCRIPT_UNDER_TEST"
        PLATFORM="$PLATFORM_T"
        WG_INTERFACE="tunnelsatsv2"
        WG_DIR="$TMP_DIR"
        TS_FS_ROOT="$TMP_DIR"
        CONFIG_FILE="$TMP_DIR/input.conf"
        node_user="bitcoin"
        mkdir -p "$TMP_DIR/etc/wireguard" "$TMP_DIR/proc/net"
        if [[ "$IPV6_SYSCTL" == "0" ]]; then
            : > "$TMP_DIR/proc/net/if_inet6"
        fi
        resolve_wg_target_path() { echo "$TMP_DIR/tunnelsatsv2.conf"; }
        id() { echo 1001; }
        ip() {
            if [[ "$1" == "route" ]]; then
                echo "192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.10"
            fi
            return 0
        }
        docker() {
            if [[ "$1 $2" == "network inspect" ]]; then
                echo "10.9.9.0/25 6c3d330ad9f50000"
                return 0
            fi
            return 1
        }
        sysctl() {
            if [[ "$*" == "-n net.ipv6.conf.all.disable_ipv6" ]]; then
                echo "$IPV6_SYSCTL"
                return 0
            fi
            echo 0
        }
        configure_wireguard >/dev/null
    '
}

test_strip() {
    local input="$1"
    local expected_grep="$2"
    local desc="$3"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    run_configure_wireguard "$input" "1" "baremetal" "$tmp_dir"
    local result
    result=$(grep -E '^#?AllowedIPs' "$tmp_dir/tunnelsatsv2.conf" | head -n 1 || true)
    rm -rf "$tmp_dir"

    if echo "$result" | grep -q "$expected_grep"; then
        pass "$desc ($input -> $result)"
    else
        fail "$desc (Input: '$input', Result: '$result', Expected: '$expected_grep')"
    fi
}

echo "Testing AllowedIPs stripping via configure_wireguard when host IPv6 is disabled..."
test_strip "0.0.0.0/0, ::/0" "^AllowedIPs = 0.0.0.0/0$" "Trailing ::/0"
test_strip "::/0, 0.0.0.0/0" "^AllowedIPs = 0.0.0.0/0$" "Leading ::/0"
test_strip "::/0" "^#AllowedIPs = ::/0 (removed: ipv6 disabled)$" "Standalone ::/0 (commented out)"
test_strip "10.0.0.0/8, ::/0, 192.168.1.0/24" "^AllowedIPs = 10.0.0.0/8, 192.168.1.0/24$" "Middle ::/0"
test_strip "0.0.0.0/0" "^AllowedIPs = 0.0.0.0/0$" "IPv4 only (no change)"

echo "Testing scoped IPv6 blocking when host IPv6 is enabled..."
for platform in baremetal umbrel; do
    tmp_dir=$(mktemp -d)
    run_configure_wireguard "0.0.0.0/0, ::/0" "0" "$platform" "$tmp_dir"
    conf="$tmp_dir/tunnelsatsv2.conf"

    if grep -qE "^PreUp = .*/tunnelsats-route-guard\.sh arm " "$conf"; then
        pass "[$platform] configure_wireguard arms fail-closed block in PreUp"
    else
        fail "[$platform] configure_wireguard is missing PreUp fail-closed arm hook"
    fi

    if [[ "$platform" == "baremetal" ]]; then
        if grep -q "disable_ipv6=1" "$conf"; then
            fail "[$platform] configure_wireguard must not disable IPv6 host-wide via sysctl"
        else
            pass "[$platform] configure_wireguard does not emit host-wide disable_ipv6=1 sysctl"
        fi
        if [[ -e "$tmp_dir/.tunnelsats-ipv6-disabled" ]] || [[ -e "$tmp_dir/etc/wireguard/.tunnelsats-ipv6-disabled" ]]; then
            fail "[$platform] configure_wireguard must not create .tunnelsats-ipv6-disabled"
        else
            pass "[$platform] configure_wireguard does not create .tunnelsats-ipv6-disabled"
        fi
        if grep -q "nft add table inet %i" "$conf" && grep -q "meta cgroup 1118498 ip6 daddr !=" "$conf" && grep -q "meta skuid 1001 ip6 daddr !=" "$conf"; then
            pass "[$platform] configure_wireguard emits scoped inet IPv6 output drop rules (cgroup and skuid)"
        else
            fail "[$platform] configure_wireguard is missing scoped inet IPv6 output drop rules"
        fi
        if grep -q "PostDown = nft delete table inet %i" "$conf"; then
            pass "[$platform] configure_wireguard cleans up inet table in PostDown"
        else
            fail "[$platform] configure_wireguard is missing inet table cleanup in PostDown"
        fi
    else
        if grep -qE "^PreUp = sysctl -w net\.ipv6\.conf\.all\.disable_ipv6=1" "$conf"; then
            pass "[$platform] configure_wireguard disables IPv6 in PreUp for Docker container networks"
        else
            fail "[$platform] configure_wireguard is missing PreUp disable_ipv6=1 for Docker"
        fi
        if [[ -e "$tmp_dir/.tunnelsats-ipv6-disabled" ]]; then
            pass "[$platform] configure_wireguard records .tunnelsats-ipv6-disabled when IPv6 was enabled"
        else
            fail "[$platform] configure_wireguard did not record .tunnelsats-ipv6-disabled on Docker"
        fi
        if grep -q "ip6tables -I FORWARD -i br-" "$conf" && grep -q " -j DROP" "$conf"; then
            pass "[$platform] configure_wireguard blocks forwarded IPv6 on Docker bridge"
        else
            fail "[$platform] configure_wireguard is missing Docker bridge ip6tables FORWARD DROP"
        fi
        if grep -q "ip6tables -D FORWARD -i br-" "$conf"; then
            pass "[$platform] configure_wireguard cleans up Docker bridge ip6tables rule in PostDown"
        else
            fail "[$platform] configure_wireguard is missing Docker bridge ip6tables cleanup in PostDown"
        fi
    fi
    rm -rf "$tmp_dir"
done

echo "--------------------------------"
echo "Passed: $pass_count"
echo "Failed: $fail_count"
echo "--------------------------------"
[[ "$fail_count" -eq 0 ]]
