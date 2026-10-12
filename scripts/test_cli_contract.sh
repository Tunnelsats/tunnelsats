#!/bin/bash
# Tests for the CLI contract of tunnelsats.sh: global option parsing, non-interactive prompts,
# --json documents (version, detect, error envelopes), detect on fixture trees, the config
# metadata parsers and the JSON string escaper.
# Runs unprivileged and offline and never modifies the host: every command with side effects is
# a stub, and detect reads fixture trees through TS_FS_ROOT and stub binaries.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/tunnelsats.sh"

pass_count=0
fail_count=0
skip_count=0

if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL: python3 is required to validate the JSON output"
    exit 1
fi

TMP_ROOT="$(mktemp -d)"
cleanup() {
    chmod -R u+rwX "$TMP_ROOT" 2>/dev/null || true
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# Synthetic WireGuard keys: base64 of readable 32-byte strings, never used for a real tunnel
PRIV_KEY="dHVubmVsc2F0cy10ZXN0LXByaXZhdGUta2V5LTAwMDE="
STUB_PUB_KEY="dHVubmVsc2F0cy10ZXN0LXB1YmxpYy1rZXktMDAwMDE="
# What a real "wg pubkey" derives from PRIV_KEY (checked only where wireguard-tools is installed)
REAL_PUB_KEY="g4b1YwYif2cSACcXjlAdTXqXpsSoI+QvAYXkaJ/+21w="
COMMENT_KEY_A="dHVubmVsc2F0cy10ZXN0LWNvbW1lbnQta2V5LTAwMDE="
COMMENT_KEY_B="dHVubmVsc2F0cy10ZXN0LWNvbW1lbnQta2V5LTAwMDI="
SERVER_KEY="dHVubmVsc2F0cy10ZXN0LXNlcnZlci1rZXktMDAwMDE="
PSK_KEY="dHVubmVsc2F0cy10ZXN0LXByZXNoYXJlZC1rZXktMDE="

pass() {
    echo "PASS: $1"
    pass_count=$((pass_count + 1))
}

fail() {
    echo "FAIL: $1"
    fail_count=$((fail_count + 1))
}

skip() {
    echo "SKIP: $1"
    skip_count=$((skip_count + 1))
}

assert_equals() {
    local expected="$1" actual="$2" desc="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$desc"
    else
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc (missing '$needle')"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc (unexpected '$needle')"
    fi
}

# Runs a command with stdin from /dev/null. Sets CLI_RC, CLI_OUT (stdout) and CLI_ERR (stderr).
run_cli() {
    set +e
    "$@" >"$TMP_ROOT/cli.out" 2>"$TMP_ROOT/cli.err" </dev/null
    CLI_RC=$?
    set -e
    CLI_OUT="$(cat "$TMP_ROOT/cli.out")"
    CLI_ERR="$(cat "$TMP_ROOT/cli.err")"
}

# Evaluates a Python expression over the single JSON document in $1 (bound to d). Strings are
# printed as they are, everything else as JSON. Fails unless $1 is exactly one JSON document.
json_eval() {
    printf '%s' "$1" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
v = eval(sys.argv[1])
print(v if isinstance(v, str) else json.dumps(v))
' "$2"
}

assert_json() {
    local doc="$1" expr="$2" expected="$3" desc="$4" actual
    actual=$(json_eval "$doc" "$expr" 2>&1) || actual="<not one valid JSON document>"
    assert_equals "$expected" "$actual" "$desc"
}

assert_json_valid() {
    if printf '%s' "$1" | python3 -m json.tool >/dev/null 2>&1; then
        pass "$2"
    else
        fail "$2 (python3 -m json.tool rejected: $1)"
    fi
}

echo "=== Running CLI Contract Tests ==="

# ---------------------------------------------------------------------------
# GROUP 1: Option parsing
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 1: Option Parsing ---"

# Parsed state of a command line (ts_parse_cli in a child shell; nothing is executed)
parse_state() {
    bash -c 'source "$1"; shift; ts_parse_cli "$@"; echo "cmd=${TS_COMMAND} json=${TS_JSON} ni=${TS_NONINTERACTIVE} yes=${TS_OPT_YES} platform=${TS_OPT_PLATFORM} impl=${TS_OPT_IMPL} packages=${TS_OPT_PACKAGES} config=${CONFIG_FILE} error=${TS_USAGE_ERROR}"' _ "$SCRIPT_UNDER_TEST" "$@"
}

expected_state="cmd=install json=0 ni=1 yes=1 platform=raspiblitz impl=lnd packages= config=my.conf error="
assert_equals "$expected_state" "$(parse_state --non-interactive --yes --platform raspiblitz --impl lnd --config my.conf install)" \
    "Options before the command word are parsed"
assert_equals "$expected_state" "$(parse_state install --config my.conf --impl lnd --platform raspiblitz --yes --non-interactive)" \
    "Options after the command word are parsed"
assert_equals "$expected_state" "$(parse_state --platform raspiblitz install --impl lnd --non-interactive --config my.conf --yes)" \
    "Options on both sides of the command word are parsed"
assert_equals "cmd=uninstall json=0 ni=0 yes=0 platform= impl= packages=remove config= error=" "$(parse_state remove --remove-packages)" \
    "Alias 'remove' maps to uninstall and --remove-packages is parsed"
assert_equals "cmd=uninstall json=0 ni=0 yes=0 platform= impl= packages=keep config= error=" "$(parse_state --keep-packages uninstall)" \
    "--keep-packages is parsed"
assert_contains "$(parse_state precheck)" "cmd=pre-check " "Alias 'precheck' maps to pre-check"
assert_contains "$(parse_state check)" "cmd=pre-check " "Alias 'check' maps to pre-check"
assert_contains "$(parse_state --json detect)" "json=1 ni=1 " "--json implies --non-interactive"
assert_contains "$(parse_state install --help)" "cmd=help " "--help after a command selects help"
assert_contains "$(parse_state -h)" "cmd=help " "-h selects help"
assert_contains "$(parse_state version)" "ni=0 " "Non-interactive mode is never implied without the flag"

run_cli bash "$SCRIPT_UNDER_TEST" version --bogus
assert_equals 2 "$CLI_RC" "Unknown option exits 2"
assert_contains "$CLI_ERR" "Unknown option: --bogus [E_USAGE]" "Unknown option is reported on stderr with E_USAGE"
assert_equals "" "$CLI_OUT" "A usage error without --json prints nothing on stdout"

run_cli bash "$SCRIPT_UNDER_TEST" --json --bogus version
assert_equals 2 "$CLI_RC" "Unknown option with --json exits 2"
assert_json_valid "$CLI_OUT" "Usage error envelope is valid JSON"
assert_json "$CLI_OUT" 'd["contract"]' 1 "Error envelope has contract 1"
assert_json "$CLI_OUT" 'd["command"]' version "Error envelope names the command even if the bad option comes first"
assert_json "$CLI_OUT" 'd["tool_version"]' 3.2 "Error envelope has tool_version"
assert_json "$CLI_OUT" 'd["ok"]' false "Error envelope has ok false"
assert_json "$CLI_OUT" 'd["exit_code"]' 2 "Error envelope exit_code matches the exit code"
assert_json "$CLI_OUT" '[d["errors"][0][k] for k in ("code", "class", "message")]' \
    '["E_USAGE", "usage", "Unknown option: --bogus"]' "Error object has code, class and message"

usage_cases=(
    "install --platform foo|Invalid --platform 'foo'"
    "install --impl xyz|Invalid --impl 'xyz'"
    "install --platform|--platform requires a value"
    "install --platform --non-interactive|--platform requires a value"
    "install --config|--config requires a value"
    "install --platform raspiblitz --platform umbrel|--platform given more than once"
    "uninstall --remove-packages --keep-packages|cannot be combined"
    "version --platform raspiblitz|--platform is not supported by 'version'"
    "detect --config x.conf|--config is not supported by 'detect'"
    "status --remove-packages|--remove-packages is not supported by 'status'"
    "pre-check --impl lnd|--impl is not supported by 'pre-check'"
    "frobnicate|Unknown command: frobnicate"
    "version extra|Unexpected argument: extra"
    "--non-interactive|Missing command"
)
for usage_case in "${usage_cases[@]}"; do
    case_args="${usage_case%%|*}"
    case_needle="${usage_case#*|}"
    # shellcheck disable=SC2086
    run_cli bash "$SCRIPT_UNDER_TEST" --json $case_args
    assert_equals 2 "$CLI_RC" "[$case_args] exits 2"
    assert_json "$CLI_OUT" 'd["errors"][0]["code"]' E_USAGE "[$case_args] reports E_USAGE in one JSON document"
    assert_contains "$(json_eval "$CLI_OUT" 'd["errors"][0]["message"]' 2>&1)" "$case_needle" "[$case_args] message: $case_needle"
done

for json_cmd in install uninstall status restart pre-check help; do
    run_cli bash "$SCRIPT_UNDER_TEST" "$json_cmd" --json
    assert_equals 2 "$CLI_RC" "$json_cmd --json exits 2 before doing anything (no root check reached)"
    assert_json "$CLI_OUT" '[d["command"], d["errors"][0]["code"], d["ok"]]' "[\"${json_cmd}\", \"E_JSON_UNSUPPORTED\", false]" \
        "$json_cmd --json reports E_JSON_UNSUPPORTED"
done

run_cli bash "$SCRIPT_UNDER_TEST"
assert_equals 0 "$CLI_RC" "No arguments shows help and exits 0"
assert_contains "$CLI_OUT" "Usage: sudo bash tunnelsats.sh" "Help text is printed"
assert_contains "$CLI_OUT" "--non-interactive" "Help documents --non-interactive"
assert_contains "$CLI_OUT" "Exit codes: 0 success, 1 failure, 2 usage error or interaction required" "Help documents the exit codes"
assert_not_contains "$CLI_OUT$CLI_ERR" $'\033[' "No ANSI colours when the output is not a terminal"

if command -v script >/dev/null 2>&1 && script -qec true /dev/null >/dev/null 2>&1; then
    tty_out=$(script -qec "bash '$SCRIPT_UNDER_TEST' help" /dev/null 2>/dev/null || true)
    assert_contains "$tty_out" $'\033[' "Colours are kept on a terminal (unchanged interactive output)"
    tty_out=$(NO_COLOR=1 script -qec "bash '$SCRIPT_UNDER_TEST' help" /dev/null 2>/dev/null || true)
    assert_not_contains "$tty_out" $'\033[' "NO_COLOR disables colours on a terminal"
else
    skip "util-linux script is not available: terminal colour checks"
fi

# ---------------------------------------------------------------------------
# GROUP 2: Prompts (non-interactive refusal, answering flags, unchanged prompts)
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 2: Prompts ---"

# Prelude of every snippet: the production script is sourced and every command that could change
# the system is replaced by a stub that only appends to $LOG. The read wrapper records the text
# each interactive prompt passes to read -p (shown only on a terminal) in $PROMPTS.
STUB_PRELUDE=$(cat <<'EOF'
source "$SCRIPT_UNDER_TEST"
stub_log() { printf '%s\n' "$*" >> "$LOG"; }
systemctl() { stub_log "systemctl $*"; if [[ "${1:-}" == "is-active" ]]; then return 3; fi; return 0; }
apt-get() { stub_log "apt-get $*"; return 0; }
docker() { stub_log "docker $*"; return 0; }
nft() { stub_log "nft $*"; return 1; }
ip() { stub_log "ip $*"; return 0; }
wg() { stub_log "wg $*"; echo "interface: tunnelsatsv2"; return 0; }
ufw() { stub_log "ufw $*"; return 0; }
cgdelete() { stub_log "cgdelete $*"; return 0; }
journalctl() { stub_log "journalctl $*"; return 0; }
sudo() { stub_log "sudo $*"; return 1; }
rm() { stub_log "rm $*"; return 0; }
mv() { stub_log "mv $*"; return 0; }
cp() { stub_log "cp $*"; return 0; }
sed() { local a; for a in "$@"; do if [[ "$a" == -i* ]]; then stub_log "sed $*"; return 0; fi; done; command sed "$@"; }
sleep() { :; }
check_root() { :; }
read() { local a prev=""; for a in "$@"; do if [[ "$prev" == "-p" ]]; then printf '%s\n' "$a" >> "$PROMPTS"; fi; prev="$a"; done; builtin read "$@"; }
EOF
)

# Runs snippet $1 after the prelude in a child bash with $2 as stdin (empty: end of input).
# Sets SN_RC, SN_OUT (stdout and stderr), SN_LOG (stub calls) and SN_PROMPTS (prompt texts).
run_snippet() {
    local snippet="$1" input="${2-}"
    : > "$TMP_ROOT/stub.log"
    : > "$TMP_ROOT/prompts.log"
    printf '%s' "$input" > "$TMP_ROOT/stdin"
    set +e
    SN_OUT=$(SCRIPT_UNDER_TEST="$SCRIPT_UNDER_TEST" LOG="$TMP_ROOT/stub.log" PROMPTS="$TMP_ROOT/prompts.log" \
        UMBREL_VERSION_FILE="$TMP_ROOT/no-umbrel-package.json" \
        bash -c "${STUB_PRELUDE}"$'\n'"${snippet}" <"$TMP_ROOT/stdin" 2>&1)
    SN_RC=$?
    set -e
    SN_LOG="$(cat "$TMP_ROOT/stub.log")"
    SN_PROMPTS="$(cat "$TMP_ROOT/prompts.log")"
}

# Checks a refusal: $1 = flag named in the error, $2 = description, $3 = "eof" when the refusal
# comes from end of input (interactive mode) instead of non-interactive mode (no read at all).
assert_interaction_required() {
    local flag="$1" desc="$2" mode="${3:-noninteractive}"
    assert_equals 2 "$SN_RC" "$desc: exits 2"
    assert_contains "$SN_OUT" "[E_INTERACTION_REQUIRED]" "$desc: reports E_INTERACTION_REQUIRED"
    assert_contains "$SN_OUT" "Pass ${flag}" "$desc: names ${flag}"
    if [[ "$mode" == "eof" ]]; then
        assert_contains "$SN_OUT" "no answer received (end of input)" "$desc: explains the end of input"
    else
        assert_contains "$SN_OUT" "non-interactive mode never prompts" "$desc: refused by non-interactive mode"
        assert_equals "" "$SN_PROMPTS" "$desc: no answer was read"
    fi
}

assert_no_side_effects() {
    local line bad=""
    while IFS= read -r line; do
        if [[ -n "$line" ]] && [[ "$line" != "systemctl is-active "* ]]; then
            bad+="${line}; "
        fi
    done <<< "$SN_LOG"
    if [[ -z "$bad" ]]; then
        pass "$1: no command with side effects ran"
    else
        fail "$1: commands ran before the refusal: $bad"
    fi
}

# Prompt 1: config selection (detect_config_file), answered by --config
cfg_dir="$TMP_ROOT/configs"
mkdir -p "$cfg_dir"
printf '[Interface]\n' > "$cfg_dir/tunnelsats_a.conf"
printf '[Interface]\n' > "$cfg_dir/tunnelsats_b.conf"

run_snippet "SCRIPT_DIR='$cfg_dir'; parse_args install --non-interactive; echo REACHED_DISPATCH"
assert_interaction_required "--config <file>" "Config selection in non-interactive mode"
assert_not_contains "$SN_OUT" "REACHED_DISPATCH" "Config selection refusal stops before the root check and install"
assert_no_side_effects "Config selection in non-interactive mode"

run_snippet "SCRIPT_DIR='$cfg_dir'; selected=\$(detect_config_file ''); echo \"SELECTED=\$selected\"" $'2\n'
second_listed=$(printf '%s\n' "$SN_OUT" | sed -n 's/^  2) //p')
assert_equals "SELECTED=${cfg_dir}/${second_listed}" "$(printf '%s\n' "$SN_OUT" | grep '^SELECTED=')" "Interactive config selection returns the chosen file"
assert_equals "Select config [1-2]: " "$SN_PROMPTS" "Config selection prompt is unchanged"
assert_equals $'  1) tunnelsats_a.conf\n  2) tunnelsats_b.conf' "$(printf '%s\n' "$SN_OUT" | grep -E '^  [0-9]+\) ')" \
    "Config selection lists the candidates in sorted order (find order before)"

run_snippet "SCRIPT_DIR='$cfg_dir'; cmd_install() { echo REACHED_INSTALL; }; parse_args install" $'9\n'
assert_equals 1 "$SN_RC" "An invalid config selection now stops the install (exit 1)"
assert_not_contains "$SN_OUT" "REACHED_INSTALL" "An invalid config selection no longer continues with an empty config"

run_snippet "SCRIPT_DIR='$cfg_dir'; cmd_install() { echo REACHED_INSTALL; }; parse_args install"
assert_interaction_required "--config <file>" "Config selection at end of input" eof
assert_not_contains "$SN_OUT" "REACHED_INSTALL" "End of input at the config selection stops the install"

if [[ "$EUID" -eq 0 ]]; then
    skip "running as root: end-to-end install refusal (never run install as root in tests)"
else
    cli_dir="$TMP_ROOT/cli"
    mkdir -p "$cli_dir"
    cp "$SCRIPT_UNDER_TEST" "$cli_dir/tunnelsats.sh"
    cp "$cfg_dir"/tunnelsats_*.conf "$cli_dir/"
    run_cli bash "$cli_dir/tunnelsats.sh" install --non-interactive
    assert_equals 2 "$CLI_RC" "install --non-interactive with two configs next to the script exits 2"
    assert_contains "$CLI_ERR" "Pass --config <file>. [E_INTERACTION_REQUIRED]" "install --non-interactive names --config"
fi

# Prompts 2 and 3: platform confirmation and menu, answered by --platform
run_snippet "TS_NONINTERACTIVE=1; ts_guess_platform() { echo raspiblitz; }; detect_platform"
assert_interaction_required "--platform <id>" "Platform confirmation in non-interactive mode"
assert_no_side_effects "Platform confirmation in non-interactive mode"

run_snippet "TS_NONINTERACTIVE=1; ts_guess_platform() { :; }; detect_platform"
assert_interaction_required "--platform <id>" "Platform menu in non-interactive mode"
assert_not_contains "$SN_OUT" "What Lightning node package" "The platform menu is not printed in non-interactive mode"

run_snippet "TS_NONINTERACTIVE=1; TS_OPT_PLATFORM=umbrel; ts_guess_platform() { echo raspiblitz; }; detect_platform; echo \"PLATFORM=\$PLATFORM\""
assert_equals 0 "$SN_RC" "--platform answers the platform questions"
assert_contains "$SN_OUT" "PLATFORM=umbrel" "--platform value is used"
assert_contains "$SN_OUT" "Using --platform umbrel (detected: raspiblitz)" "A --platform that differs from the detected platform is reported"
assert_equals "" "$SN_PROMPTS" "--platform reads no answer"

run_snippet "ts_guess_platform() { echo raspiblitz; }; detect_platform; echo \"PLATFORM=\$PLATFORM\"" $'Y\n'
assert_contains "$SN_OUT" "PLATFORM=raspiblitz" "Interactive platform confirmation still works"
assert_equals "Detected Platform: raspiblitz. Correct? [Y/n]: " "$SN_PROMPTS" "Platform confirmation prompt is unchanged"

run_snippet "ts_guess_platform() { echo raspiblitz; }; detect_platform; echo \"PLATFORM=\$PLATFORM\"" $'n\n4\n'
assert_contains "$SN_OUT" "PLATFORM=baremetal" "Interactive platform menu still works"
assert_equals $'Detected Platform: raspiblitz. Correct? [Y/n]: \nSelect [1-4]: ' "$SN_PROMPTS" "Platform menu prompt is unchanged"

run_snippet "ts_guess_platform() { :; }; detect_platform"
assert_interaction_required "--platform <id>" "Platform menu at end of input (piped answers ran out)" eof

# Prompts 4 and 5: implementation confirmation and menu, answered by --impl
run_snippet "PLATFORM=baremetal; TS_NONINTERACTIVE=1; ts_guess_ln_impl_systemd() { echo lnd; }; detect_ln_implementation"
assert_interaction_required "--impl <id>" "Implementation confirmation in non-interactive mode"
assert_no_side_effects "Implementation confirmation in non-interactive mode"

run_snippet "PLATFORM=baremetal; TS_NONINTERACTIVE=1; ts_guess_ln_impl_systemd() { :; }; detect_ln_implementation"
assert_interaction_required "--impl <id>" "Implementation menu in non-interactive mode"
assert_not_contains "$SN_OUT" "Which Lightning implementation" "The implementation menu is not printed in non-interactive mode"

run_snippet "PLATFORM=raspiblitz; TS_NONINTERACTIVE=1; TS_OPT_IMPL=lnd; ts_guess_ln_impl_systemd() { echo lnd; }; detect_ln_implementation; echo \"LN_IMPL=\$LN_IMPL USER=\$node_user\""
assert_contains "$SN_OUT" "LN_IMPL=lnd USER=bitcoin" "--impl matching the detected implementation confirms it"

run_snippet "PLATFORM=raspiblitz; TS_NONINTERACTIVE=1; TS_OPT_IMPL=cln; ts_guess_ln_impl_systemd() { echo lnd; }; detect_ln_implementation; echo \"LN_IMPL=\$LN_IMPL USER=\$node_user\""
assert_contains "$SN_OUT" "LN_IMPL=cln USER=bitcoin" "--impl different from the detected implementation selects it"
assert_contains "$SN_OUT" "Using --impl cln (detected: lnd)" "A --impl that differs from the detected implementation is reported"
assert_equals "" "$SN_PROMPTS" "--impl reads no answer"

run_snippet "PLATFORM=raspiblitz; TS_NONINTERACTIVE=1; TS_OPT_IMPL=lit; ts_guess_ln_impl_systemd() { :; }; detect_ln_implementation"
assert_equals 2 "$SN_RC" "--impl lit outside baremetal is a usage error (exit 2)"
assert_contains "$SN_OUT" "--impl lit is only available on platform baremetal" "--impl lit outside baremetal explains why"

run_snippet "PLATFORM=baremetal; ts_guess_ln_impl_systemd() { echo lnd; }; detect_ln_implementation; echo \"LN_IMPL=\$LN_IMPL\"" $'\n'
assert_contains "$SN_OUT" "LN_IMPL=lnd" "Interactive implementation confirmation (empty answer) still works"
assert_equals "Detected Implementation: LND. Correct? [Y/n]: " "$SN_PROMPTS" "Implementation confirmation prompt is unchanged"

# Prompt 6: LIT confirmation, answered by --yes
run_snippet "PLATFORM=baremetal; TS_NONINTERACTIVE=1; TS_OPT_IMPL=lit; ts_guess_ln_impl_systemd() { :; }; ts_lit_integrated_mode() { return 1; }; detect_ln_implementation"
assert_interaction_required "--yes" "LIT confirmation in non-interactive mode"
assert_contains "$SN_OUT" "Are you sure LIT is managing its own LND? [y/N]:" "LIT refusal quotes the prompt"

run_snippet "PLATFORM=baremetal; TS_NONINTERACTIVE=1; TS_OPT_IMPL=lit; TS_OPT_YES=1; ts_guess_ln_impl_systemd() { :; }; ts_lit_integrated_mode() { return 1; }; detect_ln_implementation; echo \"LN_IMPL=\$LN_IMPL\""
assert_contains "$SN_OUT" "LN_IMPL=lit" "--yes answers the LIT confirmation"

run_snippet "PLATFORM=baremetal; ts_guess_ln_impl_systemd() { :; }; ts_lit_integrated_mode() { return 1; }; detect_ln_implementation; echo \"LN_IMPL=\$LN_IMPL\"" $'3\ny\n'
assert_contains "$SN_OUT" "LN_IMPL=lit" "Interactive implementation menu and LIT confirmation still work"
assert_equals $'Select [1-3]: \nAre you sure LIT is managing its own LND? [y/N]: ' "$SN_PROMPTS" "Implementation menu and LIT prompts are unchanged"

# install: the platform and implementation questions come before any system change
run_snippet "TS_NONINTERACTIVE=1; CONFIG_FILE=/nonexistent.conf; ts_guess_platform() { :; }; cmd_install"
assert_interaction_required "--platform <id>" "install without --platform"
assert_no_side_effects "install without --platform"

run_snippet "TS_NONINTERACTIVE=1; TS_OPT_PLATFORM=baremetal; CONFIG_FILE=/nonexistent.conf; ts_guess_ln_impl_systemd() { :; }; cmd_install"
assert_interaction_required "--impl <id>" "install without --impl"
assert_no_side_effects "install without --impl"

# Prompt 7: uninstall confirmation, answered by --yes
run_snippet "TS_NONINTERACTIVE=1; cmd_uninstall"
assert_interaction_required "--yes" "uninstall without --yes"
assert_no_side_effects "uninstall without --yes"

run_snippet "TS_NONINTERACTIVE=1; TS_OPT_YES=1; ts_guess_platform() { :; }; cmd_uninstall"
assert_interaction_required "--platform <id>" "uninstall --yes without --platform"
assert_no_side_effects "uninstall --yes without --platform"

run_snippet "cmd_uninstall" $'n\n'
assert_equals 1 "$SN_RC" "Interactive uninstall can still be declined"
assert_equals "CAUTION! Uninstalling TunnelSats will force your lightning process to stop. Do you really want to proceed? (Y/N) " \
    "$SN_PROMPTS" "Uninstall confirmation prompt is unchanged"
assert_no_side_effects "Declined uninstall"

# Prompts 8 and 9: package removal after the removal steps; never fails, keeps packages by default
if [[ "$EUID" -eq 0 ]]; then
    skip "running as root: full uninstall runs with stubs"
else
    uninstall_flags="TS_OPT_YES=1; TS_OPT_PLATFORM=baremetal; TS_OPT_IMPL=lnd; ts_guess_ln_impl_systemd() { :; }"
    run_snippet "TS_NONINTERACTIVE=1; ${uninstall_flags}; cmd_uninstall"
    assert_equals 0 "$SN_RC" "Non-interactive uninstall with --yes --platform --impl completes"
    assert_contains "$SN_OUT" "Non-interactive mode: keeping system packages" "Non-interactive uninstall keeps packages by default"
    assert_not_contains "$SN_LOG" "apt-get" "Non-interactive uninstall removes no package"
    assert_equals "" "$SN_PROMPTS" "Non-interactive uninstall reads no answer"

    run_snippet "TS_NONINTERACTIVE=1; TS_OPT_PACKAGES=remove; ${uninstall_flags}; cmd_uninstall"
    assert_contains "$SN_LOG" "apt-get remove -yqq cgroup-tools nftables wireguard-tools" "--remove-packages removes the packages"

    run_snippet "${uninstall_flags}; cmd_uninstall" $'n\n'
    assert_equals "Remove cgroup-tools, nftables and wireguard-tools? (Y/N) " "$SN_PROMPTS" "Package removal prompt is unchanged"
    assert_contains "$SN_OUT" "Packages kept" "Interactive package answer is used"

    run_snippet "${uninstall_flags}; cmd_uninstall"
    assert_equals 0 "$SN_RC" "End of input at the package question keeps the packages and completes"
    assert_contains "$SN_OUT" "No answer received (end of input); using 'N'" "End of input at the package question is reported"
    assert_not_contains "$SN_LOG" "apt-get" "End of input at the package question removes no package"

    # Several installed tunnels: uninstall cleans up every one (it used to clean the first find result)
    wg_multi="$TMP_ROOT/wg_multi"
    mkdir -p "$wg_multi"
    printf '[Interface]\n' > "$wg_multi/tunnelsats-us3.conf"
    printf '[Interface]\n' > "$wg_multi/tunnelsats-de2.conf"
    run_snippet "WG_DIR='$wg_multi'; TS_NONINTERACTIVE=1; ${uninstall_flags}; cmd_uninstall"
    assert_equals 0 "$SN_RC" "Uninstall with two installed tunnels completes"
    for multi_iface in tunnelsats-de2 tunnelsats-us3; do
        assert_contains "$SN_LOG" "systemctl disable wg-quick@${multi_iface}" "Uninstall disables ${multi_iface}"
        assert_contains "$SN_LOG" "nft delete table ip ${multi_iface}" "Uninstall deletes the nft table of ${multi_iface}"
    done
fi

# Prompts 10 and 11: restart confirmations, answered by --yes
wg_single="$TMP_ROOT/wg_single"
mkdir -p "$wg_single"
printf '[Interface]\n' > "$wg_single/tunnelsatsv2.conf"
restart_env="WG_DIR='$wg_single'"
run_snippet "PLATFORM=baremetal; LN_IMPL=lnd; TS_NONINTERACTIVE=1; ${restart_env}; cmd_restart"
assert_interaction_required "--yes" "restart (systemd) without --yes"
assert_no_side_effects "restart (systemd) without --yes"

run_snippet "PLATFORM=umbrel; LN_IMPL=lnd; TS_NONINTERACTIVE=1; ${restart_env}; cmd_restart"
assert_interaction_required "--yes" "restart (Umbrel) without --yes"
assert_no_side_effects "restart (Umbrel) without --yes"

run_snippet "PLATFORM=umbrel; LN_IMPL=lnd; ${restart_env}; cmd_restart" $'n\n'
assert_equals 0 "$SN_RC" "Interactive Umbrel restart can still be declined"
assert_equals "Do you want to proceed? [y/N]: " "$SN_PROMPTS" "Umbrel restart prompt is unchanged"
assert_no_side_effects "Declined Umbrel restart"

if [[ "$EUID" -eq 0 ]]; then
    skip "running as root: full restart runs with stubs"
else
    run_snippet "PLATFORM=baremetal; LN_IMPL=lnd; TS_NONINTERACTIVE=1; TS_OPT_YES=1; ${restart_env}; cmd_restart"
    assert_equals 0 "$SN_RC" "restart --non-interactive --yes completes"
    assert_equals $'systemctl stop lnd.service\nsystemctl stop wg-quick@tunnelsatsv2\nsystemctl start wg-quick@tunnelsatsv2\nsystemctl start lnd.service\nwg show tunnelsatsv2' \
        "$SN_LOG" "--yes stops the daemon before the tunnel and starts it after the tunnel"

    run_snippet "PLATFORM=baremetal; LN_IMPL=lnd; ${restart_env}; cmd_restart" $'n\n'
    assert_equals "Stop lnd.service for safe tunnel restart? [y/N]: " "$SN_PROMPTS" "Systemd restart prompt is unchanged"
    assert_not_contains "$SN_LOG" "systemctl stop lnd.service" "The interactive 'no' answer still keeps the daemon running"
fi

# Prompt 12: the installed config (status, restart), answered by --config. One rule for detect,
# status, restart and uninstall: --config, else tunnelsatsv2.conf, else the only tunnelsats-*.conf.
select_state() {  # $1 = explicit config, $2 = WireGuard directory
    bash -c 'source "$1"; ts_select_wg_config "$2" "" "$3"; echo "selection=${TS_WG_SELECTION} selected=${TS_WG_SELECTED} candidates=${TS_WG_CANDIDATES[*]}"' \
        _ "$SCRIPT_UNDER_TEST" "$1" "$2"
}
wg_sel="$TMP_ROOT/wg_select"
mkdir -p "$wg_sel"
assert_equals "selection=none selected= candidates=" "$(select_state "" "$wg_sel")" "Selection: no TunnelSats config"
printf '[Interface]\n' > "$wg_sel/tunnelsats-us3.conf"
assert_equals "selection=single selected=${wg_sel}/tunnelsats-us3.conf candidates=${wg_sel}/tunnelsats-us3.conf" \
    "$(select_state "" "$wg_sel")" "Selection: the only tunnelsats-*.conf"
printf '[Interface]\n' > "$wg_sel/tunnelsats-de2.conf"
printf '[Interface]\n' > "$wg_sel/tunnelsats-bad name.conf"
assert_equals "selection=ambiguous selected= candidates=${wg_sel}/tunnelsats-de2.conf ${wg_sel}/tunnelsats-us3.conf" \
    "$(select_state "" "$wg_sel")" "Selection: several tunnelsats-*.conf are ambiguous, candidates sorted, invalid names ignored"
assert_equals "selection=explicit selected=/x/tunnelsats-us3.conf candidates=${wg_sel}/tunnelsats-de2.conf ${wg_sel}/tunnelsats-us3.conf" \
    "$(select_state "/x/tunnelsats-us3.conf" "$wg_sel")" "Selection: --config wins"
wg_canon="$TMP_ROOT/wg_canonical"
mkdir -p "$wg_canon"
printf '[Interface]\n' > "$wg_canon/tunnelsats-de2.conf"
printf '[Interface]\n' > "$wg_canon/tunnelsatsv2.conf"
assert_equals "selection=canonical selected=${wg_canon}/tunnelsatsv2.conf candidates=${wg_canon}/tunnelsats-de2.conf ${wg_canon}/tunnelsatsv2.conf" \
    "$(select_state "" "$wg_canon")" "Selection: tunnelsatsv2.conf wins over other configs"

wg_two="$TMP_ROOT/wg_two"
mkdir -p "$wg_two"
printf '[Interface]\n' > "$wg_two/tunnelsats-us3.conf"
printf '[Interface]\n' > "$wg_two/tunnelsats-de2.conf"
run_snippet "PLATFORM=baremetal; LN_IMPL=lnd; TS_NONINTERACTIVE=1; TS_OPT_YES=1; WG_DIR='$wg_two'; cmd_restart"
assert_interaction_required "--config <file>" "restart with two installed configs in non-interactive mode"
assert_contains "$SN_OUT" $'  1) tunnelsats-de2.conf\n  2) tunnelsats-us3.conf' "Ambiguous restart lists the sorted candidates"
assert_no_side_effects "restart with two installed configs in non-interactive mode"

run_snippet "PLATFORM=baremetal; LN_IMPL=lnd; TS_NONINTERACTIVE=1; WG_DIR='$wg_two'; cmd_status"
assert_interaction_required "--config <file>" "status with two installed configs in non-interactive mode"
assert_no_side_effects "status with two installed configs in non-interactive mode"

run_snippet "PLATFORM=baremetal; LN_IMPL=lnd; WG_DIR='$wg_two'; cmd_restart" $'2\nn\n'
assert_equals $'Select config [1-2]: \nStop lnd.service for safe tunnel restart? [y/N]: ' "$SN_PROMPTS" \
    "Interactive restart asks which installed config, with the install selection prompt"
assert_contains "$SN_LOG" "systemctl stop wg-quick@tunnelsats-us3" "Interactive restart uses the chosen config"
assert_not_contains "$SN_LOG" "wg-quick@tunnelsats-de2" "Interactive restart leaves the other tunnel alone"

if [[ "$EUID" -eq 0 ]]; then
    skip "running as root: restart --config runs with stubs"
else
    run_snippet "WG_DIR='$wg_two'; parse_args restart --non-interactive --yes --platform baremetal --impl lnd --config '$wg_two/tunnelsats-de2.conf'"
    assert_equals 0 "$SN_RC" "restart --config with two installed configs completes"
    assert_contains "$SN_LOG" "systemctl stop wg-quick@tunnelsats-de2" "restart --config restarts the named tunnel"
    assert_not_contains "$SN_LOG" "wg-quick@tunnelsats-us3" "restart --config leaves the other tunnel alone"
    assert_equals "" "$SN_PROMPTS" "restart --config reads no answer"
fi

run_snippet "WG_DIR='$wg_two'; parse_args restart --non-interactive --yes --config '$cfg_dir/tunnelsats_a.conf'"
assert_equals 2 "$SN_RC" "restart --config outside the WireGuard directory is a usage error (exit 2)"
assert_contains "$SN_OUT" "restart --config must name an installed config in ${wg_two} [E_USAGE]" "restart --config outside the WireGuard directory explains why"
assert_no_side_effects "restart --config outside the WireGuard directory"

printf '[Interface]\n' > "$wg_two/tunnelsatsv2.conf.bak.Ab12Cd"
run_snippet "WG_DIR='$wg_two'; parse_args restart --non-interactive --yes --config '$wg_two/tunnelsatsv2.conf.bak.Ab12Cd'"
assert_equals 2 "$SN_RC" "restart --config with a backup file name is a usage error (exit 2)"
assert_contains "$SN_OUT" "restart --config must name an installed TunnelSats config" "restart --config with a backup file name explains why"
assert_no_side_effects "restart --config with a backup file name (Lightning is never stopped)"
rm -f "$wg_two/tunnelsatsv2.conf.bak.Ab12Cd"

wg_long="$TMP_ROOT/wg_long"
mkdir -p "$wg_long"
printf '[Interface]\n' > "$wg_long/tunnelsats-toolongname.conf"
assert_equals "selection=none selected= candidates=" "$(select_state "" "$wg_long")" \
    "Selection: an interface name longer than 15 characters is not a loadable config"
if [[ "$EUID" -eq 0 ]]; then
    skip "running as root: unsearchable parent directory"
else
    wg_locked="$TMP_ROOT/wg_locked"
    mkdir -p "$wg_locked/parent/wireguard"
    chmod 000 "$wg_locked/parent"
    assert_equals "selection=permission_denied selected= candidates=" "$(select_state "" "$wg_locked/parent/wireguard")" \
        "Selection: a WireGuard directory behind an unsearchable parent is permission_denied, not none"
    chmod 755 "$wg_locked/parent"
fi

wg_empty="$TMP_ROOT/wg_empty"
mkdir -p "$wg_empty"
run_snippet "PLATFORM=baremetal; LN_IMPL=lnd; TS_NONINTERACTIVE=1; TS_OPT_YES=1; WG_DIR='$wg_empty'; cmd_restart"
assert_equals 1 "$SN_RC" "restart without any TunnelSats config fails (exit 1)"
assert_contains "$SN_OUT" "No TunnelSats configuration found. Pass --config <file>" "restart without a config points to --config"
assert_no_side_effects "restart without any TunnelSats config (no fallback to another WireGuard interface)"

# ---------------------------------------------------------------------------
# GROUP 3: version
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 3: version ---"

script_sha=$(sha256sum "$SCRIPT_UNDER_TEST" | cut -d' ' -f1)
run_cli bash "$SCRIPT_UNDER_TEST" version --json
assert_equals 0 "$CLI_RC" "version --json exits 0"
assert_json_valid "$CLI_OUT" "version --json prints valid JSON"
assert_json "$CLI_OUT" '[d["contract"], d["command"], d["tool_version"], d["ok"], d["exit_code"], d["errors"]]' \
    '[1, "version", "3.2", true, 0, []]' "version envelope fields"
assert_json "$CLI_OUT" 'd["tool_sha256"]' "$script_sha" "version reports the sha256 of the running script"
assert_equals "" "$CLI_ERR" "version --json logs nothing"

run_cli bash "$SCRIPT_UNDER_TEST" --json version
assert_json "$CLI_OUT" 'd["command"]' version "--json before the command works"

run_cli bash "$SCRIPT_UNDER_TEST" version
assert_equals 0 "$CLI_RC" "version exits 0"
assert_equals "tunnelsats.sh 3.2 (CLI contract 1)"$'\n'"sha256: ${script_sha}" "$CLI_OUT" "Human version output"

# ---------------------------------------------------------------------------
# GROUP 4: detect on fixture trees
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 4: detect ---"

STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/wg" <<'EOF'
#!/bin/bash
# Test stub for wg: logs its arguments and derives one known key pair from stdin
printf 'wg %s\n' "$*" >> "${STUB_LOG:-/dev/null}"
case "${1:-}" in
    --version) echo "wireguard-tools v1.0.20210914 - https://git.zx2c4.com/wireguard-tools/" ;;
    pubkey)
        read -r key || true
        if [[ "$key" == "$STUB_WG_PRIV" ]]; then echo "$STUB_WG_PUB"; else exit 1; fi
        ;;
    *) echo "wg stub: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
