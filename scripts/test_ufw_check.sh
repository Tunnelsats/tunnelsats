#!/bin/bash
# Tests for UFW configuration checks in tunnelsats.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/tunnelsats.sh"

pass_count=0
fail_count=0

# Mock variables to control behavior of mocked command/ufw
MOCK_UFW_INSTALLED=0
MOCK_UFW_STATUS_OUT=""
MOCK_UFW_ALLOW_FAIL=0

# Override 'command' builtin to control 'command -v ufw' results
command() {
    local cmd="$1"
    if [[ "$cmd" == "-v" ]]; then
        local target="$2"
        if [[ "$target" == "ufw" ]]; then
            if [[ "$MOCK_UFW_INSTALLED" -eq 1 ]]; then
                echo "/usr/sbin/ufw"
                return 0
            else
                return 1
            fi
        fi
    fi
    builtin command "$@"
}

# Mock 'ufw' function
ufw() {
    local cmd="${1:-}"
    if [[ "$cmd" == "allow" ]]; then
        return "$MOCK_UFW_ALLOW_FAIL"
    fi
    echo -e "$MOCK_UFW_STATUS_OUT"
}

# Source the script under test
source "$SCRIPT_UNDER_TEST"

run_test_case() {
    local installed="$1"
    local status_out="$2"
    local allow_fail="$3"
    local interface="$4"
    local expected_status="$5"
    local desc="$6"

    MOCK_UFW_INSTALLED="$installed"
    MOCK_UFW_STATUS_OUT="$status_out"
    MOCK_UFW_ALLOW_FAIL="$allow_fail"

    set +e
    local output
    output=$(check_ufw_configuration "$interface" 2>&1)
    local status=$?
    set -e

    if [[ "$status" -eq "$expected_status" ]]; then
        echo "PASS: $desc (exit=$status)"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc (expected exit=$expected_status, got exit=$status)"
        echo "Output was:"
        echo "$output"
        fail_count=$((fail_count + 1))
    fi
}

run_is_port_allowed_case() {
    local status_out="$1"
    local interface="$2"
    local expected_status="$3"
    local desc="$4"

    set +e
    is_port_allowed_in_ufw "$interface" "9735" "$status_out"
    local status=$?
    set -e

    if [[ "$status" -eq "$expected_status" ]]; then
        echo "PASS: $desc (exit=$status)"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc (expected exit=$expected_status, got exit=$status)"
        fail_count=$((fail_count + 1))
    fi
}

echo "Running UFW check logic tests..."
echo "--------------------------------"

# Case 1: UFW not installed
run_test_case 0 "" 0 "tunnelsatsv2" 0 "UFW not installed (should return 0)"

# Case 2: UFW installed but inactive
status_inactive="Status: inactive"
run_test_case 1 "$status_inactive" 0 "tunnelsatsv2" 0 "UFW installed but inactive (should return 0)"

# Case 3: UFW active, but 9735 blocked (no rules), allow succeeds
status_active_blocked="Status: active

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere"
run_test_case 1 "$status_active_blocked" 0 "tunnelsatsv2" 0 "UFW active, 9735 blocked, auto-allow succeeds (should return 0)"

# Case 3b: UFW active, 9735 blocked, allow fails
run_test_case 1 "$status_active_blocked" 1 "tunnelsatsv2" 0 "UFW active, 9735 blocked, auto-allow fails (should return 0)"

# Case 4: UFW active, global rule for 9735/tcp (no rule needs to be added)
status_active_global="Status: active

To                         Action      From
--                         ------      ----
9735/tcp                   ALLOW       Anywhere"
run_test_case 1 "$status_active_global" 0 "tunnelsatsv2" 0 "UFW active, global 9735/tcp allowed (should return 0)"

# Case 5: UFW active, global rule for 9735
status_active_global_no_proto="Status: active

To                         Action      From
--                         ------      ----
9735                       ALLOW       Anywhere"
run_test_case 1 "$status_active_global_no_proto" 0 "tunnelsatsv2" 0 "UFW active, global 9735 allowed (should return 0)"

# Case 6: UFW active, rule specifically on tunnelsatsv2
status_active_interface="Status: active

To                         Action      From
--                         ------      ----
9735/tcp on tunnelsatsv2   ALLOW       Anywhere"
run_test_case 1 "$status_active_interface" 0 "tunnelsatsv2" 0 "UFW active, interface rule for tunnelsatsv2 allowed (should return 0)"

# Case 7: UFW active, rule specifically on another interface (e.g. eth0), auto-allow succeeds
status_active_other_interface="Status: active

To                         Action      From
--                         ------      ----
9735/tcp on eth0           ALLOW       Anywhere"
run_test_case 1 "$status_active_other_interface" 0 "tunnelsatsv2" 0 "UFW active, rule for eth0, auto-allow on tunnelsatsv2 succeeds (should return 0)"

# Case 7b: UFW active, rule specifically on another interface, auto-allow fails
run_test_case 1 "$status_active_other_interface" 1 "tunnelsatsv2" 0 "UFW active, rule for eth0, auto-allow on tunnelsatsv2 fails (should return 0)"

# Case 8: Interface names are matched literally, not as regex patterns
status_active_plus_interface="Status: active

To                         Action      From
--                         ------      ----
9735/tcp on tunnelsats+eu  ALLOW       Anywhere"
run_is_port_allowed_case "$status_active_plus_interface" "tunnelsats+eu" 0 "UFW active, interface containing + matched literally"

status_active_dot_interface="Status: active

To                         Action      From
--                         ------      ----
9735/tcp on tunnelsats.eu  ALLOW       Anywhere"
run_is_port_allowed_case "$status_active_dot_interface" "tunnelsats.eu" 0 "UFW active, interface containing . matched literally"

status_active_dot_false_match="Status: active

To                         Action      From
--                         ------      ----
9735/tcp on tunnelsatsXeu  ALLOW       Anywhere"
run_is_port_allowed_case "$status_active_dot_false_match" "tunnelsats.eu" 1 "UFW active, interface . does not match another character"

echo "--------------------------------"
echo "Passed: $pass_count"
echo "Failed: $fail_count"

if [[ "$fail_count" -gt 0 ]]; then
    exit 1
fi
