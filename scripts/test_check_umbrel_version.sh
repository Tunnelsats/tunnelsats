#!/bin/bash
# Tests for check_umbrel_version in tunnelsats.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/tunnelsats.sh"

pass_count=0
fail_count=0

run_check() {
    local version_file="$1"
    local output
    local status

    set +e
    output=$(
        UMBREL_VERSION_FILE="$version_file" \
        bash -c "source \"$SCRIPT_UNDER_TEST\"; check_umbrel_version" 2>&1
    )
    status=$?
    set -e

    echo "$output"
    return "$status"
}

assert_status() {
    local expected="$1"
    local version_file="$2"
    local desc="$3"
    local output
    local status

    set +e
    output="$(run_check "$version_file")"
    status=$?
    set -e

    if [[ "$status" -eq "$expected" ]]; then
        echo "PASS: $desc (exit=$status)"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc (expected exit=$expected, got exit=$status)"
        if [[ -n "$output" ]]; then
            echo "Output:"
            echo "$output"
        fi
        fail_count=$((fail_count + 1))
    fi
}

assert_output_contains() {
    local version_file="$1"
    local pattern="$2"
    local desc="$3"
    local output

    output="$(run_check "$version_file" || true)"
    if echo "$output" | grep -Fq "$pattern"; then
        echo "PASS: $desc"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc (missing pattern: $pattern)"
        if [[ -n "$output" ]]; then
            echo "Output:"
            echo "$output"
        fi
        fail_count=$((fail_count + 1))
    fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

echo '{"version":"1.5.9"}' > "$tmp_dir/allow.json"
echo '{"version":"1.6.0"}' > "$tmp_dir/block_1_6_0.json"
echo '{"version":"v1.6.0"}' > "$tmp_dir/block_v1_6_0.json"
echo '{"version":"1.08.0"}' > "$tmp_dir/block_1_08_0.json"
echo 'not-json' > "$tmp_dir/malformed.json"

assert_status 0 "$tmp_dir/missing.json" "missing version file should be ignored (fail-open)"
assert_status 0 "$tmp_dir/allow.json" "Umbrel 1.5.x should be allowed"
assert_status 1 "$tmp_dir/block_1_6_0.json" "Umbrel 1.6.0 should be blocked"
assert_status 1 "$tmp_dir/block_v1_6_0.json" "Umbrel v1.6.0 should be blocked"
assert_status 1 "$tmp_dir/block_1_08_0.json" "Umbrel 1.08.0 should be blocked (base-10 compare)"
assert_status 0 "$tmp_dir/malformed.json" "malformed JSON should not abort install (fail-open)"
assert_output_contains "$tmp_dir/malformed.json" "Warning: could not determine Umbrel OS version" "malformed JSON should emit warning"

echo ""
echo "Passed: $pass_count"
echo "Failed: $fail_count"

if [[ "$fail_count" -gt 0 ]]; then
    exit 1
fi