cat > "$STUB_BIN/ip" <<'EOF'
#!/bin/bash
# Test stub for ip: answers the read-only queries of detect from fixture files
printf 'ip %s\n' "$*" >> "${STUB_LOG:-/dev/null}"
k="${STUB_KERNEL:?}"
case "$*" in
    "-4 rule show") cat "$k/ip_rules" ;;
    "route show table 51820"|"route show table 52")
        f="$k/table_${!#}"
        if [[ -f "$f" ]]; then cat "$f"; else echo "Error: ipv4: FIB table does not exist." >&2; exit 2; fi
        ;;
    "-o link show type wireguard") cat "$k/wg_links" ;;
    *) echo "ip stub: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
cat > "$STUB_BIN/nft" <<'EOF'
#!/bin/bash
# Test stub for nft: version and table listing from fixture files
printf 'nft %s\n' "$*" >> "${STUB_LOG:-/dev/null}"
k="${STUB_KERNEL:?}"
case "$*" in
    --version) echo "nftables v1.0.6 (Lester Gooch #5)" ;;
    "list tables")
        if [[ -f "$k/nft_denied" ]]; then echo "Error: Could not process rule: Operation not permitted" >&2; exit 1; fi
        cat "$k/nft_tables"
        ;;
    *) echo "nft stub: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
