#!/bin/bash
# Test script for IPv6 AllowedIPs stripping logic in tunnelsats.sh
# This script verifies that ::/0 is correctly removed from various AllowedIPs formats.

test_strip() {
    local input="$1"
    local expected_grep="$2"
    local desc="$3"
    local temp_file=$(mktemp)
    
    echo "AllowedIPs = $input" > "$temp_file"
    
    # Logic from tunnelsats.sh
    sed -i 's/,\s*::\/0//g' "$temp_file"
    sed -i 's/::\/0,\s*//g' "$temp_file"
    sed -i 's/^AllowedIPs\s*=\s*::\/0/#AllowedIPs = ::\/0 (removed: ipv6 disabled)/g' "$temp_file"
    
    local result=$(cat "$temp_file")
    rm "$temp_file"
    
    if echo "$result" | grep -q "$expected_grep"; then
        echo "PASS: $desc"
        echo "      Input:  '$input'"
        echo "      Result: '$result'"
    else
        echo "FAIL: $desc"
        echo "      Input:  '$input'"
        echo "      Result: '$result'"
        echo "      Expected to match: '$expected_grep'"
        exit 1
    fi
}

echo "Testing AllowedIPs stripping logic..."

test_strip "0.0.0.0/0, ::/0" "AllowedIPs = 0.0.0.0/0" "Trailing ::/0"
test_strip "::/0, 0.0.0.0/0" "AllowedIPs = 0.0.0.0/0" "Leading ::/0"
test_strip "::/0" "#AllowedIPs = ::/0 (removed: ipv6 disabled)" "Standalone ::/0 (commented out)"
test_strip "10.0.0.0/8, ::/0, 192.168.1.0/24" "AllowedIPs = 10.0.0.0/8, 192.168.1.0/24" "Middle ::/0"
test_strip "0.0.0.0/0" "AllowedIPs = 0.0.0.0/0" "IPv4 only (no change)"

echo "All tests passed!"
