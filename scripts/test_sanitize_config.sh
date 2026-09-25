#!/bin/bash
# Test script for WireGuard config sanitization logic in tunnelsats.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source production script to test the real production functions directly
source "$SCRIPT_DIR/tunnelsats.sh"


# Test Runner
test_num=0
run_test() {
    local desc="$1"
    local input_content="$2"
    local expect_success="$3"
    local verify_fn="$4"

    test_num=$((test_num + 1))
    local in_file=$(mktemp)
    local out_file=$(mktemp)
    echo -e "$input_content" > "$in_file"

    if sanitize_wireguard_config "$in_file" "$out_file"; then
        if [[ "$expect_success" != "true" ]]; then
            echo "FAIL (Test $test_num): $desc - expected failure but succeeded"
            rm -f "$in_file" "$out_file"
            exit 1
        fi
        if ! $verify_fn "$out_file"; then
            echo "FAIL (Test $test_num): $desc - verification failed"
            echo "Output was:"
            cat "$out_file"
            rm -f "$in_file" "$out_file"
            exit 1
        fi
        echo "PASS (Test $test_num): $desc"
    else
        if [[ "$expect_success" == "true" ]]; then
            echo "FAIL (Test $test_num): $desc - expected success but failed"
            rm -f "$in_file" "$out_file"
            exit 1
        fi
        echo "PASS (Test $test_num): $desc (failed as expected)"
    fi
    rm -f "$in_file" "$out_file"
}

echo "=== Running WireGuard Config Sanitization Tests ==="

# Test 1: Clean raw config remains pristine
raw_config="[Interface]
#myPubKey = QNi/CoSxqGiobUGLYfrqdO68ikYIKQTQumaDEAlLEQs=
#VPNPort = 48049
#ValidUntil (UTC time) = 2024-07-21T10:00:00Z
PrivateKey = aaaaaa=
Address = 10.9.0.109/32
DNS = 1.1.1.1

[Peer]
PublicKey = bbbbbb=
PresharedKey = cccccc=
Endpoint = us3.tunnelsats.com:48049
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25"

verify_raw() {
    local f="$1"
    grep -q "PrivateKey = aaaaaa=" "$f" && \
    grep -q "Endpoint = us3.tunnelsats.com:48049" "$f" && \
    grep -q "PersistentKeepalive = 25" "$f" && \
    ! grep -q "PostUp" "$f"
}
run_test "Pristine raw config untouched" "$raw_config" "true" verify_raw

# Test 2: Config with single #Tunnelsats-Setupv2-Non-Docker block
single_polluted="${raw_config}

#Tunnelsats-Setupv2-Non-Docker

[Interface]
FwMark = 0x2000000
Table = off

PostUp = while [ \$(ip rule | grep -c suppress_prefixlength) -gt 0 ]; do ip rule del from all table main suppress_prefixlength 0;done
PostUp = ip route add default dev %i table 51820;
PostDown = ip route flush table 51820"

verify_single() {
    local f="$1"
    grep -q "PersistentKeepalive = 25" "$f" && \
    ! grep -q "Tunnelsats-Setup" "$f" && \
    ! grep -q "FwMark" "$f" && \
    ! grep -q "PostUp" "$f"
}
run_test "Single Tunnelsats-Setup block stripped" "$single_polluted" "true" verify_single

# Test 3: Config with DUPLICATE #Tunnelsats-Setup blocks (Ray Buni's failure case)
double_polluted="${single_polluted}

#Tunnelsats-Setupv2-Non-Docker

[Interface]
FwMark = 0x2000000
Table = off

PostUp = while [ \$(ip rule | grep -c suppress_prefixlength) -gt 0 ]; do ip rule del from all table main suppress_prefixlength 0;done
PostUp = ip route add default dev %i table 51820;
PostDown = ip route flush table 51820"

verify_double() {
    local f="$1"
    local count
    count=$(grep -c "\[Interface\]" "$f")
    [[ "$count" -eq 1 ]] && \
    grep -q "PersistentKeepalive = 25" "$f" && \
    ! grep -q "Tunnelsats-Setup" "$f" && \
    ! grep -q "PostUp" "$f"
}
run_test "Duplicate Tunnelsats-Setup blocks stripped down to single [Interface]" "$double_polluted" "true" verify_double

# Test 4: Config without marker comments but with stray PostUp / secondary [Interface]
unmarked_polluted="${raw_config}

[Interface]
FwMark = 0x2000000
Table = off
PostUp = ip route add default dev %i table 51820;
PostDown = ip route flush table 51820"

verify_unmarked() {
    local f="$1"
    local count
    count=$(grep -c "\[Interface\]" "$f")
    [[ "$count" -eq 1 ]] && \
    ! grep -q "FwMark" "$f" && \
    ! grep -q "PostUp" "$f"
}
run_test "Unmarked secondary [Interface] and PostUp rules stripped" "$unmarked_polluted" "true" verify_unmarked