cat > "$STUB_BIN/systemctl" <<'EOF'
#!/bin/bash
# Test stub for systemctl: version and unit states from fixture files
printf 'systemctl %s\n' "$*" >> "${STUB_LOG:-/dev/null}"
k="${STUB_KERNEL:?}"
case "${1:-}" in
    --version) printf 'systemd 252 (252.30-1~deb12u2)\n+PAM +AUDIT +SELINUX\n' ;;
    is-active)
        shift
        quiet=0
        unit=""
        for a in "$@"; do
            if [[ "$a" == "--quiet" ]]; then quiet=1; else unit="${a%.service}"; fi
        done
        state="inactive"
        if [[ -f "$k/active_${unit}" ]]; then state="$(cat "$k/active_${unit}")"; fi
        if [[ "$quiet" -eq 0 ]]; then echo "$state"; fi
        [[ "$state" == "active" ]]
        ;;
    *) echo "systemctl stub: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/wg-quick"
chmod +x "$STUB_BIN/wg" "$STUB_BIN/ip" "$STUB_BIN/nft" "$STUB_BIN/systemctl" "$STUB_BIN/wg-quick"

# Creates fixture $1 (fs/ is the TS_FS_ROOT tree, kernel/ feeds the stubs) and prints its path.
new_fixture() {
    local fx="$TMP_ROOT/fixtures/$1"
    mkdir -p "$fx/fs/etc/systemd/system" "$fx/fs/proc" "$fx/kernel"
    printf 'cgroup2 /sys/fs/cgroup cgroup2 rw,nosuid,nodev,noexec,relatime,nsdelegate 0 0\n' > "$fx/fs/proc/mounts"
    printf '0:\tfrom all lookup local\n32766:\tfrom all lookup main\n32767:\tfrom all lookup default\n' > "$fx/kernel/ip_rules"
    : > "$fx/kernel/nft_tables"
    : > "$fx/kernel/wg_links"
    echo "$fx"
}

put() {
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" > "$1"
}

tree_snapshot() {
    (cd "$1" && find . -printf '%p|%y|%s|%m|%T@\n' 2>/dev/null | LC_ALL=C sort)
}

# Runs detect against fixture $1 with the stub commands; extra arguments go to the script.
run_detect() {
    local fx="$1"
    shift
    : > "$TMP_ROOT/stub.log"
    run_cli env TS_FS_ROOT="$fx/fs" STUB_KERNEL="$fx/kernel" STUB_LOG="$TMP_ROOT/stub.log" \
        STUB_WG_PRIV="$PRIV_KEY" STUB_WG_PUB="$STUB_PUB_KEY" \
        WG_BIN="${DETECT_WG_BIN:-$STUB_BIN/wg}" WG_QUICK_BIN="$STUB_BIN/wg-quick" NFT_BIN="$STUB_BIN/nft" \
        IP_BIN="$STUB_BIN/ip" SYSTEMCTL_BIN="$STUB_BIN/systemctl" \
        bash "$SCRIPT_UNDER_TEST" detect "$@"
    STUB_CALLS="$(cat "$TMP_ROOT/stub.log")"
}

assert_readonly_calls() {
    local line bad=""
    while IFS= read -r line; do
        case "$line" in
            ""|"wg --version"|"wg pubkey"|"ip -4 rule show"|"ip route show table 51820"|"ip route show table 52"|\
            "ip -o link show type wireguard"|"nft --version"|"nft list tables"|"systemctl --version"|"systemctl is-active "*) ;;
            *) bad+="${line}; " ;;
        esac
    done <<< "$STUB_CALLS"
    if [[ -z "$bad" ]]; then
        pass "$1: only read-only queries"
    else
        fail "$1: unexpected commands: $bad"
    fi
}

# Status of the first artifact with id $2 and location $3 in document $1
art_status() {
    json_eval "$1" "next((a['status'] for a in d['install']['artifacts'] if a['id'] == '$2' and a['location'] == '$3'), 'MISSING')"
}

conflict_status() {
    json_eval "$1" "next((c['status'] for c in d['conflicts'] if c['id'] == '$2'), 'MISSING')"
}

website_config() {
    cat <<EOF
[Interface]
# StartTunnel
# inbound: yes
# TunnelSats WireGuard Configuration
# Server: de2.tunnelsats.com
# Port Forwarding: 24556
# myPubKey: $1
# Valid Until: 2026-11-07T08:18:33.839Z
PrivateKey = ${PRIV_KEY}
Address = 10.9.0.42/32

[Peer]
PublicKey = ${SERVER_KEY}
PresharedKey = ${PSK_KEY}
Endpoint = de2.tunnelsats.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
}

old_website_config() {
    cat <<EOF
[Interface]
#myPubKey = ${COMMENT_KEY_A}
#VPNPort = 48049
#ValidUntil (UTC time) = 2025-06-29T08:18:33.839Z
PrivateKey = ${PRIV_KEY}
Address = 10.9.0.109/32

[Peer]
PublicKey = ${SERVER_KEY}
PresharedKey = ${PSK_KEY}
Endpoint = us3.tunnelsats.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
}

V2_HOOKS=$(cat <<'EOF'

#Tunnelsats-Setupv2-Non-Docker

[Interface]
FwMark = 0x2000000
Table = off

PostUp = while [ $(ip rule | grep -c suppress_prefixlength) -gt 0 ]; do ip rule del from all table  main suppress_prefixlength 0;done
PostUp = ip rule add from all fwmark 0x1000000/0xff000000 table 51820;ip rule add from all table main suppress_prefixlength 0
PostUp = ip route add default dev %i table 51820;
PostUp = nft insert rule ip %i nat skuid bitcoin fib  daddr type != local ip daddr != {192.168.1.0/24}  meta oifname != %i  meta l4proto { tcp, udp } th dport != { 51820 } counter drop
PostDown = ip route flush table 51820
EOF
)

V3_PRE_204_HOOKS=$(cat <<'EOF'

#Tunnelsats-Setupv2-Non-Docker

[Interface]
FwMark = 0x2000000
Table = off

PostUp = while [ $(ip rule | grep -c suppress_prefixlength) -gt 0 ]; do ip rule del from all table  main suppress_prefixlength 0;done
PostUp = ip rule add from all fwmark 0x1000000/0xff000000 table 51820;ip rule add from all table main suppress_prefixlength 0
PostUp = ip route add default dev %i table 51820;
PostUp = nft add rule ip %i mangle tcp sport != { 8080, 10009 } meta mark and 0xff000000 != 0x2000000 meta cgroup 1118498 meta mark set 0x1000000
PostUp = nft "insert rule ip %i nat skuid bitcoin meta cgroup 1118498 fib daddr type != local ip daddr != { 192.168.1.0/24 } meta oifname != %i counter drop"
PostDown = ip route flush table 51820
EOF
)