# Test 5: Missing PrivateKey fails safety check
corrupt_no_key="[Interface]
Address = 10.9.0.109/32

[Peer]
Endpoint = us3.tunnelsats.com:48049"

run_test "Corrupt config without PrivateKey fails guardrail" "$corrupt_no_key" "false" ":"

# Test 6: In-place sanitization (input_file == output_file)
test_in_place() {
    test_num=$((test_num + 1))
    local f=$(mktemp)
    echo -e "$double_polluted" > "$f"
    if sanitize_wireguard_config "$f" "$f"; then
        if verify_double "$f"; then
            echo "PASS (Test $test_num): In-place sanitization (input == output)"
        else
            echo "FAIL (Test $test_num): In-place sanitization failed verification"
            rm -f "$f"
            exit 1
        fi
    else
        echo "FAIL (Test $test_num): In-place sanitization returned error"
        rm -f "$f"
        exit 1
    fi
    rm -f "$f"
}
test_in_place

# Test 7: Missing PersistentKeepalive gets automatically added
missing_keepalive="[Interface]
PrivateKey = aaaaaa=
Address = 10.9.0.109/32

[Peer]
PublicKey = bbbbbb=
Endpoint = us3.tunnelsats.com:48049
AllowedIPs = 0.0.0.0/0"

verify_missing_keepalive() {
    local f="$1"
    grep -q "PersistentKeepalive = 25" "$f" && \
    grep -q "Endpoint = us3.tunnelsats.com:48049" "$f"
}
run_test "Missing PersistentKeepalive injected as 25" "$missing_keepalive" "true" verify_missing_keepalive

# Test 8: Disabled PersistentKeepalive (0) updated to 25
zero_keepalive="[Interface]
PrivateKey = aaaaaa=
Address = 10.9.0.109/32

[Peer]
PublicKey = bbbbbb=
Endpoint = us3.tunnelsats.com:48049
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 0"

verify_zero_keepalive() {
    local f="$1"
    grep -q "PersistentKeepalive = 25" "$f" && \
    ! grep -q "PersistentKeepalive = 0" "$f"
}
run_test "Disabled PersistentKeepalive (0) updated to 25" "$zero_keepalive" "true" verify_zero_keepalive

# Test 9: Existing custom PersistentKeepalive (e.g. 15) preserved
custom_keepalive="[Interface]
PrivateKey = aaaaaa=
Address = 10.9.0.109/32

[Peer]
PublicKey = bbbbbb=
Endpoint = us3.tunnelsats.com:48049
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15"

verify_custom_keepalive() {
    local f="$1"
    grep -q "PersistentKeepalive = 15" "$f"
}
run_test "Custom PersistentKeepalive (15) preserved" "$custom_keepalive" "true" verify_custom_keepalive

# Test 10: Tabs and irregular whitespace before '=' in hooks stripped
tab_polluted="[Interface]
PrivateKey = aaaaaa=
Address = 10.9.0.109/32
PostUp	= echo tab_postup
PostDown 	= echo space_tab_postdown
FwMark	 = 0x123
Table	=	off

[Peer]
PublicKey = bbbbbb=
Endpoint = us3.tunnelsats.com:48049
AllowedIPs = 0.0.0.0/0"

verify_tab_polluted() {
    local f="$1"
    ! grep -q "echo tab_postup" "$f" && \
    ! grep -q "echo space_tab_postdown" "$f" && \
    ! grep -q "0x123" "$f" && \
    ! grep -q "Table" "$f" && \
    grep -q "PrivateKey = aaaaaa=" "$f"
}
run_test "Irregular tabs and whitespace in hooks stripped" "$tab_polluted" "true" verify_tab_polluted

# Test 11: Backup file created with unique name when destination exists
test_backup_created() {
    test_num=$((test_num + 1))
    local in_f=$(mktemp)
    local out_f=$(mktemp)
    echo -e "$raw_config" > "$in_f"
    echo "ORIGINAL_DESTINATION_CONTENT" > "$out_f"

    if sanitize_wireguard_config "$in_f" "$out_f"; then
        # Check that a backup file exists containing the original content
        local bak_files
        bak_files=( "${out_f}".bak.* )
        if [[ ${#bak_files[@]} -gt 0 && -f "${bak_files[0]}" ]]; then
            if grep -q "ORIGINAL_DESTINATION_CONTENT" "${bak_files[0]}"; then
                echo "PASS (Test $test_num): Unique backup file created and preserved original content"
                rm -f "${bak_files[@]}" "$in_f" "$out_f"
                return 0
            fi
        fi
        echo "FAIL (Test $test_num): Backup file was not created or did not preserve content"
        rm -f "${bak_files[@]}" "$in_f" "$out_f"
        exit 1
    else
        echo "FAIL (Test $test_num): sanitize_wireguard_config failed unexpectedly"
        rm -f "$in_f" "$out_f"
        exit 1
    fi
}
test_backup_created

echo "All $test_num tests passed successfully!"