V3_POST_204_HOOKS=$(cat <<'EOF'

#Tunnelsats-Setupv2-Non-Docker

[Interface]
FwMark = 0x2000000
Table = off

PostUp = /etc/wireguard/tunnelsats-route-guard.sh check %i 10.9.9.0/25 1001
PostUp = /etc/wireguard/tunnelsats-route-guard.sh clean %i
PostUp = ip route add default dev %i table 51820;
PostUp = ip rule add from all table main suppress_prefixlength 0 priority 21820
PostUp = ip rule add from all fwmark 0x1000000/0xff000000 table 51820 priority 21821
PostUp = nft "insert rule ip %i nat skuid bitcoin meta cgroup 1118498 fib daddr type != local ip daddr != { 192.168.1.0/24 } meta oifname != %i counter drop"
PostUp = /etc/wireguard/tunnelsats-route-guard.sh release 10.9.9.0/25 1001
PostDown = nft delete table ip %i
EOF
)

lnd_unit() {  # $1 = ExecStartPre line
    cat <<EOF
[Unit]
Description=LND Lightning Network Daemon
[Service]
User=bitcoin
$1
ExecStart=/usr/bin/cgexec -g net_cls:splitted_processes /usr/local/bin/lnd --configfile=/mnt/hdd/app-data/lnd/lnd.conf
EOF
}

ln_dropin() {  # $1 = Requires or Wants
    cat <<EOF
#Don't edit this file its generated by tunnelsats scripts
[Unit]
Description=lnd service - powered by tunnelsats
$1=tunnelsats-create-cgroup.service
After=tunnelsats-create-cgroup.service
$1=wg-quick@tunnelsatsv2.service
After=wg-quick@tunnelsatsv2.service
EOF
}

# Units and helper scripts written by both v2 and v3
add_common_install() {
    local fs="$1/fs" unit
    for unit in tunnelsats-create-cgroup.service tunnelsats-splitting-processes.service tunnelsats-splitting-processes.timer \
        tunnelsats-resolve-dns-wg.service tunnelsats-resolve-dns-wg.timer; do
        put "$fs/etc/systemd/system/$unit" "[Unit]"
    done
    put "$fs/etc/wireguard/tunnelsats-create-cgroup.sh" "#!/bin/sh"
    put "$fs/etc/wireguard/tunnelsats-splitting-processes.sh" "#!/bin/sh"
    put "$fs/etc/wireguard/tunnelsats-resolve-dns-wg.sh" "#!/bin/bash"
    put "$fs/etc/systemd/system/blitzapi.service.d/tunnelsats-wg.conf" "[Unit]"
    put "$fs/etc/systemd/system/lnd.service.bak" "[Unit]"
    mkdir -p "$fs/etc/systemd/system/multi-user.target.wants" "$fs/home/admin/config.scripts"
    ln -s /lib/systemd/system/wg-quick@.service "$fs/etc/systemd/system/multi-user.target.wants/wg-quick@tunnelsatsv2.service"
    printf '5: tunnelsatsv2: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000\\    link/none \n' > "$1/kernel/wg_links"
    printf 'table ip tunnelsatsv2\n' > "$1/kernel/nft_tables"
    printf 'default dev tunnelsatsv2 scope link \n' > "$1/kernel/table_51820"
    echo active > "$1/kernel/active_lnd"
}

# Fixture: nothing installed
fx_none=$(new_fixture none)
snapshot_before=$(tree_snapshot "$fx_none")
run_detect "$fx_none" --json
assert_equals 0 "$CLI_RC" "[none] detect --json exits 0"
assert_json_valid "$CLI_OUT" "[none] detect --json prints valid JSON"
assert_json "$CLI_OUT" '[d["contract"], d["command"], d["tool_version"], d["ok"], d["exit_code"], d["errors"]]' \
    '[1, "detect", "3.2", true, 0, []]' "[none] envelope fields"
assert_json "$CLI_OUT" '[d["install"]["kind"], d["install"]["candidates"], d["install"]["evidence"]]' \
    '["none", ["none"], []]' "[none] install kind is none"
assert_json "$CLI_OUT" '[d["platform"]["guess"], d["lightning"]["guess"], d["config"]["status"], d["config"]["selection"], d["config"]["candidates"]]' \
    '[null, null, "absent", "none", []]' "[none] no platform, Lightning or config"
assert_json "$CLI_OUT" '[a["status"] for a in d["install"]["artifacts"] if a["status"] != "absent"]' '[]' "[none] every artifact is absent"
assert_json "$CLI_OUT" 'd["capabilities"]["wireguard_tools"]' \
    '{"status": "present", "version": "1.0.20210914", "wg_quick": "present", "wg_quick_unit": "absent"}' "[none] wireguard-tools capability"
assert_json "$CLI_OUT" '[d["capabilities"]["nft"], d["capabilities"]["systemd"]]' \
    '[{"status": "present", "version": "1.0.6"}, {"status": "present", "version": 252}]' "[none] nft and systemd versions"
assert_json "$CLI_OUT" '[d["capabilities"]["cgroup_v2"], d["capabilities"]["net_cls_v1"]]' \
    '[{"status": "mounted", "mountpoint": "/sys/fs/cgroup"}, {"status": "not_mounted", "mountpoint": null}]' "[none] cgroup capabilities"
assert_json "$CLI_OUT" '{c["id"]: c["status"] for c in d["conflicts"]}' \
    '{"table_51820_foreign_routes": "not_detected", "tailscale_exit_node": "not_detected", "nftables_service_enabled": "not_detected", "multiple_ln_implementations": "not_detected", "raspiblitz_custom_lnd_port": "not_applicable", "raspiblitz_custom_installs": "not_applicable"}' \
    "[none] no conflicts"
assert_json "$CLI_OUT" '[d["privileged"], d["unreadable_items"]]' "[$([[ $EUID -eq 0 ]] && echo true || echo false), 0]" \
    "[none] privileged flag and no unreadable item"
assert_readonly_calls "[none]"
assert_equals "$snapshot_before" "$(tree_snapshot "$fx_none")" "[none] detect changed nothing in the fixture tree"

# Fixture: legacy v2 (setupv2.sh on RaspiBlitz)
fx_v2=$(new_fixture legacy_v2)
add_common_install "$fx_v2"
put "$fx_v2/fs/etc/wireguard/tunnelsatsv2.conf" "$(old_website_config)${V2_HOOKS}"
put "$fx_v2/fs/etc/systemd/system/lnd.service" "$(lnd_unit 'ExecStartPre=-/home/admin/config.scripts/lnd.check.sh prestart mainnet')"
put "$fx_v2/fs/etc/systemd/system/lnd.service.d/tunnelsats-cgroup.conf" "$(ln_dropin Requires)"
put "$fx_v2/fs/home/admin/config.scripts/lnd.check.bak" "#!/bin/bash"
printf '0:\tfrom all lookup local\n32764:\tfrom all lookup main suppress_prefixlength 0\n32765:\tfrom all fwmark 0x1000000/0xff000000 lookup 51820\n32766:\tfrom all lookup main\n' > "$fx_v2/kernel/ip_rules"
run_detect "$fx_v2" --json
assert_equals 0 "$CLI_RC" "[legacy_v2] detect --json exits 0"
assert_json "$CLI_OUT" 'd["install"]["kind"]' legacy_v2 "[legacy_v2] install kind"
assert_json "$CLI_OUT" 'sorted(d["install"]["evidence"])' \
    '["config_without_route_guard", "legacy_rule_selectors", "v2_check_script_renamed", "v2_dropin_requires", "v2_killswitch_uid_only"]' \
    "[legacy_v2] evidence"
assert_json "$CLI_OUT" '[d["platform"]["guess"], d["lightning"]["guess"]]' '["raspiblitz", "lnd"]' "[legacy_v2] platform and Lightning guesses"
assert_json "$CLI_OUT" 'd["lightning"]["units"][0]' \
    '{"impl": "lnd", "unit": "lnd.service", "file": "present", "path": "/etc/systemd/system/lnd.service", "active": "active", "user": "bitcoin"}' "[legacy_v2] lnd unit present and active"
assert_equals "present" "$(art_status "$CLI_OUT" raspiblitz_check_renamed /home/admin/config.scripts/lnd.check.bak)" "[legacy_v2] renamed lnd.check.sh artifact"
assert_json "$CLI_OUT" 'next(a["detail"] for a in d["install"]["artifacts"] if a["id"] == "ln_dropin" and a["status"] == "present")' requires \
    "[legacy_v2] drop-in uses Requires="
assert_equals "present" "$(art_status "$CLI_OUT" wg_quick_enabled /etc/systemd/system/multi-user.target.wants/wg-quick@tunnelsatsv2.service)" \
    "[legacy_v2] wg-quick enablement symlink (dangling in the fixture) is found"
assert_equals "present" "$(art_status "$CLI_OUT" ln_unit_cgexec /etc/systemd/system/lnd.service)" "[legacy_v2] cgexec in the lnd unit"
assert_equals "present" "$(art_status "$CLI_OUT" nft_table "nft table ip tunnelsatsv2")" "[legacy_v2] nft table"
assert_equals "present" "$(art_status "$CLI_OUT" wg_interface "wireguard link tunnelsatsv2")" "[legacy_v2] WireGuard link"
assert_equals "present" "$(art_status "$CLI_OUT" table_51820_route "ip -4 route table 51820")" "[legacy_v2] TunnelSats route in table 51820"
assert_json "$CLI_OUT" '[d["config"][k] for k in ("path", "status", "interface", "marker", "marker_count")]' \
    '["/etc/wireguard/tunnelsatsv2.conf", "ok", "tunnelsatsv2", "non_docker", 1]' "[legacy_v2] config path and marker"
assert_json "$CLI_OUT" '[d["config"]["endpoint"], d["config"]["vpn_port"], d["config"]["valid_until"]]' \
    '[{"host": "us3.tunnelsats.com", "port": 51820, "status": "ok"}, {"value": 48049, "status": "ok"}, {"value": "2025-06-29T08:18:33.839Z", "status": "ok"}]' \
    "[legacy_v2] old comment formats are parsed (full expiry timestamp)"
assert_json "$CLI_OUT" 'd["config"]["hooks"]' '{"route_guard": "absent", "killswitch": "skuid_only"}' "[legacy_v2] hook facts"
assert_json "$CLI_OUT" '[d["config"]["selection"], d["config"]["candidates"]]' '["canonical", ["/etc/wireguard/tunnelsatsv2.conf"]]' \
    "[legacy_v2] tunnelsatsv2.conf is selected as the canonical config"
assert_json "$CLI_OUT" '[[c["status"], c["detail"]] for c in d["conflicts"] if c["id"].startswith("raspiblitz_")]' \
    '[["unknown", "raspiblitz.conf not found"], ["unknown", "raspiblitz.conf not found"]]' \
    "[legacy_v2] RaspiBlitz checks are unknown, not inapplicable, while raspiblitz.conf is missing"
assert_readonly_calls "[legacy_v2]"

# Fixture: legacy v3 before #204
fx_v3pre=$(new_fixture legacy_v3_pre_204)
add_common_install "$fx_v3pre"
put "$fx_v3pre/fs/etc/wireguard/tunnelsatsv2.conf" "$(website_config "$COMMENT_KEY_A")${V3_PRE_204_HOOKS}"
put "$fx_v3pre/fs/etc/systemd/system/lnd.service" "$(lnd_unit '#ExecStartPre=-/home/admin/config.scripts/lnd.check.sh prestart mainnet')"
put "$fx_v3pre/fs/etc/systemd/system/lnd.service.d/tunnelsats-cgroup.conf" "$(ln_dropin Wants)"
put "$fx_v3pre/fs/etc/wireguard/.tunnelsats-ufw-9735-tunnelsatsv2.created" ""
put "$fx_v3pre/fs/mnt/hdd/raspiblitz.conf" $'lightning=lnd\nlndPort=9735'
run_detect "$fx_v3pre" --json
assert_json "$CLI_OUT" 'd["install"]["kind"]' legacy_v3_pre_204 "[legacy_v3_pre_204] install kind"
assert_json "$CLI_OUT" 'sorted(d["install"]["evidence"])' \
    '["config_without_route_guard", "v3_check_disabled_in_unit", "v3_dropin_wants", "v3_killswitch_uid_cgroup", "v3_ufw_marker"]' \
    "[legacy_v3_pre_204] evidence"
assert_equals "present" "$(art_status "$CLI_OUT" ufw_marker /etc/wireguard/.tunnelsats-ufw-9735-tunnelsatsv2.created)" "[legacy_v3_pre_204] UFW marker found by glob"
assert_equals "absent" "$(art_status "$CLI_OUT" route_guard_script /etc/wireguard/tunnelsats-route-guard.sh)" "[legacy_v3_pre_204] no route guard"
assert_json "$CLI_OUT" '[d["config"]["vpn_port"], d["config"]["valid_until"], d["config"]["public_key_comment"]["status"]]' \
    '[{"value": 24556, "status": "ok"}, {"value": "2026-11-07T08:18:33.839Z", "status": "ok"}, "ok"]' "[legacy_v3_pre_204] website comment formats are parsed"
assert_json "$CLI_OUT" '[c["status"] for c in d["conflicts"] if c["id"].startswith("raspiblitz_")]' '["not_detected", "not_detected"]' \
    "[legacy_v3_pre_204] default lndPort in the old raspiblitz.conf location and no custom-installs.sh"
assert_readonly_calls "[legacy_v3_pre_204]"

# Fixture: legacy v3 after #204 (route guard), with every conflict present
make_post_204_fixture() {
    local fx
    fx=$(new_fixture "$1")
    add_common_install "$fx"
    put "$fx/fs/etc/wireguard/tunnelsatsv2.conf" "$(website_config "$COMMENT_KEY_A")${V3_POST_204_HOOKS}"
    put "$fx/fs/etc/wireguard/tunnelsatsv2.conf.bak.Ab12Cd" "$(website_config "$COMMENT_KEY_A")"
    put "$fx/fs/etc/wireguard/tunnelsats-route-guard.sh" "#!/bin/bash"
    put "$fx/fs/etc/systemd/system/lnd.service" "$(lnd_unit '#ExecStartPre=-/home/admin/config.scripts/lnd.check.sh prestart mainnet')"
    put "$fx/fs/etc/systemd/system/lnd.service.d/tunnelsats-cgroup.conf" "$(ln_dropin Wants)"
    put "$fx/fs/etc/systemd/system/lightningd.service" "[Service]"
    put "$fx/fs/etc/nftables.conf" $'#!/usr/sbin/nft -f\nflush ruleset'
    mkdir -p "$fx/fs/etc/systemd/system/sysinit.target.wants"
    ln -s /lib/systemd/system/nftables.service "$fx/fs/etc/systemd/system/sysinit.target.wants/nftables.service"
    put "$fx/fs/mnt/hdd/app-data/raspiblitz.conf" $'lightning=lnd\nlndPort=\'9736\''
    put "$fx/fs/mnt/hdd/app-data/custom-installs.sh" $'#!/bin/bash\n# custom\nsudo bash /home/admin/tunnelsats.sh install'
    printf '0:\tfrom all lookup local\n21820:\tfrom all lookup main suppress_prefixlength 0\n21821:\tfrom all fwmark 0x1000000/0xff000000 lookup 51820\n32766:\tfrom all lookup main\n' > "$fx/kernel/ip_rules"
    printf 'default dev tunnelsatsv2 scope link \n10.20.0.0/16 dev wg9 scope link \n' > "$fx/kernel/table_51820"
    printf 'default dev tailscale0 \n' > "$fx/kernel/table_52"
    echo "$fx"
}
fx_v3post=$(make_post_204_fixture legacy_v3_post_204)
run_detect "$fx_v3post" --json
assert_json "$CLI_OUT" 'd["install"]["kind"]' legacy_v3_post_204 "[legacy_v3_post_204] install kind"
assert_json "$CLI_OUT" 'sorted(set(d["install"]["evidence"]) & {"route_guard_script", "route_guard_hook", "config_backup_copies", "rule_priorities_21820_21821"})' \
    '["config_backup_copies", "route_guard_hook", "route_guard_script", "rule_priorities_21820_21821"]' "[legacy_v3_post_204] route guard evidence"
assert_json "$CLI_OUT" 'next([a["status"], a["contains_secrets"]] for a in d["install"]["artifacts"] if a["location"] == "/etc/wireguard/tunnelsatsv2.conf.bak.Ab12Cd")' \
    '["present", true]' "[legacy_v3_post_204] config backup with keys is listed"
assert_equals "present" "$(art_status "$CLI_OUT" ip_rule "ip -4 rule 21820 (lookup main suppress_prefixlength 0)")" "[legacy_v3_post_204] ip rule 21820"
assert_equals "present" "$(art_status "$CLI_OUT" ip_rule "ip -4 rule 21821 (lookup 51820)")" "[legacy_v3_post_204] ip rule 21821"
assert_json "$CLI_OUT" 'd["config"]["hooks"]' '{"route_guard": "present", "killswitch": "skuid_cgroup"}' "[legacy_v3_post_204] hook facts"
assert_equals "detected" "$(conflict_status "$CLI_OUT" table_51820_foreign_routes)" "[legacy_v3_post_204] foreign table 51820 route is a conflict"
assert_contains "$(json_eval "$CLI_OUT" 'next(c["detail"] for c in d["conflicts"] if c["id"] == "table_51820_foreign_routes")')" \
    "10.20.0.0/16 dev wg9" "[legacy_v3_post_204] foreign route is named, the TunnelSats route is not"
assert_equals "detected" "$(conflict_status "$CLI_OUT" tailscale_exit_node)" "[legacy_v3_post_204] Tailscale exit node"
assert_contains "$(json_eval "$CLI_OUT" 'next(c["detail"] for c in d["conflicts"] if c["id"] == "nftables_service_enabled")')" \
    "flushes the whole ruleset" "[legacy_v3_post_204] enabled nftables.service that flushes the ruleset"
assert_equals "detected" "$(conflict_status "$CLI_OUT" multiple_ln_implementations)" "[legacy_v3_post_204] LND and CLN units"
assert_json "$CLI_OUT" 'next([c["status"], c["detail"]] for c in d["conflicts"] if c["id"] == "raspiblitz_custom_lnd_port")' \
    '["detected", "lndPort=9736"]' "[legacy_v3_post_204] custom RaspiBlitz lndPort"
assert_json "$CLI_OUT" 'next([c["status"], c["detail"]] for c in d["conflicts"] if c["id"] == "raspiblitz_custom_installs")' \
    '["detected", "lines 3"]' "[legacy_v3_post_204] custom-installs.sh reference"
assert_readonly_calls "[legacy_v3_post_204]"

run_detect "$fx_v3post"
assert_equals 0 "$CLI_RC" "[legacy_v3_post_204] human detect exits 0"
assert_contains "$CLI_OUT" "Kind:             legacy_v3_post_204" "[legacy_v3_post_204] human output shows the install kind"
assert_contains "$CLI_OUT" "table_51820_foreign_routes: detected" "[legacy_v3_post_204] human output shows conflicts"
assert_not_contains "$CLI_OUT$CLI_ERR" $'\033[' "[legacy_v3_post_204] human detect output has no ANSI colours when piped"
assert_not_contains "$CLI_OUT$CLI_ERR" "$PRIV_KEY" "[legacy_v3_post_204] human output never shows the private key"

# Fixture: both public key comment forms; the key derived from PrivateKey must win
fx_keys=$(new_fixture pubkey_forms)
put "$fx_keys/fs/etc/wireguard/tunnelsatsv2.conf" "$(website_config "$COMMENT_KEY_B" | sed "s|^# StartTunnel|#myPubKey = ${COMMENT_KEY_A}\n# StartTunnel|")"
run_detect "$fx_keys" --json
assert_json "$CLI_OUT" 'd["config"]["public_key"]' "{\"value\": \"${STUB_PUB_KEY}\", \"status\": \"derived\", \"source\": \"private_key\"}" \
    "[pubkey_forms] public key is derived from PrivateKey"
assert_json "$CLI_OUT" 'd["config"]["public_key_comment"]' "{\"value\": \"${COMMENT_KEY_A}\", \"status\": \"ok\", \"matches_derived\": false}" \
    "[pubkey_forms] comment key is only a hint and reported as not matching"
assert_contains "$STUB_CALLS" "wg pubkey" "[pubkey_forms] the key is derived with wg pubkey"
assert_not_contains "$STUB_CALLS" "$PRIV_KEY" "[pubkey_forms] the private key is never a command argument"
assert_not_contains "$CLI_OUT$CLI_ERR" "$PRIV_KEY" "[pubkey_forms] the private key is never printed"
if command -v wg >/dev/null 2>&1; then
    DETECT_WG_BIN="$(command -v wg)" run_detect "$fx_keys" --json
    assert_json "$CLI_OUT" 'd["config"]["public_key"]["value"]' "$REAL_PUB_KEY" "[pubkey_forms] real wg pubkey derivation"
else
    skip "wireguard-tools not installed: real wg pubkey derivation"
fi

# Fixture: hostile values in the config stay contained and the document stays valid
fx_hostile=$(new_fixture hostile)
put "$fx_hostile/fs/etc/wireguard/tunnelsatsv2.conf" "$(printf '[Interface]\n# Valid Until: 2026"},{"x":"\\\001\n# Port Forwarding: 99999\nPrivateKey = not-a-key\n[Peer]\nEndpoint = evil"host\033[31m:51820\n')"
run_detect "$fx_hostile" --json
assert_json_valid "$CLI_OUT" "[hostile] detect output stays valid JSON"
assert_json "$CLI_OUT" '[d["config"][k]["status"] for k in ("endpoint", "vpn_port", "public_key", "valid_until")]' \
    '["invalid", "invalid", "invalid_private_key", "invalid"]' "[hostile] invalid values are rejected"
assert_json "$CLI_OUT" '[d["config"]["endpoint"]["host"], d["config"]["valid_until"]["value"]]' '[null, null]' "[hostile] invalid values are not echoed"

# Fixture: Lightning units outside /etc/systemd/system. Packaged units live under
# /usr/lib/systemd/system and a running unit may have no unit file at all; both count.
fx_units=$(new_fixture ln_vendor_units)
put "$fx_units/fs/usr/lib/systemd/system/lnd.service" $'[Service]\nUser=lnd\nExecStart=/usr/bin/lnd'
echo active > "$fx_units/kernel/active_lnd"
echo active > "$fx_units/kernel/active_lightningd"
run_detect "$fx_units" --json
assert_json "$CLI_OUT" 'd["lightning"]["units"][0]' \
    '{"impl": "lnd", "unit": "lnd.service", "file": "present", "path": "/usr/lib/systemd/system/lnd.service", "active": "active", "user": "lnd"}' \
    "[ln_vendor_units] unit file under /usr/lib/systemd/system is found"
assert_json "$CLI_OUT" 'd["lightning"]["units"][1]' \
    '{"impl": "cln", "unit": "lightningd.service", "file": "absent", "path": null, "active": "active", "user": null}' \
    "[ln_vendor_units] running unit without a unit file is reported as active"
assert_json "$CLI_OUT" 'd["lightning"]["guess"]' lnd "[ln_vendor_units] the running LND is the Lightning guess"
assert_json "$CLI_OUT" 'next([c["status"], c["detail"]] for c in d["conflicts"] if c["id"] == "multiple_ln_implementations")' \
    '["detected", "lnd.service (active), lightningd.service (active)"]' \
    "[ln_vendor_units] two running implementations without local unit files are a conflict"
assert_readonly_calls "[ln_vendor_units]"
run_detect "$fx_units"
assert_contains "$CLI_OUT" "lnd.service: file present (/usr/lib/systemd/system/lnd.service), active, user lnd" \
    "[ln_vendor_units] human output names the unit file location"
assert_contains "$CLI_OUT" "lightningd.service: file absent, active" "[ln_vendor_units] human output lists the running unit without a file"
echo inactive > "$fx_units/kernel/active_lightningd"
run_detect "$fx_units" --json
assert_json "$CLI_OUT" 'next([c["status"], c["detail"]] for c in d["conflicts"] if c["id"] == "multiple_ln_implementations")' \
    '["not_detected", "lnd.service (active)"]' "[ln_vendor_units] a single running implementation is not a conflict"

# Fixture: two installed but stopped implementations in different unit directories
fx_split=$(new_fixture ln_split_unit_dirs)
put "$fx_split/fs/etc/systemd/system/lnd.service" $'[Service]\nUser=bitcoin'
put "$fx_split/fs/lib/systemd/system/lightningd.service" $'[Service]\nUser=bitcoin'
run_detect "$fx_split" --json
assert_json "$CLI_OUT" '[u["path"] for u in d["lightning"]["units"]]' \
    '["/etc/systemd/system/lnd.service", "/lib/systemd/system/lightningd.service", null, null]' \
    "[ln_split_unit_dirs] unit files are found in /etc/systemd/system and /lib/systemd/system"
assert_json "$CLI_OUT" 'next([c["status"], c["detail"]] for c in d["conflicts"] if c["id"] == "multiple_ln_implementations")' \
    '["detected", "lnd.service (inactive), lightningd.service (inactive)"]' \
    "[ln_split_unit_dirs] installed implementations count even when stopped"

# Fixture: masked units. systemctl mask links the unit to /dev/null in /etc/systemd/system; that
# hides the packaged unit and the unit cannot start, so it is not an installed implementation.
fx_mask=$(new_fixture ln_masked_units)
ln -s /dev/null "$fx_mask/fs/etc/systemd/system/lnd.service"
put "$fx_mask/fs/usr/lib/systemd/system/lnd.service" $'[Service]\nUser=lnd'
put "$fx_mask/fs/usr/lib/systemd/system/lightningd.service" $'[Service]\nUser=bitcoin'
echo active > "$fx_mask/kernel/active_lightningd"
run_detect "$fx_mask" --json
assert_json "$CLI_OUT" 'd["lightning"]["units"][0]' \
    '{"impl": "lnd", "unit": "lnd.service", "file": "masked", "path": "/etc/systemd/system/lnd.service", "active": "inactive", "user": null}' \
    "[ln_masked_units] a unit linked to /dev/null is reported as masked"
assert_json "$CLI_OUT" 'next([c["status"], c["detail"]] for c in d["conflicts"] if c["id"] == "multiple_ln_implementations")' \
    '["not_detected", "lightningd.service (active)"]' "[ln_masked_units] a masked unit is not counted next to the running CLN"
assert_json "$CLI_OUT" 'd["lightning"]["guess"]' cln "[ln_masked_units] the running CLN is the Lightning guess"
assert_readonly_calls "[ln_masked_units]"
run_detect "$fx_mask"
assert_contains "$CLI_OUT" "lnd.service: file masked (/etc/systemd/system/lnd.service), inactive" "[ln_masked_units] human output shows the mask"
echo active > "$fx_mask/kernel/active_lnd"
run_detect "$fx_mask" --json
assert_json "$CLI_OUT" 'next([c["status"], c["detail"]] for c in d["conflicts"] if c["id"] == "multiple_ln_implementations")' \
    '["detected", "lnd.service (active), lightningd.service (active)"]' "[ln_masked_units] a masked unit that still runs is counted"
rm -f "$fx_mask/kernel/active_lnd" "$fx_mask/fs/etc/systemd/system/lnd.service"
mkdir -p "$fx_mask/fs/run/systemd/system"
: > "$fx_mask/fs/run/systemd/system/lnd.service"
run_detect "$fx_mask" --json
assert_json "$CLI_OUT" '[d["lightning"]["units"][0]["file"], d["lightning"]["units"][0]["path"]]' '["masked", "/run/systemd/system/lnd.service"]' \
    "[ln_masked_units] an empty unit file (runtime mask) is masked and hides the packaged unit"
assert_equals "not_detected" "$(conflict_status "$CLI_OUT" multiple_ln_implementations)" "[ln_masked_units] an empty-file mask is not counted"

# Fixtures: installed config selection, the same rule as status, restart and uninstall
fx_amb=$(new_fixture config_ambiguous)
put "$fx_amb/fs/etc/wireguard/tunnelsats-us3.conf" "$(website_config "$COMMENT_KEY_A")"
put "$fx_amb/fs/etc/wireguard/tunnelsats-de2.conf" "$(website_config "$COMMENT_KEY_B")"
run_detect "$fx_amb" --json
assert_json "$CLI_OUT" '[d["config"][k] for k in ("status", "selection", "candidates", "path", "interface")]' \
    '["ambiguous", "ambiguous", ["/etc/wireguard/tunnelsats-de2.conf", "/etc/wireguard/tunnelsats-us3.conf"], null, null]' \
    "[config_ambiguous] two tunnelsats-*.conf without tunnelsatsv2.conf are ambiguous, candidates sorted"
assert_json "$CLI_OUT" '[d["config"][k]["status"] for k in ("endpoint", "vpn_port", "public_key", "public_key_comment", "valid_until")]' \
    '["not_read", "not_read", "not_read", "not_read", "not_read"]' "[config_ambiguous] no facts are read from an arbitrary file"
assert_not_contains "$STUB_CALLS" "wg pubkey" "[config_ambiguous] no key is derived"
run_detect "$fx_amb"
assert_contains "$CLI_OUT" "Selection:        ambiguous (candidates: /etc/wireguard/tunnelsats-de2.conf /etc/wireguard/tunnelsats-us3.conf)" \
    "[config_ambiguous] human output lists the candidates"
rm -f "$fx_amb/fs/etc/wireguard/tunnelsats-de2.conf"
run_detect "$fx_amb" --json
assert_json "$CLI_OUT" '[d["config"][k] for k in ("status", "selection", "path")]' '["ok", "single", "/etc/wireguard/tunnelsats-us3.conf"]' \
    "[config_ambiguous] the only tunnelsats-*.conf is selected"
put "$fx_amb/fs/etc/wireguard/tunnelsatsv2.conf" "$(old_website_config)"
run_detect "$fx_amb" --json
assert_json "$CLI_OUT" '[d["config"][k] for k in ("selection", "path", "candidates")] + [d["config"]["vpn_port"]["value"]]' \
    '["canonical", "/etc/wireguard/tunnelsatsv2.conf", ["/etc/wireguard/tunnelsats-us3.conf", "/etc/wireguard/tunnelsatsv2.conf"], 48049]' \
    "[config_ambiguous] tunnelsatsv2.conf wins and its facts are read"

# Fixtures: table 51820 ownership follows the route guard, which accepts only the interface it
# starts (the selected config), so a route via another installed tunnel is foreign
fx_own=$(new_fixture route_ownership)
put "$fx_own/fs/etc/wireguard/tunnelsatsv2.conf" "$(old_website_config)"
put "$fx_own/fs/etc/wireguard/tunnelsats-de2.conf" "$(website_config "$COMMENT_KEY_B")"
printf 'default dev tunnelsatsv2 scope link \ndefault dev tunnelsats-de2 scope link metric 5 \n' > "$fx_own/kernel/table_51820"
run_detect "$fx_own" --json
assert_equals "detected" "$(conflict_status "$CLI_OUT" table_51820_foreign_routes)" \
    "[route_ownership] a route via another installed tunnel is foreign to the selected tunnelsatsv2"
assert_contains "$(json_eval "$CLI_OUT" 'next(c["detail"] for c in d["conflicts"] if c["id"] == "table_51820_foreign_routes")')" \
    "not via tunnelsatsv2, first: default dev tunnelsats-de2" "[route_ownership] the foreign route and the reference interface are named"
assert_equals "present" "$(art_status "$CLI_OUT" table_51820_route "ip -4 route table 51820")" \
    "[route_ownership] the selected tunnel's own route still counts as TunnelSats"
assert_readonly_calls "[route_ownership]"
rm -f "$fx_own/fs/etc/wireguard/tunnelsatsv2.conf"
put "$fx_own/fs/etc/wireguard/tunnelsats-us3.conf" "$(website_config "$COMMENT_KEY_A")"
run_detect "$fx_own" --json
assert_equals "unknown" "$(conflict_status "$CLI_OUT" table_51820_foreign_routes)" \
    "[route_ownership] with an ambiguous selection the owning interface cannot be decided"
assert_contains "$(json_eval "$CLI_OUT" 'next(c["detail"] for c in d["conflicts"] if c["id"] == "table_51820_foreign_routes")')" \
    "config selection ambiguous" "[route_ownership] the unknown verdict says why"
printf 'blackhole default metric 3 \n' > "$fx_own/kernel/table_51820"
run_detect "$fx_own" --json
assert_equals "not_detected" "$(conflict_status "$CLI_OUT" table_51820_foreign_routes)" \
    "[route_ownership] only the kill-switch blackhole: nothing foreign, even with an ambiguous selection"
rm -f "$fx_own/fs/etc/wireguard/tunnelsats-de2.conf" "$fx_own/fs/etc/wireguard/tunnelsats-us3.conf"
printf 'default dev tunnelsatsv2 scope link \n' > "$fx_own/kernel/table_51820"
run_detect "$fx_own" --json
assert_equals "not_detected" "$(conflict_status "$CLI_OUT" table_51820_foreign_routes)" \
    "[route_ownership] without a config the interface a fresh install creates (tunnelsatsv2) is the reference"
printf 'default dev wg0 scope link \n' > "$fx_own/kernel/table_51820"
run_detect "$fx_own" --json
assert_equals "detected" "$(conflict_status "$CLI_OUT" table_51820_foreign_routes)" \
    "[route_ownership] without a config a route via another interface is foreign"

# Fixtures: the forwarded port is checked as a whole (it used to be cut to its first four or five
# digits, so 100000 became 10000 and 80 looked missing)
for port_case in "100000|null|invalid" "80|80|ok" "65536|null|invalid" "08080|8080|ok" \
    "18446744073709551617|null|invalid" "none|null|invalid"; do
    port_raw="${port_case%%|*}"
    port_rest="${port_case#*|}"
    fx_port=$(new_fixture "port_${port_raw}")
    put "$fx_port/fs/etc/wireguard/tunnelsatsv2.conf" \
        "$(website_config "$COMMENT_KEY_A" | sed "s/^# Port Forwarding: 24556\$/# Port Forwarding: ${port_raw}/")"
    run_detect "$fx_port" --json
    assert_json "$CLI_OUT" 'd["config"]["vpn_port"]' "{\"value\": ${port_rest%%|*}, \"status\": \"${port_rest#*|}\"}" \
        "[port ${port_raw}] the complete value is checked: ${port_rest#*|}"
done

# Fixture: unreadable config file (permission denied)
if [[ "$EUID" -eq 0 ]]; then
    skip "running as root: permission-denied fixtures"
else
    fx_noread=$(make_post_204_fixture unreadable_config)
    chmod 000 "$fx_noread/fs/etc/wireguard/tunnelsatsv2.conf"
    run_detect "$fx_noread" --json
    assert_equals 0 "$CLI_RC" "[unreadable_config] detect --json exits 0"
    assert_json "$CLI_OUT" '[d["config"]["status"], d["config"]["public_key"]["status"], d["config"]["endpoint"]["status"]]' \
        '["permission_denied", "not_read", "not_read"]' "[unreadable_config] config facts are reported as not read"
    assert_json "$CLI_OUT" 'd["install"]["kind"]' legacy_v3_post_204 "[unreadable_config] other artifacts still classify the install"
    assert_json "$CLI_OUT" 'd["unreadable_items"]' 1 "[unreadable_config] the unreadable config is counted"

    fx_nodir=$(make_post_204_fixture unreadable_wireguard_dir)
    chmod 000 "$fx_nodir/fs/etc/wireguard"
    printf '0:\tfrom all lookup local\n32766:\tfrom all lookup main\n' > "$fx_nodir/kernel/ip_rules"
    rm -f "$fx_nodir/kernel/table_51820" "$fx_nodir/kernel/nft_tables"
    : > "$fx_nodir/kernel/wg_links"
    : > "$fx_nodir/kernel/nft_denied"
    run_detect "$fx_nodir" --json
    assert_equals "permission_denied" "$(art_status "$CLI_OUT" route_guard_script /etc/wireguard/tunnelsats-route-guard.sh)" \
        "[unreadable_wireguard_dir] artifacts behind an unreadable directory are permission_denied"
    assert_equals "permission_denied" "$(art_status "$CLI_OUT" wg_config_backup "/etc/wireguard/tunnelsats*.conf.bak.*")" \
        "[unreadable_wireguard_dir] globs in an unreadable directory are permission_denied"
    assert_equals "permission_denied" "$(art_status "$CLI_OUT" nft_table "nft tables")" "[unreadable_wireguard_dir] nft listing without root is permission_denied"
    assert_json "$CLI_OUT" '[d["install"]["kind"], d["install"]["candidates"]]' '["unknown", ["legacy_v3_pre_204", "legacy_v3_post_204"]]' \
        "[unreadable_wireguard_dir] v3 is known but its revision is not: unknown with candidates"
    assert_json "$CLI_OUT" '[d["config"]["status"], d["config"]["selection"], d["config"]["path"]]' '["permission_denied", "permission_denied", null]' \
        "[unreadable_wireguard_dir] config is permission_denied and nothing is selected"

    fx_nounits=$(new_fixture unreadable_unit_dir)
    mkdir -p "$fx_nounits/fs/usr/lib/systemd/system"
    chmod 000 "$fx_nounits/fs/usr/lib/systemd/system"
    echo active > "$fx_nounits/kernel/active_lnd"
    run_detect "$fx_nounits" --json
    assert_json "$CLI_OUT" '[d["lightning"]["units"][1][k] for k in ("file", "path", "active")]' '["permission_denied", null, "inactive"]' \
        "[unreadable_unit_dir] a unit directory that cannot be searched gives permission_denied"
    assert_json "$CLI_OUT" 'next([c["status"], c["detail"]] for c in d["conflicts"] if c["id"] == "multiple_ln_implementations")' \
        '["unknown", "unit file location not readable: lightningd.service, litd.service, lit.service"]' \
        "[unreadable_unit_dir] one running implementation plus an unreadable unit directory is unknown, not not_detected"
fi

# detect on the real host (read-only, no stubs): must always produce one valid document
run_cli bash "$SCRIPT_UNDER_TEST" detect --json
assert_equals 0 "$CLI_RC" "[host] detect --json exits 0 on the test host"
assert_json "$CLI_OUT" '[d["command"], d["ok"]]' '["detect", true]' "[host] detect --json prints one valid document"

# ---------------------------------------------------------------------------
# GROUP 5: Config metadata parsers and config discovery
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 5: Parsers ---"

parse_field() {
    bash -c 'source "$1"; parse_config_metadata "$2" "$3"' _ "$SCRIPT_UNDER_TEST" "$1" "$2"
}

cfg_old="$TMP_ROOT/old.conf"
old_website_config > "$cfg_old"
assert_equals "2025-06-29T08:18:33.839Z" "$(parse_field "$cfg_old" expiry)" "Old '#ValidUntil (UTC time) =' expiry keeps the full timestamp"
assert_equals "$COMMENT_KEY_A" "$(parse_field "$cfg_old" pubkey)" "Old '#myPubKey =' comment is parsed"
assert_equals "48049" "$(parse_field "$cfg_old" port)" "Old '#VPNPort =' port is parsed"

cfg_web="$TMP_ROOT/web.conf"
website_config "$COMMENT_KEY_B" > "$cfg_web"
assert_equals "2026-11-07T08:18:33.839Z" "$(parse_field "$cfg_web" expiry)" "Website '# Valid Until:' expiry keeps the full timestamp"
assert_equals "$COMMENT_KEY_B" "$(parse_field "$cfg_web" pubkey)" "Website '# myPubKey:' comment is parsed"
assert_equals "24556" "$(parse_field "$cfg_web" port)" "Website '# Port Forwarding:' port is parsed"

cfg_startos="$TMP_ROOT/startos.conf"
printf '[Interface]\r\nPrivateKey = %s\r\n# 7-Day Grace Window Active Until: 2026-01-01T00:00:00.000Z\r\n# Valid Until: 2026-10-02T21:18:07Z\r\n# VPNPort: 31337\r\n' "$PRIV_KEY" > "$cfg_startos"
assert_equals "2026-10-02T21:18:07Z" "$(parse_field "$cfg_startos" expiry)" "StartOS expiry with CRLF line endings, grace window line ignored"
assert_equals "31337" "$(parse_field "$cfg_startos" port)" "StartOS '# VPNPort:' port is parsed"
assert_equals "" "$(parse_field "$cfg_startos" pubkey)" "Missing myPubKey comment gives an empty value"

# The port parser returns the complete value as written, never cut to four or five digits
port_parse_case() {  # $1 = port comment line; prints what parse_config_metadata returns
    printf '[Interface]\nPrivateKey = %s\n%s\n' "$PRIV_KEY" "$1" > "$TMP_ROOT/port.conf"
    parse_field "$TMP_ROOT/port.conf" port
}
assert_equals "100000" "$(port_parse_case "# Port Forwarding: 100000")" "Port parser keeps all digits of 100000 (was 10000)"
assert_equals "80" "$(port_parse_case "#VPNPort = 80")" "Port parser returns a two-digit port (was empty)"
assert_equals "24556" "$(port_parse_case "# Port Forwarding: 24556 (tcp)")" "Port parser ignores text after the number"
assert_equals "none" "$(port_parse_case "# Port Forwarding: none")" "Port parser returns a non-numeric value as written, so it is reported as invalid"
assert_equals "" "$(port_parse_case "# no port comment")" "Port parser returns nothing without a port comment"

# ts_config_vpn_port: the validated port the installer uses (Docker DNAT rule, post-install
# instructions, status). Invalid values are never truncated or used, and they are reported.
installer_port_case() {  # $1 = port comment line; sets VP_OUT (stdout) and VP_ERR (stderr)
    printf '[Interface]\nPrivateKey = %s\n%s\n' "$PRIV_KEY" "$1" > "$TMP_ROOT/port.conf"
    VP_OUT=$(bash -c 'source "$1"; ts_config_vpn_port "$2"' _ "$SCRIPT_UNDER_TEST" "$TMP_ROOT/port.conf" 2>"$TMP_ROOT/port.err") || true
    VP_ERR=$(cat "$TMP_ROOT/port.err")
}
installer_port_case "# Port Forwarding: 24556"
assert_equals "24556|" "${VP_OUT}|${VP_ERR}" "Installer port: a valid port is used as is, without a warning"
installer_port_case "#VPNPort = 80"
assert_equals "80|" "${VP_OUT}|${VP_ERR}" "Installer port: a two-digit port is used (it fell back to 9735 before)"
installer_port_case "# Port Forwarding: 08080"
assert_equals "8080" "$VP_OUT" "Installer port: leading zeros are normalised"
installer_port_case ""
assert_equals "|" "${VP_OUT}|${VP_ERR}" "Installer port: no port comment gives nothing and no warning (callers keep their fallback)"
for bad_port in 100000 65536 0 18446744073709551617 none; do
    installer_port_case "# Port Forwarding: ${bad_port}"
    assert_equals "" "$VP_OUT" "Installer port: ${bad_port} is not used (no truncation, no wrap-around)"
    assert_contains "$VP_ERR" "Ignoring invalid forwarded port '${bad_port}' in port.conf (expected 1-65535)" \
        "Installer port: ${bad_port} is reported as invalid"
done

disc_dir="$TMP_ROOT/discovery"
mkdir -p "$disc_dir"
for f in nftables.conf sysctl.conf resolv.conf wg-office.conf; do
    printf '[Interface]\n' > "$disc_dir/$f"
done
assert_equals "$disc_dir/wg-office.conf" "$(bash -c 'source "$1"; find_config_files "$2"' _ "$SCRIPT_UNDER_TEST" "$disc_dir")" \
    "Config discovery excludes nftables.conf, sysctl.conf and resolv.conf"

# ---------------------------------------------------------------------------
# GROUP 6: JSON string escaping
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 6: JSON Escaping ---"

# Escapes $1 with ts_json_escape and checks with python3 that the result is valid JSON string content
# that decodes to the input: valid UTF-8 characters unchanged, every invalid byte replaced by U+FFFD.
# $3 = "c" forces the fallback without a UTF-8 locale (TS_JSON_LOCALE=C): pure ASCII output, every
# non-ASCII byte replaced by U+FFFD.
check_escape() {
    local raw="$1" desc="$2" mode="${3:-utf8}" locale=""
    if [[ "$mode" == "c" ]]; then
        locale="C"
    fi
    printf '%s' "$raw" > "$TMP_ROOT/escape.raw"
    TS_JSON_LOCALE="$locale" bash -c 'source "$1"; ts_json_escape "$2"; printf "%s" "$TS_JSON_ESCAPED"' _ "$SCRIPT_UNDER_TEST" "$raw" > "$TMP_ROOT/escape.out"
    if python3 - "$TMP_ROOT/escape.raw" "$TMP_ROOT/escape.out" "$mode" <<'PY'
import json, sys
raw = open(sys.argv[1], "rb").read()
out = open(sys.argv[2], "rb").read()
mode = sys.argv[3]
def per_byte_utf8(data):
    chars, i = [], 0
    while i < len(data):
        for n in (1, 2, 3, 4):
            try:
                ch = data[i:i + n].decode("utf-8")
            except UnicodeDecodeError:
                continue
            if len(ch) == 1:
                chars.append(ch)
                i += n
                break
        else:
            chars.append("\ufffd")
            i += 1
    return "".join(chars)
if mode == "c":
    out.decode("ascii")
    expected = "".join(chr(b) if b < 0x80 else "\ufffd" for b in raw)
else:
    expected = per_byte_utf8(raw)
value = json.loads(b'"' + out + b'"')
sys.exit(0 if value == expected else 1)
PY
    then
        pass "$desc"
    else
        fail "$desc (escaped as: $(cat "$TMP_ROOT/escape.out"))"
    fi
}

check_escape "plain text 123" "Plain text"
check_escape 'quote " and backslash \ and slash /' "Quote and backslash"
check_escape $'line1\nline2\r\ttab\bback\fform' "Newline, carriage return, tab, backspace, form feed"
check_escape $'\x01\x02\x1b[31mred\x1b[0m\x1f\x7f' "Other control characters and DEL"
check_escape '","ok":true,"injected":"' "JSON injection attempt stays inside the string"
check_escape '\u0000 literal' "A literal backslash-u sequence"
check_escape $'caf\xc3\xa9 \xff\xfe' "Valid UTF-8 passes through unchanged, invalid bytes become U+FFFD"
check_escape $'emoji \xf0\x9f\x98\x80, check \xe2\x9c\x93, quote "' "Three- and four-byte characters pass through next to escapes"
check_escape $'caf\xc3\xa9 \xff' "Without a UTF-8 locale every non-ASCII byte becomes U+FFFD (pure ASCII)" c
check_escape $'big \xf4\x90\x80\x80 end' "A four-byte sequence above U+10FFFF (one glibc character) becomes U+FFFD per byte"
check_escape $'sur \xed\xa0\x80 end' "An encoded surrogate becomes U+FFFD per byte"
check_escape $'ovl \xc0\x80 \xe0\x80\xaf end' "Overlong forms become U+FFFD per byte"
check_escape "" "Empty string"

hostile_option=$'--x"\\\n\x01'
run_cli bash "$SCRIPT_UNDER_TEST" --json version "$hostile_option"
assert_equals 2 "$CLI_RC" "Hostile unknown option exits 2"
printf '%s' "$hostile_option" > "$TMP_ROOT/hostile.raw"
if printf '%s' "$CLI_OUT" | python3 -c '
import json, sys
doc = json.loads(sys.stdin.read())
raw = open(sys.argv[1], "rb").read().decode("ascii")
sys.exit(0 if doc["errors"][0]["message"] == "Unknown option: " + raw else 1)
' "$TMP_ROOT/hostile.raw"; then
    pass "Hostile option text round-trips through the error envelope"
else
    fail "Hostile option text round-trips through the error envelope (got: $CLI_OUT)"
fi
assert_not_contains "$CLI_ERR" $'\x01' "Control characters from the command line are not echoed to the terminal"

echo ""
echo "--------------------------------"
echo "Passed: $pass_count"
echo "Failed: $fail_count"
echo "Skipped: $skip_count"
echo "--------------------------------"

if [[ "$fail_count" -gt 0 ]]; then
    exit 1
fi
