#!/bin/bash
# Unit tests for managed mode (install --managed baremetal|raspiblitz, verify, uninstall --managed):
# the renderers, the inventory, kill switch arm/read-back/disarm/remove, the emergency block, the
# verifier, the node config detector, the verify verdicts, the CLI options, detect's view of a
# managed install and the RaspiBlitz profile. Runs unprivileged and offline and never touches the
# host: the production functions run against a fixture tree (TS_FS_ROOT) with stateful stubs for ip,
# nft, unshare, systemctl, systemd-run, getent, curl, wg and perl. The datagram probe's perl helper
# also runs for real inside a throwaway network namespace (unshare -rn) where the system allows one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/tunnelsats.sh"

pass_count=0
fail_count=0

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

pass() {
    echo "PASS: $1"
    pass_count=$((pass_count + 1))
}

fail() {
    echo "FAIL: $1"
    fail_count=$((fail_count + 1))
}

assert_equals() {
    if [[ "$1" == "$2" ]]; then
        pass "$3"
    else
        fail "$3 (expected '$1', got '$2')"
    fi
}

assert_contains() {
    if [[ "$1" == *"$2"* ]]; then
        pass "$3"
    else
        fail "$3 (missing '$2')"
    fi
}

assert_not_contains() {
    if [[ "$1" != *"$2"* ]]; then
        pass "$3"
    else
        fail "$3 (unexpected '$2')"
    fi
}

json_eval() {
    printf '%s' "$1" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
v = eval(sys.argv[1])
print(v if isinstance(v, str) else json.dumps(v))
' "$2"
}

assert_json() {
    local actual
    actual=$(json_eval "$1" "$2" 2>&1) || actual="<not one valid JSON document>"
    assert_equals "$3" "$actual" "$4"
}

# ---------------------------------------------------------------------------
# Stateful stubs. STUB_STATE holds the simulated kernel: rules4/rules6, routes4/routes6 (table
# 51820), nft_table (the live inet tunnelsats table), links, and a call log.
# ---------------------------------------------------------------------------
STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/ip" <<'EOF'
#!/bin/bash
# Stub for ip: policy rules and table 51820 routes live in files below STUB_STATE
s="${STUB_STATE:?}"
printf 'ip %s\n' "$*" >> "$s/calls"
fam=4
case "${1:-}" in
    -4) fam=4; shift ;;
    -6) fam=6; shift ;;
    -o)
        if [[ "$*" == "-o link show type wireguard" ]]; then
            if [[ -f "$s/link_tunnelsatsv2" ]]; then echo "5: tunnelsatsv2: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420"; fi
            exit 0
        fi
        ;;
esac
if [[ -f "$s/fail_ip" ]] && grep -qxF "$*" "$s/fail_ip"; then
    echo "RTNETLINK answers: Operation not permitted" >&2
    exit 2
fi
obj="${1:-}"
verb="${2:-}"
shift 2 || true
case "$obj:$verb" in
    rule:show)
        printf '0:\tfrom all lookup local\n'
        if [[ -f "$s/rules${fam}" ]]; then sort -n -s -t: -k1,1 "$s/rules${fam}"; fi
        printf '32766:\tfrom all lookup main\n'
        if [[ "$fam" == 4 ]]; then printf '32767:\tfrom all lookup default\n'; fi
        ;;
    rule:add|rule:del)
        prio=""; sel=()
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == "priority" ]]; then prio="$2"; shift 2; continue; fi
            sel+=("$1"); shift
        done
        line="${sel[*]}"
        if [[ "$line" != from* ]]; then line="from all ${line}"; fi
        entry="${prio}:"$'\t'"${line}"
        touch "$s/rules${fam}"
        if [[ "$verb" == "add" ]]; then
            if grep -qxF "$entry" "$s/rules${fam}"; then echo "RTNETLINK answers: File exists" >&2; exit 2; fi
            printf '%s\n' "$entry" >> "$s/rules${fam}"
        else
            if ! grep -qxF "$entry" "$s/rules${fam}"; then echo "RTNETLINK answers: No such file or directory" >&2; exit 2; fi
            awk -v e="$entry" '$0 == e && !done { done = 1; next } { print }' "$s/rules${fam}" > "$s/rules.tmp"
            mv "$s/rules.tmp" "$s/rules${fam}"
        fi
        ;;
    route:show)
        table="${!#}"
        if [[ "$table" == "52" ]]; then
            if [[ -f "$s/table52" ]]; then cat "$s/table52"; fi
            exit 0
        fi
        if [[ ! -f "$s/routes${fam}" ]]; then echo "Error: ipv4: FIB table does not exist." >&2; exit 2; fi
        cat "$s/routes${fam}"
        ;;
    route:add|route:del)
        if [[ "$fam" == 4 ]]; then r="blackhole default metric 4294967295 "; else r="blackhole default dev lo metric 4294967295 pref medium"; fi
        touch "$s/routes${fam}"
        if [[ "$verb" == "add" ]]; then
            if grep -qxF "$r" "$s/routes${fam}"; then echo "RTNETLINK answers: File exists" >&2; exit 2; fi
            printf '%s\n' "$r" >> "$s/routes${fam}"
        else
            if ! grep -qxF "$r" "$s/routes${fam}"; then echo "RTNETLINK answers: No such process" >&2; exit 2; fi
            awk -v e="$r" '$0 == e && !done { done = 1; next } { print }' "$s/routes${fam}" > "$s/routes.tmp"
            mv "$s/routes.tmp" "$s/routes${fam}"
        fi
        ;;
    route:get)
        echo "${1} via 192.0.2.1 dev eth0 src 192.0.2.10 uid 0"
        ;;
    link:show)
        if [[ -f "$s/link_${2:-}" ]]; then echo "5: ${2}: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420"; else exit 1; fi
        ;;
    *) echo "ip stub: unexpected call: $obj $verb $*" >&2; exit 1 ;;
esac
exit 0
EOF

cat > "$STUB_BIN/nft" <<'EOF'
#!/bin/bash
# Stub for nft: "loads" a ruleset by storing its table body; inside the unshare stub (STUB_NETNS)
# it uses a separate table file, like a throwaway network namespace
s="${STUB_STATE:?}"
printf 'nft %s%s\n' "${STUB_NETNS:+[netns] }" "$*" >> "$s/calls"
table="$s/nft_table${STUB_NETNS:+.ns}"
case "$*" in
    "-f "*)
        f="${2:-}"
        if [[ -f "$s/nft_refuse" ]] && [[ -z "${STUB_NETNS:-}" ]]; then
            echo "Error: Could not process rule: Operation not supported" >&2
            exit 1
        fi
        if [[ -f "$s/nft_refuse_all" ]]; then
            echo "Error: Could not process rule: Operation not supported" >&2
            exit 1
        fi
        awk 'f { print } /^table inet tunnelsats \{$/ { f = 1; print }' "$f" | sed 's/ and 0x00ffffff or / \& 0x01ffffff | /g' > "$table.tmp"
        mv "$table.tmp" "$table"
        ;;
    "list table inet tunnelsats")
        if [[ ! -s "$table" ]]; then echo "Error: No such file or directory" >&2; exit 1; fi
        cat "$table"
        ;;
    "delete table inet tunnelsats")
        if [[ ! -s "$table" ]]; then echo "Error: No such file or directory" >&2; exit 1; fi
        rm -f "$table"
        ;;
    "list tables")
        if [[ -s "$table" ]]; then echo "table inet tunnelsats"; fi
        ;;
    "list table ip tunnelsats_failclosed") exit 1 ;;
    "delete table ip tunnelsats_failclosed") exit 1 ;;
    "list table ip "*|"list table inet "*)
        # A legacy kill switch table (named after the tunnel interface) when the fixture has one
        if [[ -f "$s/legacy_table_${3}_${4}" ]]; then echo "table ${3} ${4} {"; echo "}"; exit 0; fi
        exit 1
        ;;
    *) echo "nft stub: unexpected call: $*" >&2; exit 1 ;;
esac
exit 0
EOF

cat > "$STUB_BIN/unshare" <<'EOF'
#!/bin/bash
# Stub for unshare --net: runs the command with STUB_NETNS set (the nft stub then uses its
# namespace table) and removes that table afterwards, like a namespace that disappears
s="${STUB_STATE:?}"
while [[ $# -gt 0 ]] && [[ "$1" != "--" ]]; do shift; done
shift
rm -f "$s/nft_table.ns"
STUB_NETNS=1 "$@"
rc=$?
rm -f "$s/nft_table.ns"
exit "$rc"
EOF

cat > "$STUB_BIN/systemctl" <<'EOF'
#!/bin/bash
# Stub for systemctl: properties come from files unit_<unit>_<Property> below STUB_STATE. With a
# file stateful_units, start and stop set the unit's ActiveState; fail_systemctl_<verb>_<unit> makes
# that call fail; with fail_systemctl_show, systemd does not answer show.
s="${STUB_STATE:?}"
printf 'systemctl %s\n' "$*" >> "$s/calls"
case "${1:-}" in
    show)
        if [[ -f "$s/fail_systemctl_show" ]]; then exit 1; fi
        prop="$3"; unit="${!#}"
        if [[ -f "$s/unit_${unit}_${prop}" ]]; then
            cat "$s/unit_${unit}_${prop}"
        elif [[ "$prop" == "LoadState" ]]; then
            echo "not-found"
        elif [[ "$prop" == "ActiveState" ]]; then
            echo "inactive"
        fi
        ;;
    start|stop|restart|enable|disable|daemon-reload|reset-failed)
        if [[ -f "$s/fail_systemctl_${1}_${!#}" ]]; then exit 1; fi
        if [[ -f "$s/stateful_units" ]]; then
            case "$1" in
                stop) echo "inactive" > "$s/unit_${!#}_ActiveState" ;;
                start|restart) echo "active" > "$s/unit_${!#}_ActiveState" ;;
            esac
        fi
        ;;
    is-active) exit 3 ;;
    *) echo "systemctl stub: unexpected call: $*" >&2; exit 1 ;;
esac
exit 0
EOF

cat > "$STUB_BIN/getent" <<'EOF'
#!/bin/bash
s="${STUB_STATE:?}"
case "$1:$2" in
    passwd:bitcoin|passwd:1001) echo "bitcoin:x:1001:1001::${STUB_HOME:-/home/bitcoin}:/bin/bash" ;;
    passwd:root|passwd:0) echo "root:x:0:0:root:/root:/bin/bash" ;;
    ahostsv4:*)
        if [[ -f "$s/resolve_$2" ]]; then echo "$(cat "$s/resolve_$2") STREAM $2"; else exit 2; fi
        ;;
    ahostsv6:*)
        if [[ -f "$s/resolve6_$2" ]]; then cat "$s/resolve6_$2"; else exit 2; fi
        ;;
    *) exit 2 ;;
esac
EOF

cat > "$STUB_BIN/systemd-run" <<'EOF'
#!/bin/bash
# Stub for systemd-run: prints the probe answers prepared in probe_<mode> files (probe_send4,
# probe_send6 for the datagram probes)
s="${STUB_STATE:?}"
printf 'systemd-run %s\n' "$*" >> "$s/calls"
while [[ $# -gt 0 ]] && [[ "$1" != "managed-probe" ]]; do shift; done
mode="${2:-}"
if [[ "$mode" == "send" ]]; then mode="send${3:-}"; fi
if [[ -f "$s/probe_${mode}" ]]; then cat "$s/probe_${mode}"; exit 0; fi
exit 1
EOF

cat > "$STUB_BIN/curl" <<'EOF'
#!/bin/bash
# Stub for curl: prints curl_out (the write-out) and exits with curl_rc (default 7)
s="${STUB_STATE:?}"
printf 'curl %s\n' "$*" >> "$s/calls"
if [[ -f "$s/curl_out" ]]; then cat "$s/curl_out"; fi
exit "$(cat "$s/curl_rc" 2>/dev/null || echo 7)"
EOF
chmod +x "$STUB_BIN"/*

# Creates a fresh fixture: the TS_FS_ROOT tree (fs/) and the stub state (state/). Prints its path.
new_fixture() {
    local fx="$TMP_ROOT/fx/$1"
    rm -rf "$fx"
    mkdir -p "$fx/fs/sys/fs/cgroup/tunnelsats.slice" "$fx/fs/proc/sys/kernel/random" "$fx/fs/proc/net" \
        "$fx/fs/run/systemd/system" "$fx/fs/etc/systemd/system" "$fx/fs/etc/wireguard" "$fx/fs/usr/local/sbin" "$fx/state"
    echo "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0" > "$fx/fs/proc/sys/kernel/random/boot_id"
    : > "$fx/fs/proc/net/if_inet6"
    : > "$fx/fs/sys/fs/cgroup/cgroup.controllers"
    printf 'cgroup2 /sys/fs/cgroup cgroup2 rw,nosuid,nodev,noexec,relatime 0 0\n' > "$fx/fs/proc/mounts"
    : > "$fx/state/calls"
    echo "$fx"
}

# Runs snippet $2 in a child bash against fixture $1 with the production script sourced and the
# stubs first in PATH. Sets SN_RC and SN_OUT (stdout and stderr).
run_snippet() {
    local fx="$1" snippet="$2"
    set +e
    SN_OUT=$(cd "$fx" && PATH="$STUB_BIN:$PATH" STUB_STATE="$fx/state" TS_FS_ROOT="$fx/fs" WG_DIR="$fx/fs/etc/wireguard" \
        NFT_BIN="$STUB_BIN/nft" IP_BIN="$STUB_BIN/ip" SYSTEMCTL_BIN="$STUB_BIN/systemctl" \
        SYSTEMD_RUN_BIN="$STUB_BIN/systemd-run" GETENT_BIN="$STUB_BIN/getent" CURL_BIN="$STUB_BIN/curl" \
        UNSHARE_BIN="$STUB_BIN/unshare" SCRIPT_UNDER_TEST="$SCRIPT_UNDER_TEST" TS_M_STOP_WAIT=0 \
        bash -c 'source "$SCRIPT_UNDER_TEST"
ts_m_expected_owner() { id -u; }
ts_m_require_root() { :; }
'"$snippet" 2>&1)
    SN_RC=$?
    set -e
}

echo "=== Running Managed Dataplane Tests ==="

# ---------------------------------------------------------------------------
# GROUP 1: Renderers
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 1: Renderers ---"

fx=$(new_fixture render)
run_snippet "$fx" 'ts_m_render_ruleset'
expected_ruleset=$(cat <<'EOF'
add table inet tunnelsats
delete table inet tunnelsats
table inet tunnelsats {
	set lan4 {
		type ipv4_addr
		flags interval
		elements = { 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 }
	}
	set lan6 {
		type ipv6_addr
		flags interval
		elements = { ::1/128, fc00::/7, fe80::/10 }
	}
	chain pre {
		type filter hook prerouting priority mangle; policy accept;
		iifname "tunnelsatsv2" ct state new ct mark set ct mark and 0x00ffffff or 0x01000000
		iifname "tunnelsatsv2" ct mark and 0xff000000 == 0x01000000 meta mark set meta mark and 0x00ffffff or 0x01000000
	}
	chain out {
		type route hook output priority mangle; policy accept;
		meta mark and 0xff000000 == 0x02000000 return
		ct state new socket cgroupv2 level 1 "tunnelsats.slice" fib daddr type != local ip daddr != @lan4 ct mark set ct mark and 0x00ffffff or 0x01000000
		socket cgroupv2 level 1 "tunnelsats.slice" fib daddr type != local ip daddr != @lan4 meta mark set meta mark and 0x00ffffff or 0x01000000
		ct mark and 0xff000000 == 0x01000000 meta mark set meta mark and 0x00ffffff or 0x01000000
	}
	chain out6 {
		type filter hook output priority filter; policy accept;
		socket cgroupv2 level 1 "tunnelsats.slice" ip6 daddr != @lan6 counter drop
	}
	chain kill {
		type filter hook postrouting priority filter; policy accept;
		meta mark and 0xff000000 == 0x01000000 oifname != "tunnelsatsv2" fib daddr type != local ip daddr != @lan4 counter drop
		ct mark and 0xff000000 == 0x01000000 oifname != "tunnelsatsv2" fib daddr type != local ip daddr != @lan4 counter drop
	}
	chain nat {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "tunnelsatsv2" meta mark and 0xff000000 == 0x01000000 masquerade
	}
	chain in {
		type filter hook input priority filter - 1; policy accept;
		iifname "tunnelsatsv2" ct state established,related accept
		iifname "tunnelsatsv2" tcp dport 9735 accept
		iifname "tunnelsatsv2" counter drop
	}
}
EOF
)
assert_equals "$expected_ruleset" "$SN_OUT" "Ruleset: the corrected design as one transaction (add, delete, define)"

run_snippet "$fx" 'ts_m_render_ruleset "system.slice" 1 | grep -c "socket cgroupv2 level 1 \"system.slice\""'
assert_equals "3" "$SN_OUT" "Ruleset: the probe variant references the given cgroup in all three slice rules"
run_snippet "$fx" 'ts_m_render_ruleset "bad\"slice" 1'
assert_equals "1" "$SN_RC" "Ruleset: a cgroup path with a quote is refused"

run_snippet "$fx" 'ts_m_render_killswitch_unit lnd.service 1001'
assert_contains "$SN_OUT" "Type=oneshot" "Kill switch unit: oneshot"
assert_contains "$SN_OUT" "RemainAfterExit=yes" "Kill switch unit: RemainAfterExit"
assert_contains "$SN_OUT" "Slice=tunnelsats.slice" "Kill switch unit: runs inside the slice and keeps it active"
assert_contains "$SN_OUT" "After=nftables.service" "Kill switch unit: after nftables.service"
assert_contains "$SN_OUT" "Before=lnd.service wg-quick@tunnelsatsv2.service" "Kill switch unit: before Lightning and the tunnel"
assert_contains "$SN_OUT" $'\nExecStart=/usr/local/sbin/tunnelsats managed-arm --fallback-uid 1001\n' \
    "Kill switch unit: arms through the installed copy, carrying the Lightning uid for a damaged install record"
assert_contains "$SN_OUT" "ExecStop=/usr/local/sbin/tunnelsats managed-disarm" "Kill switch unit: stopping only disarms"
assert_contains "$SN_OUT" "WantedBy=multi-user.target" "Kill switch unit: enabled for multi-user.target"
run_snippet "$fx" 'ts_m_render_killswitch_unit lnd.service 0 | grep "^ExecStart="'
assert_equals "ExecStart=/usr/local/sbin/tunnelsats managed-arm" "$SN_OUT" "Kill switch unit: an invalid uid is never rendered"

run_snippet "$fx" 'ts_m_render_ln_dropin'
assert_contains "$SN_OUT" "Slice=tunnelsats.slice" "Lightning drop-in: Slice="
assert_contains "$SN_OUT" "Requires=tunnelsats-killswitch.service" "Lightning drop-in: requires the kill switch (starts only when it succeeded)"
assert_not_contains "$SN_OUT" "Wants=" "Lightning drop-in: Wants= alone would let Lightning start after a failed kill switch"
assert_contains "$SN_OUT" "After=tunnelsats-killswitch.service" "Lightning drop-in: ordered after the kill switch"
assert_not_contains "$SN_OUT" "wg-quick" "Lightning drop-in: not ordered after the tunnel"

run_snippet "$fx" 'ts_m_render_wg_dropin'
assert_contains "$SN_OUT" "Restart=on-failure" "wg-quick drop-in: restarts on failure"
assert_contains "$SN_OUT" "RestartSec=30" "wg-quick drop-in: every 30 s"
assert_contains "$SN_OUT" "Environment=WG_ENDPOINT_RESOLUTION_RETRIES=5" "wg-quick drop-in: finite endpoint resolution retries"

run_snippet "$fx" 'ts_m_render_verifier_timer'
assert_contains "$SN_OUT" "OnBootSec=30s" "Verifier timer: 30 s after boot"
assert_contains "$SN_OUT" "OnUnitActiveSec=30s" "Verifier timer: every 30 s"
assert_contains "$SN_OUT" "AccuracySec=1s" "Verifier timer: 1 s accuracy (the default of 1 min would stretch the interval)"

cat > "$fx/sub.conf" <<'EOF'
[Interface]
# Port Forwarding: 24556
# Valid Until: 2026-11-07T08:18:33.839Z
PrivateKey = dHVubmVsc2F0cy10ZXN0LXByaXZhdGUta2V5LTAwMDE=
Address = 10.9.0.42/32
DNS = 8.8.8.8
 dns=1.1.1.1
[Peer]
PublicKey = dHVubmVsc2F0cy10ZXN0LXNlcnZlci1rZXktMDAwMDE=
Endpoint = de2.tunnelsats.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
run_snippet "$fx" 'ts_m_render_wg_config "$PWD/sub.conf"'
assert_not_contains "${SN_OUT,,}" "dns" "Tunnel config: DNS lines are dropped"
assert_contains "$SN_OUT" "Table = off" "Tunnel config: Table = off"
assert_contains "$SN_OUT" "FwMark = 0x2000000" "Tunnel config: FwMark = 0x2000000"
assert_contains "$SN_OUT" "PostUp = ip route replace default dev %i table 51820" "Tunnel config: PostUp adds the tunnel route"
assert_contains "$SN_OUT" "PreDown = ip route del default dev %i table 51820 || true" "Tunnel config: PreDown removes it while the interface exists"
assert_not_contains "$SN_OUT" "PostDown" "Tunnel config: no PostDown (the route is gone with the interface by then)"
assert_contains "$SN_OUT" "PostUp = sysctl -q -w net.ipv4.conf.%i.src_valid_mark=1" "Tunnel config: per-interface src_valid_mark only"
assert_not_contains "$SN_OUT" "rp_filter" "Tunnel config: no rp_filter sysctl"
assert_not_contains "$SN_OUT" "disable_ipv6" "Tunnel config: no IPv6 sysctl"
assert_not_contains "$SN_OUT" "ping" "Tunnel config: no ping in PostUp"
assert_not_contains "$SN_OUT" "nft" "Tunnel config: no kill switch in wg-quick"
assert_contains "$SN_OUT" "# Port Forwarding: 24556" "Tunnel config: subscription comments are kept"

run_snippet "$fx" 'ts_m_render_attestation 0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0 baremetal lnd lnd.service 4711 0 2026-10-12T06:00:00Z'
assert_json "$SN_OUT" '[d["schema"], d["armed"], d["profile"], d["impl"], d["unit"], d["slice"], d["slice_cgroup_id"], d["table"], d["uid_backstop"]]' \
    '[1, true, "baremetal", "lnd", "lnd.service", "tunnelsats.slice", 4711, "inet tunnelsats", false]' "Attestation: schema 1 with the documented fields"
assert_json "$SN_OUT" 'sorted(d.keys())' '["armed", "boot_id", "impl", "profile", "schema", "slice", "slice_cgroup_id", "table", "uid_backstop", "unit", "version", "written_at"]' \
    "Attestation: exactly the documented keys"

# ---------------------------------------------------------------------------
# GROUP 2: Inventory
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 2: Inventory ---"

fx=$(new_fixture inventory)
mkdir -p "$fx/fs/etc/tunnelsats"
run_snippet "$fx" '
TS_M_INV_STATE=installed TS_M_INV_PROFILE=baremetal TS_M_INV_IMPL=lnd TS_M_INV_UNIT=lnd.service TS_M_INV_USER=bitcoin TS_M_INV_UID=1001 TS_M_INV_BACKSTOP=1
TS_M_FILES=(/usr/local/sbin/tunnelsats /etc/systemd/system/tunnelsats.slice)
TS_M_FILE_SHA=(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
TS_M_CREATED_DIRS=(/etc/tunnelsats /etc/systemd/system/lnd.service.d)
TS_M_ENABLED_UNITS=(tunnelsats-killswitch.service tunnelsats-verifier.timer)
ts_m_inventory_write
stat -c %a "$TS_FS_ROOT/etc/tunnelsats/managed.json"
TS_M_INV_STATE="" TS_M_INV_PROFILE="" TS_M_FILES=() TS_M_CREATED_DIRS=() TS_M_ENABLED_UNITS=()
ts_m_inventory_read
echo "$TS_M_INV_STATE|$TS_M_INV_PROFILE|$TS_M_INV_IMPL|$TS_M_INV_UNIT|$TS_M_INV_USER|$TS_M_INV_UID|$TS_M_INV_BACKSTOP"
echo "${TS_M_FILES[*]}|${TS_M_FILE_SHA[1]:0:4}|${TS_M_CREATED_DIRS[*]}|${TS_M_ENABLED_UNITS[*]}"
'
assert_equals "0" "$SN_RC" "Inventory: write and read back"
assert_contains "$SN_OUT" "600" "Inventory: root-only mode 0600"
assert_contains "$SN_OUT" "installed|baremetal|lnd|lnd.service|bitcoin|1001|1" "Inventory: state and scalar values round-trip"
assert_contains "$SN_OUT" "/usr/local/sbin/tunnelsats /etc/systemd/system/tunnelsats.slice|bbbb|/etc/tunnelsats /etc/systemd/system/lnd.service.d|tunnelsats-killswitch.service tunnelsats-verifier.timer" \
    "Inventory: files with sha256, created directories and enabled units round-trip"
inv_doc=$(cat "$fx/fs/etc/tunnelsats/managed.json")
assert_json "$inv_doc" '[d["schema"], d["state"], d["node_config"], len(d["files"])]' '[1, "installed", [], 2]' "Inventory: valid JSON, node_config recorded as an empty list"

# Write-ahead: while installing, a planned file that is not written yet has sha256 null
run_snippet "$fx" '
TS_M_INV_STATE=installing TS_M_INV_PROFILE=baremetal TS_M_INV_IMPL=lnd TS_M_INV_UNIT=lnd.service TS_M_INV_USER=bitcoin TS_M_INV_UID=1001 TS_M_INV_BACKSTOP=0
TS_M_FILES=(/usr/local/sbin/tunnelsats /etc/systemd/system/tunnelsats.slice)
TS_M_FILE_SHA=(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "")
TS_M_CREATED_DIRS=() TS_M_ENABLED_UNITS=()
ts_m_inventory_write
TS_M_FILES=() TS_M_FILE_SHA=()
ts_m_inventory_read || { echo "refused: $TS_M_ERROR"; exit 1; }
echo "$TS_M_INV_STATE|${TS_M_FILES[*]}|${#TS_M_FILE_SHA[0]}|${#TS_M_FILE_SHA[1]}"'
assert_contains "$SN_OUT" "installing|/usr/local/sbin/tunnelsats /etc/systemd/system/tunnelsats.slice|64|0" "Inventory: state installing with a planned file (sha256 null) reads back"
assert_json "$(cat "$fx/fs/etc/tunnelsats/managed.json")" '[f["sha256"] for f in d["files"]][1]' 'null' "Inventory: a planned file is written with sha256 null"
assert_equals "installing" "$(cd "$fx" && TS_FS_ROOT="$fx/fs" bash -c 'source "$1"; ts_m_inventory_state' _ "$SCRIPT_UNDER_TEST")" "Inventory: ts_m_inventory_state reads the state"

cp "$fx/fs/etc/tunnelsats/managed.json" "$fx/state/inventory.ok"
sed -i 's/"state": "installing"/"state": "upgrading"/' "$fx/fs/etc/tunnelsats/managed.json"
run_snippet "$fx" 'ts_m_inventory_read || { echo "refused: $TS_M_ERROR"; exit 1; }'
assert_contains "$SN_OUT" "unknown state (upgrading)" "Inventory: an unknown state is refused"
cp "$fx/state/inventory.ok" "$fx/fs/etc/tunnelsats/managed.json"
sed -i 's|"sha256":null|"sha256":"xyz"|' "$fx/fs/etc/tunnelsats/managed.json"
run_snippet "$fx" 'ts_m_inventory_read || { echo "refused: $TS_M_ERROR"; exit 1; }'
assert_contains "$SN_OUT" "unexpected file entry" "Inventory: an entry it does not recognise is refused, never skipped"

cp "$fx/state/inventory.ok" "$fx/fs/etc/tunnelsats/managed.json"
sed -i 's|/etc/systemd/system/tunnelsats.slice|/etc/passwd|' "$fx/fs/etc/tunnelsats/managed.json"
run_snippet "$fx" 'ts_m_inventory_read || { echo "refused: $TS_M_ERROR"; exit 1; }'
assert_equals "1" "$SN_RC" "Inventory: a path managed mode never writes is refused"
assert_contains "$SN_OUT" "unexpected file: /etc/passwd" "Inventory: the refusal names the path"

# ---------------------------------------------------------------------------
# GROUP 3: Kill switch arm, read-back, disarm and remove
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 3: Kill switch ---"

fx=$(new_fixture apply)
run_snippet "$fx" 'ts_m_killswitch_apply baremetal lnd lnd.service 1001 0 || { echo "ERR: $TS_M_ERROR"; exit 1; }'
assert_equals "0" "$SN_RC" "Arm: succeeds on a clean kernel"
calls=$(cat "$fx/state/calls")
assert_contains "$calls" "nft -f $fx/fs/run/tunnelsats/ruleset.nft" "Arm: loads the ruleset file with one nft -f"
assert_contains "$calls" "nft [netns] -f $fx/fs/run/tunnelsats/ruleset.nft" "Arm: reads back against a reference load in a throwaway namespace"
assert_contains "$(cat "$fx/state/rules4")" $'21820:\tfrom all lookup main suppress_prefixlength 0' "Arm: IPv4 rule 21820"
assert_contains "$(cat "$fx/state/rules4")" $'21821:\tfrom all fwmark 0x1000000/0xff000000 lookup 51820' "Arm: IPv4 rule 21821"
assert_contains "$(cat "$fx/state/rules6")" $'21821:\tfrom all fwmark 0x1000000/0xff000000 lookup 51820' "Arm: IPv6 rule 21821"
assert_not_contains "$(cat "$fx/state/rules4")" "uidrange" "Arm: no uid backstop rule unless requested"
assert_equals "blackhole default metric 4294967295 " "$(cat "$fx/state/routes4")" "Arm: IPv4 blackhole in table 51820"
assert_equals "blackhole default dev lo metric 4294967295 pref medium" "$(cat "$fx/state/routes6")" "Arm: IPv6 blackhole in table 51820"
att="$fx/fs/run/tunnelsats/attest.json"
assert_equals "644" "$(stat -c %a "$att")" "Arm: attestation mode 0644"
assert_equals "755" "$(stat -c %a "$fx/fs/run/tunnelsats")" "Arm: /run/tunnelsats mode 0755"
assert_json "$(cat "$att")" '[d["armed"], d["boot_id"], d["slice_cgroup_id"]]' \
    "[true, \"0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0\", $(stat -c %i "$fx/fs/sys/fs/cgroup/tunnelsats.slice")]" "Arm: attestation holds the boot id and the slice cgroup id"

: > "$fx/state/calls"
run_snippet "$fx" 'ts_m_killswitch_apply baremetal lnd lnd.service 1001 0 || { echo "ERR: $TS_M_ERROR"; exit 1; }'
assert_equals "0" "$SN_RC" "Arm again: succeeds"
assert_equals "2" "$(grep -c . "$fx/state/rules4")" "Arm again: no duplicate IPv4 rules"
assert_equals "1" "$(grep -c . "$fx/state/routes4")" "Arm again: no duplicate blackhole"
assert_not_contains "$(cat "$fx/state/calls")" "rule add" "Arm again: present rules are not added again"

fx=$(new_fixture backstop)
run_snippet "$fx" 'ts_m_killswitch_apply baremetal lnd lnd.service 1001 1 || { echo "ERR: $TS_M_ERROR"; exit 1; }'
assert_contains "$(cat "$fx/state/rules4")" $'21822:\tfrom all uidrange 1001-1001 lookup 51820' "uid backstop: IPv4 rule 21822 for the node uid"
assert_contains "$(cat "$fx/state/rules6")" $'21822:\tfrom all uidrange 1001-1001 lookup 51820' "uid backstop: IPv6 rule 21822"
assert_json "$(cat "$fx/fs/run/tunnelsats/attest.json")" 'd["uid_backstop"]' 'true' "uid backstop: attested"

fx=$(new_fixture refuse)
touch "$fx/state/nft_refuse"
run_snippet "$fx" 'ts_m_killswitch_apply baremetal lnd lnd.service 1001 0 || { echo "ERR: $TS_M_ERROR"; exit 1; }'
assert_equals "1" "$SN_RC" "Arm: fails when the kernel refuses the ruleset"
assert_contains "$SN_OUT" "nft refused the kill switch ruleset" "Arm: the error names the refusal"
if [[ ! -e "$fx/fs/run/tunnelsats/attest.json" ]]; then pass "Arm: no attestation after a refusal"; else fail "Arm: no attestation after a refusal"; fi
if [[ ! -e "$fx/state/rules4" ]]; then pass "Arm: no policy rules after a refusal"; else fail "Arm: no policy rules after a refusal"; fi

fx=$(new_fixture noipv6)
rm -f "$fx/fs/proc/net/if_inet6"
run_snippet "$fx" 'ts_m_killswitch_apply baremetal lnd lnd.service 1001 0 || { echo "ERR: $TS_M_ERROR"; exit 1; }'
assert_equals "0" "$SN_RC" "Arm without an IPv6 stack: succeeds"
assert_not_contains "$(cat "$fx/state/calls")" "ip -6" "Arm without an IPv6 stack: no IPv6 rule or route calls"

fx=$(new_fixture readback)
run_snippet "$fx" 'ts_m_killswitch_apply baremetal lnd lnd.service 1001 0 >/dev/null
sed -i "/21821/d" "$STUB_STATE/rules4"
printf "blackhole default metric 4294967295 \n" >> "$STUB_STATE/routes6"
sed -i "s/tcp dport 9735 accept/tcp dport 9736 accept/" "$STUB_STATE/nft_table"
ts_m_kernel_readback "$TS_FS_ROOT/run/tunnelsats/ruleset.nft" 0 1001
printf "%s\n" "${TS_M_DRIFT[@]}"'
assert_contains "$SN_OUT" "IPv4 rule 21821 is present 0 times" "Read-back: a missing rule is drift"
assert_contains "$SN_OUT" "differs from the expected ruleset" "Read-back: a changed rule in the table is drift"
assert_contains "$SN_OUT" "IPv6 blackhole in table 51820 is present 2 times" "Read-back: a duplicated blackhole is drift"

fx=$(new_fixture remove)
run_snippet "$fx" 'ts_m_killswitch_apply baremetal lnd lnd.service 1001 1 >/dev/null
printf "21820:\tfrom 192.168.7.0/24 lookup main suppress_prefixlength 0\n" >> "$STUB_STATE/rules4"
printf "default via 192.0.2.99 dev eth9 \n" >> "$STUB_STATE/routes4"
ts_m_killswitch_remove 1001 || { echo "ERR: $TS_M_ERROR"; exit 1; }'
assert_equals "0" "$SN_RC" "Remove: succeeds"
assert_equals $'21820:\tfrom 192.168.7.0/24 lookup main suppress_prefixlength 0' "$(cat "$fx/state/rules4")" "Remove: a foreign rule at priority 21820 stays"
assert_equals "default via 192.0.2.99 dev eth9 " "$(cat "$fx/state/routes4")" "Remove: a foreign route in table 51820 stays"
assert_equals "" "$(cat "$fx/state/rules6")" "Remove: IPv6 rules removed"
if [[ ! -e "$fx/state/nft_table" ]] && [[ ! -e "$fx/fs/run/tunnelsats/attest.json" ]]; then
    pass "Remove: table and attestation removed"
else
    fail "Remove: table and attestation removed"
fi

fx=$(new_fixture disarm)
run_snippet "$fx" 'ts_m_killswitch_apply baremetal lnd lnd.service 1001 0 >/dev/null; ts_m_killswitch_disarm'
if [[ ! -e "$fx/fs/run/tunnelsats/attest.json" ]] && [[ -s "$fx/state/nft_table" ]] && [[ -s "$fx/state/rules4" ]]; then
    pass "Disarm: removes the attestation only; table and rules stay"
else
    fail "Disarm: removes the attestation only; table and rules stay"
fi

# ---------------------------------------------------------------------------
# GROUP 4: Emergency block and verifier
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 4: Emergency block and verifier ---"

fx=$(new_fixture emergency)
printf "21819:\tfrom all uidrange 2002-2002 blackhole\n" > "$fx/state/rules6"
run_snippet "$fx" 'ts_m_emergency_arm 1001 && echo ARMED; ts_m_emergency_verified 1001 && echo VERIFIED'
assert_contains "$SN_OUT" "ARMED" "Emergency: armed for the node uid"
assert_contains "$SN_OUT" "VERIFIED" "Emergency: verified with a real read of the rules"
assert_contains "$(cat "$fx/state/rules4")" $'21819:\tfrom all uidrange 1001-1001 blackhole' "Emergency: IPv4 uid blackhole at 21819"
assert_contains "$(cat "$fx/state/rules6")" $'21819:\tfrom all uidrange 1001-1001 blackhole' "Emergency: IPv6 uid blackhole at 21819"
assert_not_contains "$(cat "$fx/state/calls")" "meta cgroup 1118498" "Emergency: the net_cls nft table is never used in managed mode"
run_snippet "$fx" 'ts_m_emergency_release 1001 && echo RELEASED'
assert_contains "$SN_OUT" "RELEASED" "Emergency: released"
assert_not_contains "$(cat "$fx/state/rules4")" "1001-1001" "Emergency: IPv4 rules removed"
assert_equals $'21819:\tfrom all uidrange 2002-2002 blackhole' "$(cat "$fx/state/rules6")" "Emergency: a foreign IPv6 blackhole rule stays"

# The block keeps the local network: exemptions at 21817 for the node uid (lookup main
# suppress_prefixlength 0), recorded and released with it. The rule scan treats them as
# TunnelSats's own; release removes only the recorded ones.
fx=$(new_fixture emergency-lan)
printf '21817:\tfrom all to 192.168.0.0/16 uidrange 2002-2002 lookup main suppress_prefixlength 0\n' > "$fx/state/rules4"
run_snippet "$fx" 'ts_m_emergency_arm 1001 && echo ARMED'
assert_contains "$SN_OUT" "ARMED" "Emergency LAN: the block is armed"
lan4=""
for r in 10.0.0.0/8 100.64.0.0/10 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16; do
    lan4+=$'21817:\t'"from all to ${r} uidrange 1001-1001 lookup main suppress_prefixlength 0"$'\n'
done
assert_equals "${lan4%$'\n'}" "$(grep -F 'uidrange 1001-1001 lookup main' "$fx/state/rules4")" "Emergency LAN: IPv4 exemptions for the private, CGNAT and link-local ranges"
assert_equals $'21817:\tfrom all to fc00::/7 uidrange 1001-1001 lookup main suppress_prefixlength 0\n21817:\tfrom all to fe80::/10 uidrange 1001-1001 lookup main suppress_prefixlength 0' \
    "$(grep -F 'uidrange 1001-1001 lookup main' "$fx/state/rules6")" "Emergency LAN: IPv6 exemptions for ULA and link-local"
assert_equals "7" "$(wc -l < "$fx/fs/run/tunnelsats/emergency-lan.rules")" "Emergency LAN: each exemption TunnelSats added is recorded"
# Unit test for unrecorded emergency rule cleanup
fx2=$(new_fixture unrecorded-emergency)
printf "21818:\tfrom 10.9.9.0/25 blackhole\n" > "$fx2/state/rules4"
printf "21819:\tfrom all uidrange 1001-1001 blackhole\n" >> "$fx2/state/rules4"
printf "21819:\tfrom all uidrange 1001-1001 blackhole\n" > "$fx2/state/rules6"
run_snippet "$fx2" 'ts_m_emergency_release 1001 && echo RELEASED'
assert_contains "$SN_OUT" "RELEASED" "Emergency: released unrecorded rules"
assert_not_contains "$(cat "$fx2/state/rules4")" "1001-1001" "Emergency: unrecorded IPv4 rules removed"
assert_not_contains "$(cat "$fx2/state/rules6")" "1001-1001" "Emergency: unrecorded IPv6 rules removed"
assert_not_contains "$(cat "$fx2/state/rules4")" "10.9.9.0/25" "Emergency: unrecorded IPv4 subnet rules removed"

run_snippet "$fx" 'ts_m_foreign_rules_before 21818; ts_m_emergency_effective 1001 && echo EFFECTIVE'
assert_equals "EFFECTIVE" "$SN_OUT" "Emergency LAN: the rule scan treats the exemptions (any uid) as TunnelSats's own"
run_snippet "$fx" 'ts_m_emergency_lan_missing 1001'
assert_equals "0 7" "$SN_OUT" "Emergency LAN: none missing"
# Arming again (the verifier does on every run while the block holds) adds nothing; an exemption
# another tool removed is added back and recorded once
: > "$fx/state/calls"
run_snippet "$fx" 'ts_m_emergency_arm 1001 >/dev/null; ts_m_emergency_arm 1001 >/dev/null'
assert_equals "5 2 7 0" "$(grep -c '^21817:.*uidrange 1001-1001' "$fx/state/rules4") $(grep -c '^21817:.*uidrange 1001-1001' "$fx/state/rules6") $(wc -l < "$fx/fs/run/tunnelsats/emergency-lan.rules") $(grep -c 'rule add.*priority 21817' "$fx/state/calls" || true)" \
    "Emergency LAN: armed three times, still 5 + 2 exemptions and 7 records, nothing added again"
sed -i '/to 10\.0\.0\.0\/8 uidrange 1001-1001/d' "$fx/state/rules4"
run_snippet "$fx" 'ts_m_emergency_arm 1001 >/dev/null'
assert_equals "5 7" "$(grep -c '^21817:.*uidrange 1001-1001' "$fx/state/rules4") $(wc -l < "$fx/fs/run/tunnelsats/emergency-lan.rules")" \
    "Emergency LAN: an exemption another tool removed is added back and recorded once"
run_snippet "$fx" 'ts_m_emergency_release 1001 && echo RELEASED'
assert_contains "$SN_OUT" "RELEASED" "Emergency LAN: released with the block"
assert_equals $'21817:\tfrom all to 192.168.0.0/16 uidrange 2002-2002 lookup main suppress_prefixlength 0' "$(cat "$fx/state/rules4")" \
    "Emergency LAN: only the recorded exemptions are removed (another uid's stays)"
assert_equals "" "$(grep -F '1001-1001' "$fx/state/rules6" || true)" "Emergency LAN: the IPv6 exemptions are removed"
if [[ ! -e "$fx/fs/run/tunnelsats/emergency-lan.rules" ]]; then pass "Emergency LAN: the record goes with the rules"; else fail "Emergency LAN: the record goes with the rules"; fi
# An exemption that cannot be added costs only that network: the block still arms and is in effect
echo "rule add to 10.0.0.0/8 uidrange 1001-1001 lookup main suppress_prefixlength 0 priority 21817" > "$fx/state/fail_ip"
run_snippet "$fx" 'ts_m_emergency_arm 1001 && ts_m_emergency_effective 1001 && echo IN_EFFECT; ts_m_emergency_lan_missing 1001'
assert_equals $'IN_EFFECT\n1 7' "$SN_OUT" "Emergency LAN: a missing exemption does not fail the block"
rm -f "$fx/state/fail_ip"
run_snippet "$fx" 'ts_m_emergency_release 1001'
# Without IPv6 only the IPv4 exemptions are armed
fx=$(new_fixture emergency-lan4)
rm -f "$fx/fs/proc/net/if_inet6"
run_snippet "$fx" 'ts_m_emergency_arm 1001 >/dev/null; ts_m_emergency_lan_missing 1001'
assert_equals "0 5" "$SN_OUT" "Emergency LAN: without IPv6 only the IPv4 exemptions"
if [[ ! -e "$fx/state/rules6" ]]; then pass "Emergency LAN: no IPv6 rule calls without IPv6"; else fail "Emergency LAN: no IPv6 rule calls without IPv6"; fi
# A blackhole that is gone while exemptions remain: removal and re-arm clear them too
fx=$(new_fixture emergency-lan-left)
run_snippet "$fx" 'ts_m_emergency_arm 1001 >/dev/null'
sed -i '/blackhole/d' "$fx/state/rules4" "$fx/state/rules6"
run_snippet "$fx" 'ts_m_emergency_present 1001 || echo ABSENT; ts_m_emergency_lan_release && echo LAN_RELEASED'
assert_equals $'ABSENT\nLAN_RELEASED' "$SN_OUT" "Emergency LAN: exemptions without their blackholes can be released on their own"
assert_equals "" "$(grep -F '21817' "$fx/state/rules4" "$fx/state/rules6" || true)" "Emergency LAN: none left"

# Verifier: inventory plus an armed kill switch, then drift
fx=$(new_fixture verifier)
mkdir -p "$fx/fs/etc/tunnelsats"
write_inventory() {
    run_snippet "$1" '
TS_M_INV_STATE=installed TS_M_INV_PROFILE=baremetal TS_M_INV_IMPL=lnd TS_M_INV_UNIT=lnd.service TS_M_INV_USER=bitcoin TS_M_INV_UID=1001 TS_M_INV_BACKSTOP='"${2:-0}"'
TS_M_FILES=() TS_M_FILE_SHA=() TS_M_CREATED_DIRS=() TS_M_ENABLED_UNITS=()
ts_m_inventory_write'
}
write_inventory "$fx"
run_snippet "$fx" 'ts_m_cmd_arm'
assert_equals "0" "$SN_RC" "managed-arm: arms from the inventory"
assert_contains "$SN_OUT" "kill switch armed and verified" "managed-arm: logs the state change"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "0" "$SN_RC" "managed-verify: steady state passes"
assert_equals "" "$SN_OUT" "managed-verify: a steady state logs nothing"
rm -f "$fx/state/nft_table"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "0" "$SN_RC" "managed-verify: re-arms after the table vanished"
assert_contains "$SN_OUT" "drift detected (nft table inet tunnelsats is missing)" "managed-verify: names the drift"
assert_contains "$SN_OUT" "re-armed and verified" "managed-verify: logs the re-arm"
if [[ -s "$fx/state/nft_table" ]]; then pass "managed-verify: the table is back"; else fail "managed-verify: the table is back"; fi
touch "$fx/state/nft_refuse"
rm -f "$fx/state/nft_table"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "0" "$SN_RC" "managed-verify: a failed re-arm ends fail-closed (emergency block armed)"
assert_contains "$SN_OUT" "emergency block armed for uid 1001" "managed-verify: logs the emergency block"
if [[ ! -e "$fx/fs/run/tunnelsats/attest.json" ]]; then pass "managed-verify: attestation removed when re-arming fails"; else fail "managed-verify: attestation removed when re-arming fails"; fi
assert_contains "$(cat "$fx/state/rules4")" $'21819:\tfrom all uidrange 1001-1001 blackhole' "managed-verify: uid blackhole in place"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "" "$SN_OUT" "managed-verify: the unchanged fail-closed state logs nothing"
assert_contains "$(cat "$fx/state/rules4")" "1001-1001 blackhole" "managed-verify: the block stays while re-arming keeps failing"
rm -f "$fx/state/nft_refuse"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_contains "$SN_OUT" "emergency block released" "managed-verify: releases the block only after a successful re-arm"
assert_not_contains "$(cat "$fx/state/rules4")" "1001-1001 blackhole" "managed-verify: uid blackhole removed after the re-arm"

# managed-arm exits 0 only when Lightning's clearnet traffic is tunneled or blocked (the Lightning
# unit requires it), and 1 when neither protection holds
fx=$(new_fixture armfail)
mkdir -p "$fx/fs/etc/tunnelsats"
write_inventory "$fx"
touch "$fx/state/nft_refuse"
run_snippet "$fx" 'ts_m_cmd_arm'
assert_equals "0" "$SN_RC" "managed-arm: exits 0 when the kill switch fails but the emergency block holds (Lightning may start, blocked)"
assert_contains "$(cat "$fx/state/rules4")" $'21819:\tfrom all uidrange 1001-1001 blackhole' "managed-arm: arms the emergency block right away"
if [[ ! -e "$fx/fs/run/tunnelsats/attest.json" ]]; then pass "managed-arm: no attestation while only the emergency block holds"; else fail "managed-arm: no attestation while only the emergency block holds"; fi
run_snippet "$fx" 'ts_m_emergency_release 1001'
printf '%s\n' "rule add uidrange 1001-1001 blackhole priority 21819" > "$fx/state/fail_ip"
run_snippet "$fx" 'ts_m_cmd_arm'
assert_equals "1" "$SN_RC" "managed-arm: exits 1 when neither the kill switch nor the emergency block can be armed (Lightning does not start)"
assert_contains "$SN_OUT" "the emergency block could not be armed either" "managed-arm: says so"
rm -f "$fx/state/fail_ip" "$fx/state/nft_refuse"
run_snippet "$fx" 'ts_m_emergency_release 1001'
run_snippet "$fx" 'ts_m_lock() { return 1; }; ts_m_cmd_arm'
assert_equals "0" "$SN_RC" "managed-arm: an unavailable lock ends with the emergency block (exit 0, blocked)"
run_snippet "$fx" 'ts_m_emergency_release 1001'
echo "garbage" > "$fx/fs/etc/tunnelsats/managed.json"
run_snippet "$fx" 'ts_m_cmd_arm'
assert_equals "1" "$SN_RC" "managed-arm: exits 1 with an unreadable inventory and no fallback uid (Lightning does not start)"
assert_contains "$SN_OUT" "Lightning does not start" "managed-arm: the journal line says Lightning does not start"
assert_not_contains "$(cat "$fx/state/rules4" 2>/dev/null)" "21819" "managed-arm: no block is armed without a uid"

# A damaged install record no longer stops Lightning: with the uid that the kill switch unit's
# ExecStart carries (--fallback-uid), managed-arm arms the emergency block for it (the local network
# kept) and exits 0, so Lightning starts with its clearnet traffic blocked
run_snippet "$fx" 'TS_OPT_FALLBACK_UID=1001; ts_m_cmd_arm'
assert_equals "0" "$SN_RC" "managed-arm: an unreadable record with --fallback-uid exits 0 (Lightning starts behind the block)"
assert_contains "$SN_OUT" "install record unreadable" "managed-arm: says the install record is unreadable"
assert_contains "$SN_OUT" "emergency block armed for uid 1001: Lightning starts with clearnet traffic blocked, Tor and the local network keep working" \
    "managed-arm: and that Lightning starts behind the emergency block"
assert_contains "$(cat "$fx/state/rules4")" $'21819:\tfrom all uidrange 1001-1001 blackhole' "managed-arm: the blackhole for the fallback uid"
assert_contains "$(cat "$fx/state/rules4")" $'21817:\tfrom all to 192.168.0.0/16 uidrange 1001-1001 lookup main suppress_prefixlength 0' \
    "managed-arm: with the local network exemptions"
# The verifier finds the uid in the unit's ExecStart, keeps the block, releases nothing, logs once
printf '{ path=/usr/local/sbin/tunnelsats ; argv[]=/usr/local/sbin/tunnelsats managed-arm --fallback-uid 1001 ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }\n' \
    > "$fx/state/unit_tunnelsats-killswitch.service_ExecStart"
run_snippet "$fx" 'ts_m_fallback_uid'
assert_equals "1001" "$SN_OUT" "Fallback uid: read from the kill switch unit's ExecStart"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "0" "$SN_RC" "managed-verify: an unreadable record with the block in effect passes"
assert_contains "$SN_OUT" "install record unreadable" "managed-verify: logs that the install record is unreadable"
assert_contains "$SN_OUT" "emergency block active for uid 1001" "managed-verify: and that the emergency block is active"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "" "$SN_OUT" "managed-verify: the unchanged damaged state logs nothing"
assert_contains "$(cat "$fx/state/rules4")" $'21819:\tfrom all uidrange 1001-1001 blackhole' "managed-verify: never releases the block while the record is unreadable"
# A rule of another tool before the block: Lightning stays stopped even with the fallback uid
printf '100:\tfrom all lookup main\n' >> "$fx/state/rules4"
run_snippet "$fx" 'TS_OPT_FALLBACK_UID=1001; ts_m_cmd_arm'
assert_equals "1" "$SN_RC" "managed-arm: an unreadable record and a rule before the block exits 1"
assert_contains "$SN_OUT" "is armed but not in effect: IPv4 rule before 21818: 100: from all lookup main; Lightning does not start" "managed-arm: names the rule"
# The verifier in the same state stops the Lightning units that carry the drop-in (read from the
# unit directory, since the record is unreadable), and starts them again once the block holds
mkdir -p "$fx/fs/etc/systemd/system/lnd.service.d" "$fx/fs/etc/systemd/system/wg-quick@tunnelsatsv2.service.d"
run_snippet "$fx" 'ts_m_render_ln_dropin > "$TS_FS_ROOT/etc/systemd/system/lnd.service.d/tunnelsats-managed.conf"; ts_m_render_wg_dropin > "$TS_FS_ROOT/etc/systemd/system/wg-quick@tunnelsatsv2.service.d/tunnelsats-managed.conf"; ts_m_dropin_units'
assert_equals "lnd.service" "$SN_OUT" "Drop-in units: the Lightning unit with the drop-in, not the tunnel unit"
touch "$fx/state/stateful_units"
echo "active" > "$fx/state/unit_lnd.service_ActiveState"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "1" "$SN_RC" "managed-verify: an unreadable record and a rule before the block is a failure"
assert_contains "$SN_OUT" "is armed but not in effect: IPv4 rule before 21818: 100: from all lookup main; lnd.service stopped" \
    "managed-verify: names the rule and stops Lightning"
assert_equals "inactive" "$(cat "$fx/state/unit_lnd.service_ActiveState")" "managed-verify: Lightning is stopped"
sed -i '/^100:/d' "$fx/state/rules4"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "0" "$SN_RC" "managed-verify: without that rule the block holds again"
assert_contains "$SN_OUT" "protection holds again; starting lnd.service again" "managed-verify: and Lightning starts again"
assert_equals "active" "$(cat "$fx/state/unit_lnd.service_ActiveState")" "managed-verify: Lightning runs again"
# systemd does not answer: the uid comes from the unit file TunnelSats wrote
touch "$fx/state/fail_systemctl_show"
run_snippet "$fx" 'ts_m_render_killswitch_unit lnd.service 1001 > "$TS_FS_ROOT/etc/systemd/system/tunnelsats-killswitch.service"; ts_m_fallback_uid'
assert_equals "1001" "$SN_OUT" "Fallback uid: read from the unit file while systemd does not answer"
run_snippet "$fx" 'ts_m_render_killswitch_unit lnd.service "" > "$TS_FS_ROOT/etc/systemd/system/tunnelsats-killswitch.service"; ts_m_fallback_uid; echo "rc=$?"'
assert_equals "rc=0" "$SN_OUT" "Fallback uid: a unit file without --fallback-uid gives none"
rm -f "$fx/fs/etc/systemd/system/tunnelsats-killswitch.service"
run_snippet "$fx" 'rc=0; ts_m_fallback_uid || rc=$?; echo "rc=$rc"'
assert_equals "rc=1" "$SN_OUT" "Fallback uid: neither systemd nor the unit file answers: an error, never none"
# Without any uid, no block can be armed: the verifier stops Lightning (systemd does not answer
# here, so it cannot tell whether the unit stopped: unprotected, said so)
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "1" "$SN_RC" "managed-verify: no readable uid is a failure"
assert_contains "$SN_OUT" "the Lightning uid cannot be read (systemd does not answer and /etc/systemd/system/tunnelsats-killswitch.service cannot be read), so no emergency block can be armed; could not stop lnd.service (state unknown" \
    "managed-verify: says why and that Lightning could not be confirmed stopped"
assert_contains "$(cat "$fx/state/calls")" "systemctl stop --no-block lnd.service" "managed-verify: it still tries to stop Lightning"
rm -f "$fx/state/fail_systemctl_show" "$fx/state/stateful_units" "$fx/fs/run/tunnelsats/stopped-units"
rm -rf "$fx/fs/etc/systemd/system/lnd.service.d" "$fx/fs/etc/systemd/system/wg-quick@tunnelsatsv2.service.d"
echo "inactive" > "$fx/state/unit_lnd.service_ActiveState"
sed -i '/^100:/d' "$fx/state/rules4"
# The record restored: managed-arm arms the kill switch and releases the block, exemptions included
write_inventory "$fx"
run_snippet "$fx" 'TS_OPT_FALLBACK_UID=1001; ts_m_cmd_arm'
assert_equals "0" "$SN_RC" "managed-arm: with the record restored, arms the kill switch"
assert_contains "$SN_OUT" "emergency block released" "managed-arm: and releases the emergency block"
assert_not_contains "$(cat "$fx/state/rules4")" "1001-1001" "managed-arm: no blackhole or exemption for the uid is left"
rm -f "$fx/state/unit_tunnelsats-killswitch.service_ExecStart"
# --fallback-uid: a positive uid, managed-arm only
run_snippet "$fx" 'ts_parse_cli managed-arm --fallback-uid 1001; echo "${TS_COMMAND}:${TS_OPT_FALLBACK_UID}:${TS_USAGE_ERROR}"'
assert_equals "managed-arm:1001:" "$SN_OUT" "CLI: managed-arm --fallback-uid 1001"
run_snippet "$fx" 'ts_parse_cli managed-arm --fallback-uid 0; echo "${TS_OPT_FALLBACK_UID}:${TS_USAGE_ERROR}"'
assert_equals ":--fallback-uid requires a positive uid" "$SN_OUT" "CLI: --fallback-uid 0 is a usage error"
run_snippet "$fx" 'ts_parse_cli verify --fallback-uid 1001; ts_option_supported verify --fallback-uid || echo "not for verify"'
assert_equals "not for verify" "$SN_OUT" "CLI: --fallback-uid is for managed-arm only"

# The earlier-rule scan shared by ip_rules and the emergency block: rules of other tools before a
# priority, without the local rule, Tailscale's rules while no exit node is active and TunnelSats's
# emergency blackholes
fx=$(new_fixture rulescan)
printf '100:\tfrom all lookup main\n5210:\tfrom all fwmark 0x80000/0xff0000 lookup main\n5270:\tfrom all lookup 52\n21818:\tfrom 10.9.9.0/25 blackhole\n21819:\tfrom all uidrange 1001-1001 blackhole\n21820:\tfrom all lookup main suppress_prefixlength 0\n' > "$fx/state/rules4"
printf '200:\tfrom all lookup 300\n21819:\tfrom all uidrange 1001-1001 blackhole\n' > "$fx/state/rules6"
run_snippet "$fx" 'ts_m_foreign_rules_before 21818; echo "rc=$?"'
assert_equals $'IPv4 rule before 21818: 100: from all lookup main\nIPv6 rule before 21818: 200: from all lookup 300\nrc=0' "$SN_OUT" \
    "Rule scan: rules of other tools before 21818 in both families; the local rule, Tailscale's rules and later rules are not listed"
run_snippet "$fx" 'ts_m_foreign_rules_before 21820'
assert_equals $'IPv4 rule before 21820: 100: from all lookup main\nIPv6 rule before 21820: 200: from all lookup 300' "$SN_OUT" \
    "Rule scan: TunnelSats's emergency blackholes at 21818 and 21819 are not listed"
echo "default dev tailscale0 table 52" > "$fx/state/table52"
run_snippet "$fx" 'ts_m_foreign_rules_before 21818'
assert_contains "$SN_OUT" "IPv4 rule before 21818: 5270: from all lookup 52" "Rule scan: with a Tailscale exit node, its rules are listed"
rm -f "$fx/state/table52"
echo "rule show" > "$fx/state/fail_ip"
run_snippet "$fx" 'ts_m_foreign_rules_before 21818 || echo "rc=$?"'
assert_equals $'IPv4 rules cannot be read\nIPv6 rules cannot be read\nrc=1' "$SN_OUT" "Rule scan: rules that cannot be read are reported, never taken as none"
rm -f "$fx/state/fail_ip"

# The emergency block is in effect only when its rules are verified and nothing comes before them
fx=$(new_fixture effective)
run_snippet "$fx" 'ts_m_emergency_arm 1001 >/dev/null; ts_m_emergency_effective 1001 && echo EFFECTIVE'
assert_equals "EFFECTIVE" "$SN_OUT" "Emergency in effect: verified rules, nothing before them"
printf '5210:\tfrom all fwmark 0x80000/0xff0000 lookup main\n5270:\tfrom all lookup 52\n' >> "$fx/state/rules4"
run_snippet "$fx" 'ts_m_emergency_effective 1001 && echo EFFECTIVE'
assert_equals "EFFECTIVE" "$SN_OUT" "Emergency in effect: Tailscale's rules without an exit node do not count"
printf '100:\tfrom all lookup main\n' >> "$fx/state/rules4"
run_snippet "$fx" 'ts_m_emergency_effective 1001 || echo "NOT: $TS_M_ERROR"'
assert_equals "NOT: IPv4 rule before 21818: 100: from all lookup main" "$SN_OUT" "Emergency not in effect: a rule of another tool before it, named"
sed -i '/^100:/d' "$fx/state/rules4"
sed -i '/^21819:/d' "$fx/state/rules6"
run_snippet "$fx" 'ts_m_emergency_effective 1001 || echo "NOT: $TS_M_ERROR"'
assert_equals "NOT: not all of its rules (priority 21818 and 21819) are in place" "$SN_OUT" "Emergency not in effect: the IPv6 rule is missing"

# managed-arm with a rule of another tool before the emergency block: the block is armed but not in
# effect, so managed-arm exits 1 (Lightning stays stopped through Requires=) and logs the rule
fx=$(new_fixture armbypass)
mkdir -p "$fx/fs/etc/tunnelsats"
write_inventory "$fx"
touch "$fx/state/nft_refuse"
printf '100:\tfrom all lookup main\n' > "$fx/state/rules4"
run_snippet "$fx" 'ts_m_cmd_arm'
assert_equals "1" "$SN_RC" "managed-arm: exits 1 when a rule of another tool comes before the emergency block (Lightning does not start)"
assert_contains "$SN_OUT" "the emergency block is armed but not in effect: IPv4 rule before 21818: 100: from all lookup main" "managed-arm: names the rule"
assert_contains "$SN_OUT" "Lightning does not start" "managed-arm: says Lightning does not start"
assert_contains "$(cat "$fx/state/rules4")" $'21819:\tfrom all uidrange 1001-1001 blackhole' "managed-arm: the block stays armed (it covers what that rule does not)"
run_snippet "$fx" 'ts_m_cmd_arm'
assert_equals "1" "$SN_RC" "managed-arm: a second attempt exits 1 as well"
assert_contains "$SN_OUT" "Lightning does not start" "managed-arm: and says why again (the state change is logged once)"
# Without that rule the block is in effect: the verifier logs the fail-closed state, managed-arm
# exits 0. When a rule of another tool appears again, the verifier logs the change to unprotected
# once, naming the rule
sed -i '/^100:/d' "$fx/state/rules4"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "0" "$SN_RC" "managed-verify: without that rule the block is in effect"
assert_contains "$SN_OUT" "emergency block armed for uid 1001" "managed-verify: logs the fail-closed state"
run_snippet "$fx" 'ts_m_cmd_arm'
assert_equals "0" "$SN_RC" "managed-arm: exits 0 again once the block is in effect"
printf '100:\tfrom all lookup main\n' >> "$fx/state/rules4"
# Lightning runs when that happens: the verifier stops it, reads back that it stopped, and records it
touch "$fx/state/stateful_units"
echo "active" > "$fx/state/unit_lnd.service_ActiveState"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "1" "$SN_RC" "managed-verify: a block that is not in effect is a failure"
assert_contains "$SN_OUT" "the emergency block is armed but not in effect: IPv4 rule before 21818: 100: from all lookup main" \
    "managed-verify: logs the change, naming the rule"
assert_contains "$SN_OUT" "lnd.service stopped, so no Lightning traffic leaves outside the tunnel" \
    "managed-verify: stops Lightning while neither the kill switch nor the block holds"
assert_contains "$(cat "$fx/state/calls")" "systemctl stop --no-block lnd.service" "managed-verify: the stop goes through systemd without blocking (the verifier holds the lock)"
assert_equals "inactive" "$(cat "$fx/state/unit_lnd.service_ActiveState")" "managed-verify: Lightning is stopped"
assert_equals "lnd.service stopped 0" "$(cat "$fx/fs/run/tunnelsats/stopped-units" 2>/dev/null)" "managed-verify: records the unit it stopped"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "1" "$SN_RC" "managed-verify: still a failure while neither holds"
assert_equals "" "$SN_OUT" "managed-verify: the unchanged stopped state logs nothing"
# Without that rule the block holds again: the verifier starts Lightning again, without waiting
sed -i '/^100:/d' "$fx/state/rules4"
: > "$fx/state/calls"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "0" "$SN_RC" "managed-verify: the block holds again"
assert_contains "$SN_OUT" "protection holds again; starting lnd.service again" "managed-verify: starts Lightning again"
assert_contains "$(cat "$fx/state/calls")" "systemctl start --no-block lnd.service" "managed-verify: the start is queued, not awaited (the verifier holds the lock)"
assert_equals "active" "$(cat "$fx/state/unit_lnd.service_ActiveState")" "managed-verify: Lightning runs again"
assert_equals "lnd.service starting 1" "$(cat "$fx/fs/run/tunnelsats/stopped-units" 2>/dev/null)" "managed-verify: the unit stays recorded until a check finds it running"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_contains "$SN_OUT" "lnd.service runs again" "managed-verify: the next check confirms that Lightning runs"
if [[ -e "$fx/fs/run/tunnelsats/stopped-units" ]]; then
    fail "managed-verify: then the record of stopped units is removed"
else
    pass "managed-verify: then the record of stopped units is removed"
fi
# A start that systemd refuses, or that it accepts but that fails, is retried with each check and
# logged once per change
printf '100:\tfrom all lookup main\n' >> "$fx/state/rules4"
run_snippet "$fx" 'ts_m_cmd_verifier'
sed -i '/^100:/d' "$fx/state/rules4"
touch "$fx/state/fail_systemctl_start_lnd.service"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_contains "$SN_OUT" "lnd.service could not be started" "managed-verify: a refused start is logged"
assert_equals "lnd.service start-failed 1" "$(cat "$fx/fs/run/tunnelsats/stopped-units" 2>/dev/null)" "managed-verify: and the unit stays recorded"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_not_contains "$SN_OUT" "could not be started" "managed-verify: the same failure is not logged again"
rm -f "$fx/state/fail_systemctl_start_lnd.service" "$fx/state/stateful_units"
echo "failed" > "$fx/state/unit_lnd.service_ActiveState"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_contains "$SN_OUT" "protection holds again; starting lnd.service again" "managed-verify: the retry is queued once the start is accepted"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_contains "$SN_OUT" "lnd.service did not start (state failed); trying again with each check" "managed-verify: an accepted start that failed is retried"
assert_equals "lnd.service retrying 4" "$(cat "$fx/fs/run/tunnelsats/stopped-units" 2>/dev/null)" "managed-verify: the unit stays recorded while it does not run, attempts counted"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "" "$SN_OUT" "managed-verify: further retries log nothing"
echo "active" > "$fx/state/unit_lnd.service_ActiveState"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_contains "$SN_OUT" "lnd.service runs again" "managed-verify: once it runs, that is logged"
if [[ -e "$fx/fs/run/tunnelsats/stopped-units" ]]; then
    fail "managed-verify: and the record is removed"
else
    pass "managed-verify: and the record is removed"
fi
# After TS_M_RESUME_MAX starts, the verifier gives up and logs the command to start it by hand
echo "lnd.service retrying 2" > "$fx/fs/run/tunnelsats/stopped-units"
echo "failed" > "$fx/state/unit_lnd.service_ActiveState"
run_snippet "$fx" 'TS_M_RESUME_MAX=2; ts_m_cmd_verifier'
assert_contains "$SN_OUT" "lnd.service did not start after 2 attempts (state failed); no further attempts. Start it with: systemctl start lnd.service" \
    "managed-verify: gives up after the last attempt, with the command"
if [[ -e "$fx/fs/run/tunnelsats/stopped-units" ]]; then
    fail "managed-verify: the unit is no longer recorded after the last attempt"
else
    pass "managed-verify: the unit is no longer recorded after the last attempt"
fi
echo "active" > "$fx/state/unit_lnd.service_ActiveState"
touch "$fx/state/stateful_units"
# A unit still shutting down when the wait ends: state stopping; the next check confirms the stop
printf '100:\tfrom all lookup main\n' >> "$fx/state/rules4"
rm -f "$fx/state/stateful_units"
echo "deactivating" > "$fx/state/unit_lnd.service_ActiveState"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "1" "$SN_RC" "managed-verify: a unit still shutting down is not confirmed yet"
assert_contains "$SN_OUT" "lnd.service is shutting down; the next check confirms that it stopped" "managed-verify: says it is shutting down"
echo "inactive" > "$fx/state/unit_lnd.service_ActiveState"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_contains "$SN_OUT" "lnd.service stopped, so no Lightning traffic leaves outside the tunnel" "managed-verify: the next check confirms the stop"
touch "$fx/state/stateful_units"
sed -i '/^100:/d' "$fx/state/rules4"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "active" "$(cat "$fx/state/unit_lnd.service_ActiveState")" "managed-verify: and starts Lightning again once the block holds"
# A unit that does not stop: unprotected, with the state and the reason
printf '100:\tfrom all lookup main\n' >> "$fx/state/rules4"
touch "$fx/state/fail_systemctl_stop_lnd.service"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "1" "$SN_RC" "managed-verify: a unit that does not stop is a failure"
assert_contains "$SN_OUT" "could not stop lnd.service (state active; systemctl stop failed)" "managed-verify: says the unit could not be stopped, with its state"
rm -f "$fx/state/fail_systemctl_stop_lnd.service"
sed -i '/^100:/d' "$fx/state/rules4"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "0" "$SN_RC" "managed-verify: the block holds again"
if [[ -e "$fx/fs/run/tunnelsats/stopped-units" ]]; then
    fail "managed-verify: once the block holds, no record of stopped units remains"
else
    pass "managed-verify: once the block holds, no record of stopped units remains"
fi
# A Lightning unit that now runs as another user: the uid block would not cover it, so the verifier
# stops Lightning even though the block could be armed
echo "root" > "$fx/state/unit_lnd.service_User"
echo "active" > "$fx/state/unit_lnd.service_ActiveState"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "1" "$SN_RC" "managed-verify: a changed Lightning user is a failure"
assert_contains "$SN_OUT" "the lnd.service user changed to uid 0, so the emergency block for uid 1001 does not cover it" "managed-verify: names the uid change"
assert_equals "inactive" "$(cat "$fx/state/unit_lnd.service_ActiveState")" "managed-verify: and stops Lightning"
run_snippet "$fx" 'ts_m_cmd_arm'
assert_equals "1" "$SN_RC" "managed-arm: a changed Lightning user exits 1 (Lightning does not start)"
assert_contains "$SN_OUT" "user changed to uid 0" "managed-arm: and says why"
rm -f "$fx/state/unit_lnd.service_User" "$fx/state/stateful_units" "$fx/fs/run/tunnelsats/stopped-units"

# ---------------------------------------------------------------------------
# GROUP 5: Node config detector
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 5: Node config detector ---"

nc_case() {  # $1 = impl, $2 = unit, $3 = ExecStart argv, $4 = config path, $5 = config content, $6 = optional wrapper script to create
    local fx
    fx=$(new_fixture "nc-$RANDOM")
    printf '{ path=/usr/local/bin/x ; argv[]=%s ; ignore_errors=no ; start_time=[n/a] }' "$3" > "$fx/state/unit_${2}_ExecStart"
    echo "bitcoin" > "$fx/state/unit_${2}_User"
    if [[ -n "$4" ]]; then
        mkdir -p "$(dirname "$fx/fs$4")"
        printf '%s\n' "$5" > "$fx/fs$4"
    fi
    if [[ -n "${6:-}" ]]; then
        mkdir -p "$(dirname "$fx/fs$6")"
        printf '#!/bin/sh\nexec /usr/local/bin/lnd --externalhosts=203.0.113.5:9735 "$@"\n' > "$fx/fs$6"
    fi
    run_snippet "$fx" "STUB_HOME=/home/bitcoin; export STUB_HOME; ts_m_node_config_clearnet $1 $2; echo \"\$TS_M_NC_STATUS\"; printf '%s\n' \"\${TS_M_NC_LINES[@]}\"; echo \"reason=\$TS_M_NC_REASON\""
}

nc_case lnd lnd.service "/usr/local/bin/lnd --configfile=/data/lnd/lnd.conf" /data/lnd/lnd.conf $'[Application Options]\nlisten=0.0.0.0:9735\n# externalhosts=x.example:1\n[Tor]\ntor.active=true\ntor.skip-proxy-for-clearnet-targets=false'
assert_equals "clean" "${SN_OUT%%$'\n'*}" "Detector: LND Tor-only config (commented externalhosts, skip-proxy false) is clean"
nc_case lnd lnd.service "/usr/local/bin/lnd --configfile /data/lnd/lnd.conf" /data/lnd/lnd.conf $'externalhosts=de2.tunnelsats.com:24556\n tor.skip-proxy-for-clearnet-targets = 1'
assert_equals "clearnet" "${SN_OUT%%$'\n'*}" "Detector: LND externalhosts and skip-proxy=1 are clearnet"
assert_contains "$SN_OUT" "/data/lnd/lnd.conf:1:externalhosts=de2.tunnelsats.com:24556" "Detector: reports file, line and setting"
assert_contains "$SN_OUT" "/data/lnd/lnd.conf:2:tor.skip-proxy-for-clearnet-targets=1" "Detector: spaces around = are handled"
nc_case lnd lnd.service "/usr/local/bin/lnd" /home/bitcoin/.lnd/lnd.conf $'tor.skip-proxy-for-clearnet-targets=true'
assert_equals "clearnet" "${SN_OUT%%$'\n'*}" "Detector: default path below the User's home"
nc_case lnd lnd.service "/usr/local/bin/lnd --lnddir=/srv/lnd" /srv/lnd/lnd.conf $'listen=0.0.0.0:9735'
assert_equals "clean" "${SN_OUT%%$'\n'*}" "Detector: --lnddir selects <dir>/lnd.conf"
nc_case lnd lnd.service "/usr/local/bin/lnd --configfile=/missing/lnd.conf" "" ""
assert_equals "unknown" "${SN_OUT%%$'\n'*}" "Detector: a missing config is unknown"
assert_contains "$SN_OUT" "no config file found" "Detector: unknown carries the reason"
nc_case cln lightningd.service "/usr/bin/lightningd --conf=/etc/cln/config" /etc/cln/config $'bind-addr=127.0.0.1:9736\nannounce-addr=abcdefghijklmnop.onion:9735\nalways-use-proxy=true\nproxy=127.0.0.1:9050'
assert_equals "clean" "${SN_OUT%%$'\n'*}" "Detector: CLN Tor bind, onion announce and always-use-proxy=true are clean"
nc_case cln lightningd.service "/usr/bin/lightningd --conf=/etc/cln/config" /etc/cln/config $'bind-addr=127.0.0.1:9736\nbind-addr=0.0.0.0:9735\nannounce-addr=203.0.113.7:24556\nalways-use-proxy=false'
assert_equals "clearnet" "${SN_OUT%%$'\n'*}" "Detector: CLN clearnet settings are found"
assert_contains "$SN_OUT" "/etc/cln/config:2:bind-addr=0.0.0.0:9735" "Detector: CLN bind-addr=0.0.0.0:9735"
assert_contains "$SN_OUT" "/etc/cln/config:3:announce-addr=203.0.113.7:24556" "Detector: CLN non-onion announce-addr"
assert_contains "$SN_OUT" "/etc/cln/config:4:always-use-proxy=false" "Detector: CLN always-use-proxy=false"
assert_not_contains "$SN_OUT" "127.0.0.1:9736" "Detector: the Tor bind is never reported"
nc_case cln lightningd.service "/usr/bin/lightningd --conf=/etc/cln/config" /etc/cln/config $'addr=127.0.0.1:9736\naddr=statictor:127.0.0.1:9051/torport=9735\naddr=abcdefghijklmnop.onion:9735\naddr=/run/cln/rpc-socket'
assert_equals "clean" "${SN_OUT%%$'\n'*}" "Detector: CLN addr on loopback, Tor or a local socket is clean"
nc_case cln lightningd.service "/usr/bin/lightningd --conf=/etc/cln/config" /etc/cln/config $'addr=127.0.0.1:9736\naddr=203.0.113.7:9735'
assert_equals "clearnet" "${SN_OUT%%$'\n'*}" "Detector: CLN addr with a public address binds and announces: clearnet"
assert_contains "$SN_OUT" "/etc/cln/config:2:addr=203.0.113.7:9735" "Detector: reports the CLN addr line"
nc_case cln lightningd.service "/usr/bin/lightningd --conf=/etc/cln/config" /etc/cln/config $'addr=:9735'
assert_equals "clearnet" "${SN_OUT%%$'\n'*}" "Detector: CLN addr on all interfaces is clearnet"
nc_case lit litd.service "/usr/local/bin/litd" /home/bitcoin/.lit/lit.conf $'lnd-mode=integrated\nlnd.externalhosts=de2.tunnelsats.com:24556'
assert_equals "clearnet" "${SN_OUT%%$'\n'*}" "Detector: LIT lnd.externalhosts is clearnet"

# Settings on the command line (ExecStart) count like config lines; a command line that cannot be
# checked reliably makes the result unknown, so uninstall leaves Lightning stopped
clean_lnd=$'[Application Options]\nlisten=0.0.0.0:9735\n[Tor]\ntor.active=true'
nc_case lnd lnd.service "/usr/local/bin/lnd --configfile=/data/lnd/lnd.conf --tor.skip-proxy-for-clearnet-targets=true" /data/lnd/lnd.conf "$clean_lnd"
assert_equals "clearnet" "${SN_OUT%%$'\n'*}" "ExecStart: LND --tor.skip-proxy-for-clearnet-targets=true with a clean config is clearnet"
assert_contains "$SN_OUT" "lnd.service ExecStart: --tor.skip-proxy-for-clearnet-targets=true" "ExecStart: the argument is reported with the unit"
nc_case lnd lnd.service "/usr/local/bin/lnd --tor.skip-proxy-for-clearnet-targets --configfile=/data/lnd/lnd.conf" /data/lnd/lnd.conf "$clean_lnd"
assert_equals "clearnet" "${SN_OUT%%$'\n'*}" "ExecStart: LND bare --tor.skip-proxy-for-clearnet-targets is clearnet"
nc_case lnd lnd.service "/usr/local/bin/lnd --configfile=/data/lnd/lnd.conf --tor.skip-proxy-for-clearnet-targets=false" /data/lnd/lnd.conf "$clean_lnd"
assert_equals "clean" "${SN_OUT%%$'\n'*}" "ExecStart: LND --tor.skip-proxy-for-clearnet-targets=false is clean"
nc_case lnd lnd.service "/usr/local/bin/lnd --configfile=/data/lnd/lnd.conf --externalhosts=203.0.113.5:24556" /data/lnd/lnd.conf "$clean_lnd"
assert_equals "clearnet" "${SN_OUT%%$'\n'*}" "ExecStart: LND --externalhosts=... is clearnet"
nc_case lnd lnd.service "/usr/local/bin/lnd --externalhosts 203.0.113.5:24556 --configfile=/data/lnd/lnd.conf" /data/lnd/lnd.conf "$clean_lnd"
assert_contains "$SN_OUT" "lnd.service ExecStart: --externalhosts=203.0.113.5:24556" "ExecStart: LND --externalhosts <value> (separate argument) is clearnet"
nc_case lnd lnd.service "/usr/local/bin/lnd --alias=a;b --configfile=/data/lnd/lnd.conf --externalhosts=203.0.113.5:24556" /data/lnd/lnd.conf "$clean_lnd"
assert_equals "clearnet" "${SN_OUT%%$'\n'*}" "ExecStart: a ';' inside an argument does not cut the command line short"
nc_case lit litd.service "/usr/local/bin/litd --lnd.externalhosts=203.0.113.5:24556" /home/bitcoin/.lit/lit.conf $'lnd-mode=integrated'
assert_equals "clearnet" "${SN_OUT%%$'\n'*}" "ExecStart: LIT --lnd.externalhosts is clearnet"
clean_cln=$'proxy=127.0.0.1:9050\nalways-use-proxy=true'
for arg in "--bind-addr=0.0.0.0:9735" "--announce-addr=203.0.113.7:24556" "--addr=0.0.0.0:9735" "--always-use-proxy=false" "--always-use-proxy false"; do
    nc_case cln lightningd.service "/usr/bin/lightningd --conf=/etc/cln/config ${arg}" /etc/cln/config "$clean_cln"
    assert_equals "clearnet" "${SN_OUT%%$'\n'*}" "ExecStart: CLN ${arg} is clearnet"
done
for arg in "--announce-addr=abcdefghijklmnop.onion:9735" "--addr=127.0.0.1:9736" "--always-use-proxy=true" "--bind-addr=127.0.0.1:9736"; do
    nc_case cln lightningd.service "/usr/bin/lightningd --conf=/etc/cln/config ${arg}" /etc/cln/config "$clean_cln"
    assert_equals "clean" "${SN_OUT%%$'\n'*}" "ExecStart: CLN ${arg} is clean"
done
nc_case lnd lnd.service "/bin/sh -c /usr/local/bin/lnd --configfile=/data/lnd/lnd.conf" /data/lnd/lnd.conf "$clean_lnd"
assert_equals "unknown" "${SN_OUT%%$'\n'*}" "ExecStart: a command line that runs through sh -c is unknown"
assert_contains "$SN_OUT" "runs through a shell (/bin/sh)" "ExecStart: the reason names the shell"
nc_case lnd lnd.service "/usr/local/bin/lnd --configfile=/data/lnd/lnd.conf \$LND_ARGS" /data/lnd/lnd.conf "$clean_lnd"
assert_equals "unknown" "${SN_OUT%%$'\n'*}" "ExecStart: \$VAR expansion is unknown"
assert_contains "$SN_OUT" "takes values from environment variables" "ExecStart: the reason names the environment variables"
nc_case lnd lnd.service "/usr/local/bin/lnd --configfile=/data/lnd/lnd.conf --externalhosts=\${TS_HOST}" /data/lnd/lnd.conf "$clean_lnd"
assert_equals "unknown" "${SN_OUT%%$'\n'*}" "ExecStart: \${VAR} expansion (EnvironmentFile values) is unknown"
nc_case lnd lnd.service "/usr/local/bin/start-lnd --configfile=/data/lnd/lnd.conf" /data/lnd/lnd.conf "$clean_lnd" /usr/local/bin/start-lnd
assert_equals "unknown" "${SN_OUT%%$'\n'*}" "ExecStart: a wrapper script is unknown"
assert_contains "$SN_OUT" "runs the script /usr/local/bin/start-lnd" "ExecStart: the reason names the script"
fx=$(new_fixture nc-noexec)
echo "bitcoin" > "$fx/state/unit_lnd.service_User"
mkdir -p "$fx/fs/home/bitcoin/.lnd"
printf '%s\n' "$clean_lnd" > "$fx/fs/home/bitcoin/.lnd/lnd.conf"
run_snippet "$fx" 'ts_m_node_config_clearnet lnd lnd.service; echo "$TS_M_NC_STATUS reason=$TS_M_NC_REASON"'
assert_contains "$SN_OUT" "unknown reason=the command line (ExecStart) of lnd.service cannot be read" "ExecStart: no readable ExecStart is unknown"
printf '{ path=/a ; argv[]=/usr/local/bin/lnd ; ignore_errors=no ; start_time=[n/a] } { path=/b ; argv[]=/usr/local/bin/lnd ; ignore_errors=no ; start_time=[n/a] }' > "$fx/state/unit_lnd.service_ExecStart"
run_snippet "$fx" 'ts_m_node_config_clearnet lnd lnd.service; echo "$TS_M_NC_STATUS"'
assert_equals "unknown" "$SN_OUT" "ExecStart: two command lines are unknown"

# uninstall: a command line that cannot be checked leaves Lightning stopped with the reason
fx=$(new_fixture nc-uninstall)
mkdir -p "$fx/fs/data/lnd"
printf '%s\n' "$clean_lnd" > "$fx/fs/data/lnd/lnd.conf"
printf '{ path=/bin/sh ; argv[]=/bin/sh -c /usr/local/bin/lnd --configfile=/data/lnd/lnd.conf ; ignore_errors=no ; start_time=[n/a] }' > "$fx/state/unit_lnd.service_ExecStart"
echo "bitcoin" > "$fx/state/unit_lnd.service_User"
echo "active" > "$fx/state/unit_lnd.service_ActiveState"
mkdir -p "$fx/fs/etc/tunnelsats"
write_inventory "$fx"
run_snippet "$fx" "TS_JSON=1; TS_NONINTERACTIVE=1; TS_COMMAND=uninstall; TS_OUT_FD=1; TS_OPT_YES=1; cmd_uninstall_managed"
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["ln_started"], d["node_config"], d["action_required"]["reason"], "runs through a shell" in d["action_required"]["detail"]]' \
    '[false, "unknown", "node_config_unknown", true]' "Uninstall: a command line that cannot be checked leaves Lightning stopped, with the reason"
assert_not_contains "$(cat "$fx/state/calls")" "systemctl start lnd.service" "Uninstall: Lightning is not started"
assert_json "$doc" '[d["ln_disabled"], d["action_required"]["then"]]' '[true, "systemctl enable --now lnd.service"]' \
    "Uninstall: the unit is disabled, and the action says how to enable it again"
assert_contains "$(cat "$fx/state/calls")" "systemctl disable lnd.service" "Uninstall: the disable goes through systemd"

# uninstall while Lightning was not running: with settings that cannot be checked, the unit is
# disabled all the same, so no boot starts it outside the tunnel; a failed disable is an error
fx=$(new_fixture nc-uninstall-stopped)
mkdir -p "$fx/fs/data/lnd"
printf '%s\n' "$clean_lnd" > "$fx/fs/data/lnd/lnd.conf"
printf '{ path=/bin/sh ; argv[]=/bin/sh -c /usr/local/bin/lnd --configfile=/data/lnd/lnd.conf ; ignore_errors=no ; start_time=[n/a] }' > "$fx/state/unit_lnd.service_ExecStart"
echo "bitcoin" > "$fx/state/unit_lnd.service_User"
mkdir -p "$fx/fs/etc/tunnelsats"
write_inventory "$fx"
touch "$fx/state/fail_systemctl_disable_lnd.service"
run_snippet "$fx" "TS_JSON=1; TS_NONINTERACTIVE=1; TS_COMMAND=uninstall; TS_OUT_FD=1; TS_OPT_YES=1; cmd_uninstall_managed"
assert_equals "1" "$SN_RC" "Uninstall: a unit that cannot be disabled exits 1"
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["ln_was_active"], d["ln_started"], d["ln_disabled"], d["action_required"]["reason"], d["action_required"]["then"]]' \
    '[false, false, false, "node_config_unknown", "systemctl disable lnd.service"]' \
    "Uninstall: not running before, settings unchecked: the action is to disable the unit"
assert_json "$doc" '[e["code"] for e in d["errors"]]' '["E_LN_DISABLE"]' "Uninstall: the failed disable is reported as an error"
assert_contains "$SN_OUT" "could not be disabled" "Uninstall: and printed"
assert_not_contains "$(cat "$fx/state/calls")" "systemctl start lnd.service" "Uninstall: Lightning is not started"

# uninstall after the verifier stopped Lightning (no protection held): it counts as running before,
# so with a clean node config Lightning starts again; the record is gone before anything else
fx=$(new_fixture uninstall-after-quarantine)
mkdir -p "$fx/fs/data/lnd" "$fx/fs/run/tunnelsats"
printf '%s\n' "$clean_lnd" > "$fx/fs/data/lnd/lnd.conf"
printf '{ path=/usr/local/bin/lnd ; argv[]=/usr/local/bin/lnd --configfile=/data/lnd/lnd.conf ; ignore_errors=no ; start_time=[n/a] }' > "$fx/state/unit_lnd.service_ExecStart"
echo "bitcoin" > "$fx/state/unit_lnd.service_User"
echo "lnd.service stopped" > "$fx/fs/run/tunnelsats/stopped-units"
mkdir -p "$fx/fs/etc/tunnelsats"
write_inventory "$fx"
run_snippet "$fx" "TS_JSON=1; TS_NONINTERACTIVE=1; TS_COMMAND=uninstall; TS_OUT_FD=1; TS_OPT_YES=1; cmd_uninstall_managed"
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["ln_was_active"], d["ln_started"], d["node_config"]]' '[true, true, "clean"]' \
    "Uninstall: Lightning stopped by the verifier counts as running before and starts again with a clean config"
if [[ -e "$fx/fs/run/tunnelsats/stopped-units" ]]; then
    fail "Uninstall: the record of stopped units is removed"
else
    pass "Uninstall: the record of stopped units is removed"
fi

# ---------------------------------------------------------------------------
# GROUP 6: verify verdicts and checks
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 6: verify ---"

verdict_case() {  # $1 = emergency, then "id:class:result" triples
    local fx emergency="$1" spec snippet="TS_V_ID=(); TS_V_CLASS=(); TS_V_RESULT=(); TS_V_DETAIL=();"
    shift
    fx=$(new_fixture verdict)
    for spec in "$@"; do
        snippet+=" ts_v_add ${spec//:/ } detail;"
    done
    snippet+=" ts_v_verdict $emergency; echo \"\$TS_V_VERDICT \$TS_V_EXIT \$TS_V_CLEARNET_BLOCKED\""
    run_snippet "$fx" "$snippet"
}
verdict_case 0 attest:unsafe:pass egress_probe:unsafe:pass wg_handshake:degraded:pass
assert_equals "protected 0 0" "$SN_OUT" "Verdict: protected only when every check passes"
verdict_case 0 attest:unsafe:pass egress_probe:degraded:fail wg_handshake:degraded:fail
assert_equals "degraded 5 1" "$SN_OUT" "Verdict: degraded with clearnet_blocked when only the tunnel checks fail"
verdict_case 0 attest:unsafe:fail wg_handshake:degraded:fail
assert_equals "unsafe 4 0" "$SN_OUT" "Verdict: any unsafe failure is unsafe"
verdict_case 1 attest:unsafe:fail nft_killswitch:unsafe:fail
assert_equals "degraded 5 1" "$SN_OUT" "Verdict: the armed emergency block is degraded, never protected"

# Full verify on an armed fixture with prepared probe answers
fx=$(new_fixture verify)
mkdir -p "$fx/fs/etc/tunnelsats" "$fx/fs/sys/fs/cgroup/tunnelsats.slice/lnd.service" "$fx/fs/proc/4242"
write_inventory "$fx"
run_snippet "$fx" 'ts_m_killswitch_apply baremetal lnd lnd.service 1001 0 >/dev/null'
cp "$fx/../render/sub.conf" "$fx/fs/etc/wireguard/tunnelsatsv2.conf"
sed -i 's/de2.tunnelsats.com:51820/198.18.2.1:51820/' "$fx/fs/etc/wireguard/tunnelsatsv2.conf"
echo "4242" > "$fx/fs/sys/fs/cgroup/tunnelsats.slice/lnd.service/cgroup.procs"
echo "0::/tunnelsats.slice/lnd.service" > "$fx/fs/proc/4242/cgroup"
echo "active" > "$fx/state/unit_lnd.service_ActiveState"
echo "/tunnelsats.slice/lnd.service" > "$fx/state/unit_lnd.service_ControlGroup"
echo "tunnelsats.slice" > "$fx/state/unit_lnd.service_Slice"
echo "/lib/systemd/system/lnd.service.d/x.conf /etc/systemd/system/lnd.service.d/tunnelsats-managed.conf" > "$fx/state/unit_lnd.service_DropInPaths"
touch "$fx/state/link_tunnelsatsv2"
printf 'default dev tunnelsatsv2 scope link \n' >> "$fx/state/routes4"
# The kill switch probe sends one datagram to the WireGuard endpoint (198.18.2.1), which a working
# kill switch stops on the host (EPERM); the IPv6 probe sends one to the TunnelSats host's IPv6
# address (stand-in 2001:db8:113::40); the echo services answer the egress probe through the tunnel
probe_ok() {
    printf 'cgroup /tunnelsats.slice/run-u1.service\nsend 198.18.2.1 EPERM\n' > "$fx/state/probe_send4"
    printf 'cgroup /tunnelsats.slice/run-u2.service\nanswer http://203.0.113.10/ 198.18.2.1\nanswer http://203.0.113.11/ 198.18.2.1\n' > "$fx/state/probe_egress4"
    printf 'cgroup /tunnelsats.slice/run-u3.service\nsend 2001:db8:113::40 EPERM\n' > "$fx/state/probe_send6"
}
probe_ok
wg_up() {
    cat > "$STUB_BIN/wg" <<'EOF'
#!/bin/bash
case "$3" in
    latest-handshakes) echo "c2VydmVyLXB1YmxpYy1rZXktZm9yLXRlc3RzLTAwMDA9	$(( $(date +%s) - 20 ))" ;;
    endpoints) echo "c2VydmVyLXB1YmxpYy1rZXktZm9yLXRlc3RzLTAwMDA9	198.18.2.1:51820" ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$STUB_BIN/wg"
}
wg_up
probe_urls='export TS_VERIFY_ECHO_URLS="http://203.0.113.10/ http://203.0.113.11/" TS_VERIFY_IPV6_URL="http://[2001:db8:113::40]/" WG_BIN="'"$STUB_BIN"'/wg";'
verify_env="$probe_urls TS_JSON=1; TS_COMMAND=verify; TS_OUT_FD=1;"
human_env="$probe_urls TS_COMMAND=verify;"
verify_doc() {
    run_snippet "$fx" "$verify_env $1 cmd_verify"
    doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
}
check_detail() {  # $1 = check id: prints "<class>:<result>: <detail>" of the last verify_doc
    json_eval "$doc" "[c['class'] + ':' + c['result'] + ': ' + c['detail'] for c in d['checks'] if c['id'] == '$1'][0]" 2>/dev/null || echo "<missing>"
}
: > "$fx/state/calls"
verify_doc ""
assert_equals "0" "$SN_RC" "verify: protected exits 0"
assert_json "$doc" '[d["verdict"], d["clearnet_blocked"], d["emergency_block"], d["emergency_state"], d["managed"], d["probes"], d["install_state"]]' '["protected", false, false, "none", true, "run", "installed"]' "verify: protected document"
assert_json "$doc" '[c["id"] for c in d["checks"]]' '["install_state", "attest", "nft_killswitch", "slice_id", "ip_rules", "table_51820", "ln_dropin", "ln_membership", "killswitch_probe", "egress_probe", "ipv6_probe", "wg_handshake", "wg_endpoint"]' \
    "verify: the bare-metal checks in order"
assert_json "$doc" '[c["id"] for c in d["checks"] if c["result"] != "pass"]' '[]' "verify: every check passes on the armed fixture"
assert_json "$doc" 'd["endpoint"]' '{"host": "198.18.2.1", "ipv4": "198.18.2.1", "port": 51820, "vpn_port": 24556}' "verify: endpoint object"
assert_not_contains "$SN_OUT" "dHVubmVsc2F0cy10ZXN0LXByaXZhdGUta2V5LTAwMDE=" "verify: never prints the private key"
assert_not_contains "$doc" "direct" "verify: no direct address is fetched or reported"
assert_equals "unsafe:pass: a datagram from inside the slice to 198.18.2.1 through eth0 was stopped on this host (EPERM)" "$(check_detail killswitch_probe)" \
    "verify: the kill switch datagram was stopped on the host"
calls=$(cat "$fx/state/calls")
assert_equals "0" "$(grep -c '^curl ' "$fx/state/calls" || true)" "verify: nothing is fetched outside the slice"
assert_contains "$calls" "managed-probe send 4 eth0 198.18.2.1" "verify: the kill switch probe sends to the WireGuard endpoint, bound to the regular interface"
assert_contains "$calls" "managed-probe send 6 - 2001:db8:113::40" "verify: the IPv6 probe sends to the TunnelSats host's IPv6 address, unbound"
assert_not_contains "$(grep 'send 4' "$fx/state/calls")" "--uid=" "verify: the kill switch probe runs as root (the cgroup classification on its own)"
assert_contains "$(grep 'egress4' "$fx/state/calls")" "--uid=bitcoin" "verify: the egress probe runs as the node user"
assert_not_contains "$(grep '^ip ' "$fx/state/calls" | grep -v 'route get 198.18.2.1')" "route get" "verify: the kill switch probe needs no name lookup, only the route to the endpoint"
run_snippet "$fx" "$human_env cmd_verify"
assert_contains "$SN_OUT" "Protected" "verify (human): Protected"
run_snippet "$fx" "$human_env TS_OPT_NO_PROBE=1; cmd_verify"
assert_contains "$SN_OUT" "Protected (kernel checks only, probes skipped)" "verify (human): --no-probe says kernel checks only"

# The IPv6 target host name is resolved as root, outside the slice (IPv4-mapped answers ignored)
printf '::ffff:203.0.113.40 STREAM ts-host.test\n2001:db8:113::41 STREAM ts-host.test\n' > "$fx/state/resolve6_ts-host.test"
printf 'cgroup /tunnelsats.slice/run-u3.service\nsend 2001:db8:113::41 EPERM\n' > "$fx/state/probe_send6"
: > "$fx/state/calls"
verify_doc 'TS_VERIFY_IPV6_URL=https://ts-host.test;'
assert_contains "$(cat "$fx/state/calls")" "managed-probe send 6 - 2001:db8:113::41" "verify: the IPv6 host name is resolved outside the slice, without IPv4-mapped answers"
assert_json "$doc" 'd["verdict"]' 'protected' "verify: the resolved IPv6 probe passes"
probe_ok

# A host without IPv6 (no /proc/net/if_inet6): the IPv6 probe is skipped, not failed
mv "$fx/fs/proc/net/if_inet6" "$fx/if_inet6.saved"
: > "$fx/state/calls"
verify_doc ""
assert_equals "unsafe:skip: not run: this host has no IPv6" "$(check_detail ipv6_probe)" "verify: a host without IPv6 skips the IPv6 probe"
assert_json "$doc" 'd["verdict"]' 'protected' "verify: and stays protected"
assert_not_contains "$(cat "$fx/state/calls")" "send 6" "verify: no IPv6 datagram on a host without IPv6"
mv "$fx/if_inet6.saved" "$fx/fs/proc/net/if_inet6"

# The kill switch datagram leaves the host: unsafe, and the echo services and the IPv6 probe are
# never contacted
printf 'cgroup /tunnelsats.slice/run-u1.service\nsend 198.18.2.1 sent\n' > "$fx/state/probe_send4"
: > "$fx/state/calls"
verify_doc ""
assert_equals "4" "$SN_RC" "verify: a kill switch datagram that leaves the host exits 4"
assert_equals "unsafe:fail: a datagram from inside the slice to 198.18.2.1 through eth0 left this host; nothing stopped it" "$(check_detail killswitch_probe)" \
    "verify: the kill switch probe names the datagram that left"
assert_equals "unsafe:skip: not run: the kill switch probe did not pass, so the echo services were not contacted" "$(check_detail egress_probe)" \
    "verify: the egress probe is then skipped, with the reason"
assert_equals "unsafe:skip: not run: the kill switch probe did not pass" "$(check_detail ipv6_probe)" "verify: the IPv6 probe is skipped as well"
assert_not_contains "$(cat "$fx/state/calls")" "egress4" "verify: the echo services are not contacted while the direct path is open"
assert_not_contains "$(cat "$fx/state/calls")" "send 6" "verify: no IPv6 datagram either"
run_snippet "$fx" "$human_env cmd_verify"
assert_contains "$SN_OUT" "Not protected" "verify (human): unsafe says Not protected"
assert_contains "$SN_OUT" "  - killswitch_probe: a datagram from inside the slice to 198.18.2.1 through eth0 left this host" "verify (human): and lists the failing checks"
printf 'cgroup /tunnelsats.slice/run-u1.service\nsend 198.18.2.1 error:no-perl\n' > "$fx/state/probe_send4"
verify_doc ""
assert_json "$doc" '[d["verdict"], [c["detail"] for c in d["checks"] if c["id"] == "killswitch_probe"][0]]' '["unsafe", "could not run (error:no-perl)"]' "verify: a kill switch probe that cannot run counts as unsafe"
printf 'cgroup /tunnelsats.slice/run-u1.service\nsend 198.18.2.1 ECONNREFUSED\n' > "$fx/state/probe_send4"
verify_doc ""
assert_json "$doc" 'd["verdict"]' 'unsafe' "verify: an errno outside the local classes counts as unsafe"
probe_ok

# The gate: a kernel check of the unsafe class that failed keeps the echo services and the IPv6
# probe off, even when the kill switch datagram was stopped; a Lightning unit that is only stopped
# (degraded) does not
cp "$fx/state/nft_table" "$fx/state/nft_table.saved"
rm -f "$fx/state/nft_table"
: > "$fx/state/calls"
verify_doc ""
assert_equals "unsafe:skip: not run: nft_killswitch did not pass, so the echo services were not contacted" "$(check_detail egress_probe)" \
    "verify: a failed kernel check keeps the echo services off"
assert_equals "unsafe:skip: not run: nft_killswitch did not pass" "$(check_detail ipv6_probe)" "verify: and the IPv6 probe"
assert_not_contains "$(cat "$fx/state/calls")" "egress4" "verify: no echo service is contacted after a failed kernel check"
mv "$fx/state/nft_table.saved" "$fx/state/nft_table"
echo "inactive" > "$fx/state/unit_lnd.service_ActiveState"
: > "$fx/state/calls"
verify_doc ""
assert_equals "degraded:fail: lnd.service is inactive" "$(check_detail ln_membership)" "verify: a stopped Lightning unit is degraded"
assert_contains "$(cat "$fx/state/calls")" "egress4" "verify: a stopped Lightning unit does not keep the echo services off"
echo "active" > "$fx/state/unit_lnd.service_ActiveState"

# An IPv6 datagram from the slice leaves the host: unsafe
printf 'cgroup /tunnelsats.slice/run-u3.service\nsend 2001:db8:113::40 sent\n' > "$fx/state/probe_send6"
verify_doc ""
assert_equals "4" "$SN_RC" "verify: an IPv6 datagram that leaves the host exits 4"
assert_json "$doc" '[e["code"] for e in d["errors"] if e["class"] == "unsafe"]' '["E_IPV6_PROBE"]' "verify: unsafe names the IPv6 probe"
probe_ok

# Tunnel down: no interface, no route, no answers: degraded with clearnet_blocked
rm -f "$fx/state/link_tunnelsatsv2"
sed -i '/tunnelsatsv2/d' "$fx/state/routes4"
printf 'cgroup /tunnelsats.slice/run-u2.service\nanswer http://203.0.113.10/ -\nanswer http://203.0.113.11/ -\n' > "$fx/state/probe_egress4"
printf '#!/bin/bash\nexit 1\n' > "$STUB_BIN/wg"
verify_doc ""
assert_equals "5" "$SN_RC" "verify: tunnel down exits 5"
assert_json "$doc" '[d["verdict"], d["clearnet_blocked"]]' '["degraded", true]' "verify: tunnel down is degraded with clearnet_blocked"
run_snippet "$fx" "$human_env cmd_verify"
assert_contains "$SN_OUT" "Tunnel down: clearnet traffic blocked, the kill switch holds" "verify (human): tunnel down text"

# The home address seen from inside the slice: unsafe
printf 'cgroup /tunnelsats.slice/run-u2.service\nanswer http://203.0.113.10/ 198.18.1.1\nanswer http://203.0.113.11/ 198.18.1.1\n' > "$fx/state/probe_egress4"
verify_doc ""
assert_equals "4" "$SN_RC" "verify: an egress address other than the endpoint exits 4"
assert_json "$doc" '[e["code"] for e in d["errors"] if e["class"] == "unsafe"]' '["E_EGRESS_PROBE"]' "verify: unsafe names the egress probe"

# Only one echo service answered: the egress is not confirmed
printf 'cgroup /tunnelsats.slice/run-u2.service\nanswer http://203.0.113.10/ 198.18.2.1\nanswer http://203.0.113.11/ -\n' > "$fx/state/probe_egress4"
verify_doc ""
assert_json "$doc" '[c["class"] + ":" + c["result"] for c in d["checks"] if c["id"] == "egress_probe"]' '["degraded:fail"]' "verify: one answering echo service does not confirm the egress"

# Probe that did not run inside the slice: cannot run counts as unsafe
printf 'cgroup /user.slice/run-u2.service\nanswer http://203.0.113.10/ -\nanswer http://203.0.113.11/ -\n' > "$fx/state/probe_egress4"
verify_doc ""
assert_equals "4" "$SN_RC" "verify: a probe outside the slice counts as unsafe"

# --no-probe: kernel checks only
verify_doc "TS_OPT_NO_PROBE=1;"
assert_json "$doc" '[d["probes"], "egress_probe" in [c["id"] for c in d["checks"]]]' '["skipped", false]' "verify --no-probe: no probe checks"

# A missing IPv4 tunnel route is degraded only on its own: any other table problem, IPv6 included,
# keeps table_51820 unsafe (checked with --no-probe, where no probe can make the verdict unsafe)
wg_up
touch "$fx/state/link_tunnelsatsv2"
cp "$fx/state/routes6" "$fx/state/routes6.saved"
: > "$fx/state/routes6"
verify_doc "TS_OPT_NO_PROBE=1;"
assert_json "$doc" '[d["verdict"], d["clearnet_blocked"], [c["class"] + ":" + c["result"] for c in d["checks"] if c["id"] == "table_51820"][0]]' \
    '["unsafe", false, "unsafe:fail"]' "verify: a missing IPv4 tunnel route plus a missing IPv6 blackhole is unsafe (--no-probe)"
mv "$fx/state/routes6.saved" "$fx/state/routes6"
verify_doc "TS_OPT_NO_PROBE=1;"
assert_json "$doc" '[d["verdict"], [c["class"] + ":" + c["result"] for c in d["checks"] if c["id"] == "table_51820"][0]]' \
    '["degraded", "degraded:fail"]' "verify: the missing tunnel route on its own is degraded"

# The endpoint host name is resolved once, for at most TS_VERIFY_RESOLVE_TIMEOUT seconds (default
# 5): a name server that does not answer holds verify up for that long at most (a start guard runs
# verify before every Lightning start), and wg_endpoint names the lookup that got no answer
run_snippet "$fx" 'for v in "" 1 7 999 0 1000 abc " 5" 5s; do printf "[%s]=%s " "$v" "$(TS_VERIFY_RESOLVE_TIMEOUT="$v" ts_v_resolve_timeout || echo refused)"; done'
assert_equals "[]=5 [1]=1 [7]=7 [999]=999 [0]=refused [1000]=refused [abc]=refused [ 5]=refused [5s]=refused " "$SN_OUT" \
    "verify: the endpoint lookup timeout defaults to 5 s and takes 1 to 999 s"
verify_doc "TS_OPT_NO_PROBE=1; export TS_VERIFY_RESOLVE_TIMEOUT=abc;"
assert_json "$doc" '[d["exit_code"], d["errors"][0]["code"], d["errors"][0]["message"]]' \
    '[2, "E_USAGE", "TS_VERIFY_RESOLVE_TIMEOUT must be a whole number of seconds from 1 to 999"]' "verify: an invalid lookup timeout is a usage error"
cat > "$TMP_ROOT/getent-silent" <<EOF
#!/bin/bash
# getent whose host lookups get no answer (a silent name server); everything else as the stub
if [[ "\$1" == "ahostsv4" ]]; then sleep 20; fi
exec "$STUB_BIN/getent" "\$@"
EOF
chmod +x "$TMP_ROOT/getent-silent"
sed -i 's/198.18.2.1:51820/vpn.ts-host.test:51820/' "$fx/fs/etc/wireguard/tunnelsatsv2.conf"
lookup_started=$SECONDS
verify_doc "TS_OPT_NO_PROBE=1; GETENT_BIN='$TMP_ROOT/getent-silent'; export TS_VERIFY_RESOLVE_TIMEOUT=1;"
lookup_secs=$((SECONDS - lookup_started))
assert_equals "degraded:fail: the lookup of the configured endpoint vpn.ts-host.test got no answer within 1 s" "$(check_detail wg_endpoint)" \
    "verify: an endpoint lookup that gets no answer is reported as such"
assert_json "$doc" '[d["exit_code"], d["endpoint"]["host"], d["endpoint"]["ipv4"]]' '[5, "vpn.ts-host.test", null]' \
    "verify: degraded, with the host name and no address"
if [[ "$lookup_secs" -lt 10 ]]; then
    pass "verify: the lookup is cut off after the timeout (${lookup_secs} s)"
else
    fail "verify: the lookup is cut off after the timeout (took ${lookup_secs} s)"
fi
verify_doc "TS_OPT_NO_PROBE=1;"
assert_equals "degraded:fail: the configured endpoint vpn.ts-host.test does not resolve" "$(check_detail wg_endpoint)" \
    "verify: a name that does not resolve is reported as before"
echo "198.18.2.1" > "$fx/state/resolve_vpn.ts-host.test"
verify_doc "TS_OPT_NO_PROBE=1;"
assert_equals "degraded:pass: 198.18.2.1:51820" "$(check_detail wg_endpoint)" "verify: a resolved host name is compared with the live endpoint"
assert_json "$doc" 'd["endpoint"]["ipv4"]' "198.18.2.1" "verify: and reported with its address"
rm -f "$fx/state/resolve_vpn.ts-host.test"
sed -i 's/vpn.ts-host.test:51820/198.18.2.1:51820/' "$fx/fs/etc/wireguard/tunnelsatsv2.conf"

# Emergency block armed and verified while the kill switch table is in place too (the fixture's
# attestation stays valid), as after a re-arm before the release: degraded while no probe gets
# through. The kill chain stops the slice's direct path then, so the kill switch probe runs as root,
# bound to the regular interface (EPERM); the echo services and the IPv6 probe are not contacted
# while emergency rules are present.
wg_up
touch "$fx/state/link_tunnelsatsv2"
printf 'default dev tunnelsatsv2 scope link \n' >> "$fx/state/routes4"
# $1 = what stops the kill switch datagram: EPERM (the kill chain, default) or EINVAL (uid blackhole)
probe_emergency() {
    probe_ok
    printf 'cgroup /tunnelsats.slice/run-u1.service\nsend 198.18.2.1 %s\n' "${1:-EPERM}" > "$fx/state/probe_send4"
    printf 'cgroup /tunnelsats.slice/run-u2.service\nanswer http://203.0.113.10/ -\nanswer http://203.0.113.11/ -\n' > "$fx/state/probe_egress4"
}
probe_emergency
run_snippet "$fx" 'ts_m_emergency_arm 1001 && echo ARMED'
assert_contains "$SN_OUT" "ARMED" "Emergency verify fixture: block armed"
: > "$fx/state/calls"
verify_doc ""
assert_equals "5" "$SN_RC" "verify: emergency block with nothing getting through exits 5"
assert_json "$doc" '[d["verdict"], d["clearnet_blocked"], d["emergency_block"], d["emergency_state"]]' '["degraded", true, true, "active"]' "verify: emergency block is degraded with clearnet_blocked"
assert_equals "degraded:pass: the local network stays reachable (7 exemptions at priority 21817)" "$(check_detail emergency_lan)" \
    "verify: under the emergency block the local network stays reachable"
sed -i '/to 10\.0\.0\.0\/8 uidrange 1001-1001/d' "$fx/state/rules4"
verify_doc "TS_OPT_NO_PROBE=1;"
assert_json "$doc" '[d["verdict"], d["emergency_state"], [c["class"] + ":" + c["result"] + ": " + c["detail"] for c in d["checks"] if c["id"] == "emergency_lan"][0]]' \
    '["degraded", "active", "degraded:fail: 1 of 7 local network exemptions at priority 21817 are missing: Lightning cannot reach those local networks"]' \
    "verify: a missing local network exemption is reported, the block stays in effect"
run_snippet "$fx" 'ts_m_emergency_arm 1001 >/dev/null'
: > "$fx/state/calls"
verify_doc ""
assert_not_contains "$(grep 'send 4' "$fx/state/calls")" "--uid=" "verify: with the kill switch table in place the kill switch probe runs as root, emergency rules or not"
assert_contains "$(cat "$fx/state/calls")" "managed-probe send 4 eth0 198.18.2.1" "verify: bound to the regular interface, so it tests the kill chain"
assert_equals "unsafe:pass: a datagram from inside the slice to 198.18.2.1 through eth0 was stopped on this host (EPERM)" "$(check_detail killswitch_probe)" \
    "verify: the kill chain stops the kill switch datagram"
assert_equals "unsafe:skip: not run: emergency rules are present (the verifier removes them once the kill switch is armed), so the echo services were not contacted" \
    "$(check_detail egress_probe)" "verify: while emergency rules are present the echo services are not contacted"
assert_equals "unsafe:skip: not run: emergency rules are present (the verifier removes them once the kill switch is armed)" "$(check_detail ipv6_probe)" \
    "verify: nor the IPv6 probe"
assert_equals "" "$(grep -E 'egress4|send 6' "$fx/state/calls" || true)" "verify: no echo or IPv6 probe unit is started"
run_snippet "$fx" "$human_env cmd_verify"
assert_contains "$SN_OUT" "Emergency block active: Lightning clearnet traffic blocked, Tor and the local network keep working" "verify (human): emergency text"
printf 'cgroup /tunnelsats.slice/run-u1.service\nsend 198.18.2.1 sent\n' > "$fx/state/probe_send4"
verify_doc ""
assert_json "$doc" '[d["verdict"], d["emergency_block"]]' '["unsafe", true]' "verify: under the emergency block a kill switch datagram that leaves is unsafe"
# The block armed because the kill switch could not be (its table is gone): the kill switch probe
# runs as the node user with an unbound socket, as the daemon's sockets are, and meets the uid
# blackhole (EINVAL); the gate stays closed, so only that probe runs, and the verdict stays degraded
probe_emergency EINVAL
cp "$fx/state/nft_table" "$fx/state/nft_table.saved"
rm -f "$fx/state/nft_table"
: > "$fx/state/calls"
verify_doc ""
assert_json "$doc" '[d["verdict"], d["clearnet_blocked"], d["emergency_block"]]' '["degraded", true, true]' \
    "verify: the emergency block without a kill switch is degraded while its datagram is stopped"
assert_contains "$(grep 'send 4' "$fx/state/calls")" "--uid=bitcoin" "verify: without the kill switch table the kill switch probe runs as the node user"
assert_contains "$(cat "$fx/state/calls")" "managed-probe send 4 - 198.18.2.1" "verify: with an unbound socket, as the daemon's sockets are"
assert_equals "unsafe:pass: a datagram from inside the slice to 198.18.2.1 was stopped on this host (EINVAL)" "$(check_detail killswitch_probe)" \
    "verify: the uid blackhole stops the node user's datagram"
assert_equals "unsafe:skip: not run: nft_killswitch did not pass, so the echo services were not contacted" "$(check_detail egress_probe)" \
    "verify: under the emergency block a failed kernel check keeps the echo services off"
assert_not_contains "$(cat "$fx/state/calls")" "send 6" "verify: and the IPv6 probe off"
# A rule of another tool before the emergency block (priority 100, lookup main) routes the node's
# traffic around it: present but not in effect is unsafe, with and without --no-probe, and the rule
# is named. The kill switch probe still runs as the node user, unbound, and its datagram gets out.
printf '100:\tfrom all lookup main\n' >> "$fx/state/rules4"
verify_doc "TS_OPT_NO_PROBE=1;"
assert_equals "4" "$SN_RC" "verify --no-probe: an emergency block with a rule of another tool before it exits 4"
assert_json "$doc" '[d["verdict"], d["clearnet_blocked"], d["emergency_block"], d["emergency_state"]]' '["unsafe", false, false, "bypassed"]' \
    "verify --no-probe: unsafe, never reported as blocked, emergency_state bypassed"
assert_equals "unsafe:fail: present for uid 1001 but not in effect: IPv4 rule before 21818: 100: from all lookup main" "$(check_detail emergency_block)" \
    "verify --no-probe: the emergency_block check names the rule"
assert_json "$doc" '"E_EMERGENCY_BLOCK" in [e["code"] for e in d["errors"] if e["class"] == "unsafe"]' 'true' "verify --no-probe: reported as E_EMERGENCY_BLOCK"
printf 'cgroup /tunnelsats.slice/run-u1.service\nsend 198.18.2.1 sent\n' > "$fx/state/probe_send4"
: > "$fx/state/calls"
verify_doc ""
assert_json "$doc" '[d["verdict"], d["clearnet_blocked"], d["emergency_block"], d["emergency_state"]]' '["unsafe", false, false, "bypassed"]' "verify: with probes as well"
assert_contains "$(grep 'send 4' "$fx/state/calls")" "--uid=bitcoin" "verify: the kill switch probe runs as the node user while emergency rules are present"
assert_contains "$(cat "$fx/state/calls")" "managed-probe send 4 - 198.18.2.1" "verify: with an unbound socket, as the daemon's sockets are"
assert_equals "unsafe:fail: a datagram from inside the slice to 198.18.2.1 left this host; nothing stopped it" "$(check_detail killswitch_probe)" \
    "verify: the node user's datagram gets around the block"
run_snippet "$fx" "$human_env cmd_verify"
assert_contains "$SN_OUT" "Not protected" "verify (human): an emergency block that is not in effect is Not protected"
assert_not_contains "$SN_OUT" "Emergency block active" "verify (human): and is never called active"
assert_contains "$SN_OUT" "  - emergency_block: present for uid 1001 but not in effect: IPv4 rule before 21818: 100: from all lookup main" \
    "verify (human): the failing check names the rule"
# Tailscale's rules without an exit node do not count: the block is in effect, degraded
sed -i '/^100:/d' "$fx/state/rules4"
printf '5210:\tfrom all fwmark 0x80000/0xff0000 lookup main\n5270:\tfrom all lookup 52\n' >> "$fx/state/rules4"
probe_emergency EINVAL
verify_doc "TS_OPT_NO_PROBE=1;"
assert_json "$doc" '[d["verdict"], d["clearnet_blocked"], d["emergency_block"]]' '["degraded", true, true]' \
    "verify --no-probe: with Tailscale's rules (no exit node) the emergency block is in effect, degraded"
assert_equals "unsafe:pass: in effect for uid 1001 (priority 21818 and 21819), no rule of another tool before it" "$(check_detail emergency_block)" \
    "verify --no-probe: the emergency_block check passes"
verify_doc ""
assert_json "$doc" '[d["verdict"], d["clearnet_blocked"], d["emergency_block"]]' '["degraded", true, true]' "verify: with probes as well"
sed -i '/^52[17]0:/d' "$fx/state/rules4"
# Only part of the block in place (the IPv6 rule missing): not in effect either, emergency_state
# incomplete
sed -i '/^21819:/d' "$fx/state/rules6"
verify_doc "TS_OPT_NO_PROBE=1;"
assert_json "$doc" '[d["verdict"], d["clearnet_blocked"], d["emergency_block"], d["emergency_state"]]' '["unsafe", false, false, "incomplete"]' \
    "verify --no-probe: a partly armed emergency block is unsafe, emergency_state incomplete"
assert_equals "unsafe:fail: present for uid 1001 but not in effect: not all of its rules (priority 21818 and 21819) are in place" "$(check_detail emergency_block)" \
    "verify --no-probe: the emergency_block check says the rules are incomplete"
run_snippet "$fx" 'ts_m_emergency_arm 1001 >/dev/null'
mv "$fx/state/nft_table.saved" "$fx/state/nft_table"
# Emergency rules left beside an armed kill switch, as during a release (only the IPv6 blackhole is
# left): not in effect, but the kill switch holds, so degraded, not unsafe; the kill switch probe
# runs as root through the regular interface and the echo services are not contacted
probe_emergency
sed -i '/^2181[789]:.*1001-1001/d' "$fx/state/rules4"
sed -i '/^21817:.*1001-1001/d' "$fx/state/rules6"
: > "$fx/state/calls"
verify_doc ""
assert_equals "5" "$SN_RC" "verify: emergency rules left beside an armed kill switch exit 5"
assert_json "$doc" '[d["verdict"], d["clearnet_blocked"], d["emergency_block"], d["emergency_state"], [c["result"] for c in d["checks"] if c["id"] in ("killswitch_probe", "egress_probe", "ipv6_probe")]]' \
    '["degraded", true, false, "incomplete", ["pass", "skip", "skip"]]' "verify: leftover emergency rules beside an armed kill switch are degraded, incomplete"
assert_equals "degraded:fail: present for uid 1001 but not in effect: not all of its rules (priority 21818 and 21819) are in place; the kill switch is armed, and the verifier removes these rules" \
    "$(check_detail emergency_block)" "verify: the emergency_block check is degraded while the kill switch table matches"
assert_contains "$(cat "$fx/state/calls")" "managed-probe send 4 eth0 198.18.2.1" "verify: the kill switch probe runs as root through the regular interface"
assert_equals "" "$(grep -E 'egress4|send 6' "$fx/state/calls" || true)" "verify: and the echo services are not contacted"
printf '100:\tfrom all lookup main\n' >> "$fx/state/rules4"
verify_doc "TS_OPT_NO_PROBE=1;"
assert_json "$doc" '[d["verdict"], d["emergency_state"], [c["class"] + ":" + c["result"] for c in d["checks"] if c["id"] == "ip_rules"][0]]' '["unsafe", "incomplete", "unsafe:fail"]' \
    "verify --no-probe: a rule of another tool before them still fails ip_rules as unsafe"
sed -i '/^100:/d' "$fx/state/rules4"
run_snippet "$fx" 'ts_m_emergency_release 1001'
probe_ok

# A damaged install record: verify reports install_state damaged and checks the emergency block for
# the uid that the kill switch unit's ExecStart carries; degraded while the block is in effect, with
# the action to take
cp "$fx/fs/etc/tunnelsats/managed.json" "$fx/managed.json.saved"
echo "garbage" > "$fx/fs/etc/tunnelsats/managed.json"
printf '{ path=/usr/local/sbin/tunnelsats ; argv[]=/usr/local/sbin/tunnelsats managed-arm --fallback-uid 1001 ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }\n' \
    > "$fx/state/unit_tunnelsats-killswitch.service_ExecStart"
run_snippet "$fx" 'ts_m_emergency_arm 1001 >/dev/null'
printf 'cgroup /tunnelsats.slice/run-u1.service\nsend 198.18.2.1 EINVAL\n' > "$fx/state/probe_send4"
: > "$fx/state/calls"
verify_doc ""
assert_equals "5" "$SN_RC" "verify: a damaged install record behind the emergency block exits 5"
assert_json "$doc" '[d["verdict"], d["clearnet_blocked"], d["emergency_block"], d["emergency_state"], d["install_state"], d["unit"], d["action_required"]["reason"]]' \
    '["degraded", true, true, "active", "damaged", null, "install_record_damaged"]' "verify: damaged record: degraded and blocked, with the action to take"
assert_contains "$(json_eval "$doc" 'd["action_required"]["detail"]')" "restore /etc/tunnelsats/managed.json (for example from a backup) or reinstall" \
    "verify: damaged record: the action names the record"
assert_json "$doc" '[c["id"] + ":" + c["result"] for c in d["checks"] if c["id"] in ("install_state", "emergency_block", "emergency_lan", "killswitch_probe", "egress_probe", "ipv6_probe")]' \
    '["install_state:fail", "emergency_block:pass", "emergency_lan:pass", "killswitch_probe:pass", "egress_probe:skip", "ipv6_probe:skip"]' \
    "verify: damaged record: the block, the exemptions and the kill switch probe; the echo services stay off"
assert_contains "$(grep 'send 4' "$fx/state/calls")" "--uid=1001" "verify: damaged record: the kill switch probe runs as the fallback uid"
run_snippet "$fx" "$human_env cmd_verify"
assert_contains "$SN_OUT" "install record damaged" "verify (human): names the damaged record"
assert_contains "$SN_OUT" "Action required: restore /etc/tunnelsats/managed.json (for example from a backup) or reinstall" "verify (human): and the action"
# A missing record of a managed install (its kill switch unit still carries the uid) is damaged too,
# never a standard install
rm -f "$fx/fs/etc/tunnelsats/managed.json"
verify_doc "TS_OPT_NO_PROBE=1;"
assert_json "$doc" '[d["verdict"], d["install_state"], d["managed"], d["emergency_state"], [c["detail"] for c in d["checks"] if c["id"] == "install_state"][0]]' \
    '["degraded", "damaged", true, "active", "the install record cannot be read (/etc/tunnelsats/managed.json is missing)"]' \
    "verify: a missing record of a managed install is reported as damaged"
echo "garbage" > "$fx/fs/etc/tunnelsats/managed.json"
# Without the block, or without a fallback uid: unsafe
run_snippet "$fx" 'ts_m_emergency_release 1001'
verify_doc "TS_OPT_NO_PROBE=1;"
assert_json "$doc" '[d["verdict"], d["emergency_state"], d["install_state"]]' '["unsafe", "none", "damaged"]' "verify: a damaged record without the block is unsafe"
assert_equals "unsafe:fail: not armed for uid 1001" "$(check_detail emergency_block)" "verify: damaged record: the missing block is named"
rm -f "$fx/state/unit_tunnelsats-killswitch.service_ExecStart"
verify_doc "TS_OPT_NO_PROBE=1;"
assert_equals "unsafe:fail: tunnelsats-killswitch.service carries no fallback uid, so the emergency block cannot be checked" "$(check_detail emergency_block)" \
    "verify: damaged record without a fallback uid is unsafe, with the reason"
mv "$fx/managed.json.saved" "$fx/fs/etc/tunnelsats/managed.json"
probe_ok

# No install at all
fx=$(new_fixture noinstall)
run_snippet "$fx" 'TS_JSON=1; TS_COMMAND=verify; TS_OUT_FD=1; cmd_verify'
assert_equals "3" "$SN_RC" "verify: no install exits 3"
assert_contains "$SN_OUT" '"code":"E_NOT_INSTALLED"' "verify: no install reports E_NOT_INSTALLED"

# A standard (legacy) install: verdict unmanaged (exit 9), never protected or unsafe
fx=$(new_fixture unmanaged)
cp "$TMP_ROOT/fx/render/sub.conf" "$fx/fs/etc/wireguard/tunnelsatsv2.conf"
printf '#Tunnelsats-Setupv2-Non-Docker\nPostUp = nft add table ip %%i\n' >> "$fx/fs/etc/wireguard/tunnelsatsv2.conf"
printf '#!/bin/bash\n' > "$fx/fs/etc/wireguard/tunnelsats-route-guard.sh"
touch "$fx/state/legacy_table_ip_tunnelsatsv2" "$fx/state/link_tunnelsatsv2"
wg_up
run_snippet "$fx" "$verify_env cmd_verify"
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_equals "9" "$SN_RC" "verify: a standard install exits 9"
assert_json "$doc" '[d["verdict"], d["managed"], d["install_kind"], d["clearnet_blocked"], d["emergency_state"], [c["id"] + ":" + c["result"] for c in d["checks"]]]' \
    '["unmanaged", false, "legacy_v3_post_204", false, "none", ["wg_handshake:pass", "legacy_killswitch:pass"]]' "verify: unmanaged document with the checks that apply"
assert_json "$doc" '[e["code"] + ":" + e["class"] for e in d["errors"]]' '["E_UNMANAGED:unmanaged"]' "verify: unmanaged is reported as such, not as unsafe"
run_snippet "$fx" "$human_env cmd_verify"
assert_contains "$SN_OUT" "Standard install: the tunnel is up (handshake 20 s ago) and its kill switch is active while the tunnel stays up. Managed mode keeps it armed across restarts: see https://github.com/Tunnelsats/tunnelsats/blob/main/docs/managed-mode.md." \
    "verify (human): standard install text"
assert_not_contains "$SN_OUT" "Not protected" "verify (human): a standard install is never called not protected"
printf '#!/bin/bash\nexit 1\n' > "$STUB_BIN/wg"
rm -f "$fx/state/legacy_table_ip_tunnelsatsv2"
run_snippet "$fx" "$human_env cmd_verify"
assert_contains "$SN_OUT" "Standard install: the tunnel is not up right now; its kill switch is active while the tunnel is up." "verify (human): standard install with the tunnel down"
wg_up

# ---------------------------------------------------------------------------
# GROUP 7: CLI options
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 7: CLI options ---"

parse_state() {
    bash -c 'source "$1"; shift; ts_parse_cli "$@"; echo "cmd=${TS_COMMAND} managed=${TS_OPT_MANAGED} profile=${TS_OPT_PROFILE} backstop=${TS_OPT_UID_BACKSTOP} noprobe=${TS_OPT_NO_PROBE} error=${TS_USAGE_ERROR}"' _ "$SCRIPT_UNDER_TEST" "$@"
}
assert_equals "cmd=install managed=1 profile=baremetal backstop=1 noprobe=0 error=" "$(parse_state install --managed baremetal --uid-backstop)" "CLI: install --managed baremetal --uid-backstop"
assert_equals "cmd=uninstall managed=1 profile= backstop=0 noprobe=0 error=" "$(parse_state uninstall --managed --yes)" "CLI: uninstall --managed takes no profile"
assert_equals "cmd=install managed=1 profile= backstop=0 noprobe=0 error=" "$(parse_state --managed install)" "CLI: a command word after --managed is not a profile"
assert_equals "cmd=verify managed=0 profile= backstop=0 noprobe=1 error=" "$(parse_state verify --no-probe)" "CLI: verify --no-probe"

cli() {
    set +e
    CLI_OUT=$(bash "$SCRIPT_UNDER_TEST" "$@" 2>/dev/null </dev/null)
    CLI_RC=$?
    set -e
}
cli --json install --uid-backstop
assert_equals "2" "$CLI_RC" "CLI: --uid-backstop without --managed exits 2"
assert_json "$CLI_OUT" 'd["errors"][0]["message"]' "--uid-backstop requires --managed" "CLI: --uid-backstop without --managed is a usage error"
cli --json verify --managed
assert_json "$CLI_OUT" 'd["errors"][0]["message"]' "--managed is not supported by 'verify'" "CLI: verify rejects --managed"
cli --json uninstall --managed --impl lnd
assert_json "$CLI_OUT" 'd["errors"][0]["code"]' "E_USAGE" "CLI: uninstall --managed rejects --impl"
cli --json install
assert_json "$CLI_OUT" 'd["errors"][0]["code"]' "E_JSON_UNSUPPORTED" "CLI: legacy install still has no --json"
cli --json status
assert_json "$CLI_OUT" 'd["errors"][0]["code"]' "E_JSON_UNSUPPORTED" "CLI: status has no --json"
cli help
assert_contains "$CLI_OUT" "install --managed baremetal" "Help: documents the managed install"
assert_contains "$CLI_OUT" "Exit codes: 0 success, 1 failure, 2 usage error or interaction required" "Help: the original exit codes line is unchanged"
assert_contains "$CLI_OUT" "4 unsafe" "Help: documents the verify exit codes"
assert_contains "$CLI_OUT" "9 unmanaged (verify on a standard install)" "Help: documents exit code 9"

if [[ "$EUID" -ne 0 ]]; then
    cli --json verify
    assert_equals "2" "$CLI_RC" "CLI: verify without root exits 2"
    assert_json "$CLI_OUT" 'd["errors"][0]["code"]' "E_NOT_ROOT" "CLI: verify without root reports E_NOT_ROOT"
    cli --json uninstall --managed
    assert_json "$CLI_OUT" 'd["errors"][0]["code"]' "E_NOT_ROOT" "CLI: uninstall --managed without root reports E_NOT_ROOT"
fi

# Legacy install and uninstall leave a managed install alone. The refusal comes before the root
# check, so it runs unprivileged; skipped as root, where a broken refusal would run the legacy
# command on this machine.
if [[ "$EUID" -ne 0 ]]; then
    fx=$(new_fixture legacycmd)
    mkdir -p "$fx/fs/etc/tunnelsats"
    write_inventory "$fx"
    for c in install uninstall; do
        set +e
        CLI_OUT=$(TS_FS_ROOT="$fx/fs" bash "$SCRIPT_UNDER_TEST" "$c" --non-interactive 2>&1 </dev/null)
        CLI_RC=$?
        set -e
        assert_equals "7" "$CLI_RC" "CLI: legacy ${c} is refused while a managed install exists"
        assert_contains "$CLI_OUT" "uninstall --managed" "CLI: legacy ${c} points to uninstall --managed"
    done
fi

# ---------------------------------------------------------------------------
# GROUP 8: detect on a managed install
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 8: detect ---"

fx=$(new_fixture detect)
mkdir -p "$fx/fs/etc/tunnelsats"
write_inventory "$fx"
run_snippet "$fx" 'ts_m_killswitch_apply baremetal lnd lnd.service 1001 0 >/dev/null; ts_m_render_slice_unit > "$TS_FS_ROOT/etc/systemd/system/tunnelsats.slice"'
run_snippet "$fx" 'TS_JSON=1; TS_COMMAND=detect; TS_OUT_FD=1; cmd_detect'
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["install"]["kind"], d["install"]["managed_state"]]' '["managed", "installed"]' "detect: a managed install is kind managed, with its state"
assert_json "$doc" 'next(c["status"] for c in d["conflicts"] if c["id"] == "table_51820_foreign_routes")' "not_detected" \
    "detect: the managed blackhole is not a foreign route"
rm -f "$fx/fs/etc/tunnelsats/managed.json"
run_snippet "$fx" 'TS_JSON=1; TS_COMMAND=detect; TS_OUT_FD=1; cmd_detect'
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["install"]["kind"], d["install"]["candidates"]]' '["unknown", ["managed"]]' "detect: managed units without the inventory are unknown (candidate managed)"

# ---------------------------------------------------------------------------
# GROUP 9: Install files and removal
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 9: Install files and removal ---"

# Writes the managed files into fixture $1 with the production ts_m_install_files (write-ahead
# inventory, state installing), records the enabled units and flips the state like install does.
install_files_fixture() {
    cp "$TMP_ROOT/fx/render/sub.conf" "$1/sub.conf"
    printf '#!/bin/bash\necho tunnelsats\n' > "$1/tunnelsats.sh"
    run_snippet "$1" '
TS_SCRIPT_PATH="$PWD/tunnelsats.sh" TS_M_SANITIZED="$PWD/sub.conf" TS_M_UNIT=lnd.service
TS_M_INV_PROFILE=baremetal TS_M_INV_IMPL=lnd TS_M_INV_UNIT=lnd.service TS_M_INV_USER=bitcoin TS_M_INV_UID=1001 TS_M_INV_BACKSTOP=0
TS_M_FILES=() TS_M_FILE_SHA=() TS_M_CREATED_DIRS=() TS_M_ENABLED_UNITS=()
ts_m_install_files || { echo "install files failed"; exit 1; }
echo "state after files: $(ts_m_inventory_state)"
TS_M_ENABLED_UNITS=(tunnelsats-killswitch.service tunnelsats-verifier.timer wg-quick@tunnelsatsv2.service)
TS_M_INV_STATE=installed
ts_m_inventory_write || { echo "inventory write failed"; exit 1; }
ts_m_killswitch_apply baremetal lnd lnd.service 1001 0 >/dev/null || { echo "arm failed"; exit 1; }
echo "recorded=${#TS_M_FILES[@]}"'
}

managed_files='["/etc/systemd/system/lnd.service.d/tunnelsats-managed.conf", "/etc/systemd/system/tunnelsats-killswitch.service", "/etc/systemd/system/tunnelsats-verifier.service", "/etc/systemd/system/tunnelsats-verifier.timer", "/etc/systemd/system/tunnelsats.slice", "/etc/systemd/system/wg-quick@tunnelsatsv2.service.d/tunnelsats-managed.conf", "/etc/wireguard/tunnelsatsv2.conf", "/usr/local/sbin/tunnelsats"]'

fx=$(new_fixture files)
install_files_fixture "$fx"
assert_equals "0" "$SN_RC" "Install files: every file written"
assert_contains "$SN_OUT" "recorded=8" "Install files: all eight files recorded in the installing shell"
inv_doc=$(cat "$fx/fs/etc/tunnelsats/managed.json" 2>/dev/null || true)
assert_json "$inv_doc" 'sorted(f["path"] for f in d["files"])' "$managed_files" "Install files: the inventory lists every managed file"
assert_json "$inv_doc" 'all(len(f["sha256"]) == 64 for f in d["files"])' 'true' "Install files: each file with its sha256"
assert_json "$inv_doc" 'd["dirs_created"]' '["/etc/tunnelsats", "/etc/systemd/system/lnd.service.d", "/etc/systemd/system/wg-quick@tunnelsatsv2.service.d"]' \
    "Install files: the created directories are recorded, the existing ones are not"
assert_equals "600" "$(stat -c %a "$fx/fs/etc/wireguard/tunnelsatsv2.conf")" "Install files: tunnel config mode 0600"
assert_equals "755" "$(stat -c %a "$fx/fs/usr/local/sbin/tunnelsats")" "Install files: script copy mode 0755"

# Removal: a record that misses a file (an interrupted install) still removes every managed file;
# files and directories that are not managed stay
mkdir -p "$fx/fs/etc/systemd/system/lnd.service.d"
echo "[Service]" > "$fx/fs/etc/systemd/system/lnd.service.d/override.conf"
: > "$fx/state/calls"
run_snippet "$fx" '
ts_m_inventory_read || { echo "read failed: $TS_M_ERROR"; exit 1; }
for i in "${!TS_M_FILES[@]}"; do
    if [[ "${TS_M_FILES[$i]}" == */tunnelsats-killswitch.service ]]; then unset "TS_M_FILES[$i]" "TS_M_FILE_SHA[$i]"; fi
done
ts_m_remove_dataplane
echo "remaining=${#TS_M_REMAINING[@]}:${TS_M_REMAINING[*]}"'
assert_equals "0" "$SN_RC" "Removal: completes"
assert_contains "$SN_OUT" "remaining=0:" "Removal: nothing remains"
left=""
for f in /etc/systemd/system/lnd.service.d/tunnelsats-managed.conf /etc/systemd/system/tunnelsats-killswitch.service \
    /etc/systemd/system/tunnelsats-verifier.service /etc/systemd/system/tunnelsats-verifier.timer /etc/systemd/system/tunnelsats.slice \
    /etc/systemd/system/wg-quick@tunnelsatsv2.service.d /etc/wireguard/tunnelsatsv2.conf /usr/local/sbin/tunnelsats /etc/tunnelsats /run/tunnelsats; do
    if [[ -e "$fx/fs$f" ]]; then left+=" $f"; fi
done
assert_equals "" "$left" "Removal: every managed file and created directory is gone (the unrecorded kill switch unit too)"
if [[ -f "$fx/fs/etc/systemd/system/lnd.service.d/override.conf" ]] && [[ -d "$fx/fs/etc/wireguard" ]]; then
    pass "Removal: the operator's drop-in, its directory and /etc/wireguard stay"
else
    fail "Removal: the operator's drop-in, its directory and /etc/wireguard stay"
fi
calls=$(cat "$fx/state/calls")
assert_contains "$calls" "systemctl disable wg-quick@tunnelsatsv2.service" "Removal: disables the units install enabled"
assert_contains "$calls" "nft delete table inet tunnelsats" "Removal: deletes the kill switch table"
assert_not_contains "$(cat "$fx/state/rules4")" "2182" "Removal: the policy rules are gone"

# Removal read-back through systemd: a unit whose file systemd still has loaded, a slice that is
# still active, a Lightning unit that still loads the drop-in and a leftover enablement link are
# reported as remaining. A slice that systemd loads without a unit file is not (real systemd
# shows LoadState=loaded for any slice name).
fx=$(new_fixture removal-readback)
install_files_fixture "$fx"
mkdir -p "$fx/fs/etc/systemd/system/multi-user.target.wants"
ln -s /etc/systemd/system/tunnelsats-killswitch.service "$fx/fs/etc/systemd/system/multi-user.target.wants/tunnelsats-killswitch.service"
echo "/etc/systemd/system/tunnelsats-verifier.timer" > "$fx/state/unit_tunnelsats-verifier.timer_FragmentPath"
echo "active" > "$fx/state/unit_tunnelsats.slice_ActiveState"
echo "/etc/systemd/system/lnd.service.d/tunnelsats-managed.conf" > "$fx/state/unit_lnd.service_DropInPaths"
run_snippet "$fx" '
ts_m_inventory_read || { echo "read failed: $TS_M_ERROR"; exit 1; }
ts_m_remove_dataplane
printf "remaining: %s\n" "${TS_M_REMAINING[@]}"'
assert_contains "$SN_OUT" "remaining: tunnelsats-verifier.timer (systemd: /etc/systemd/system/tunnelsats-verifier.timer, inactive)" \
    "Removal read-back: a unit file systemd still has loaded is remaining"
assert_contains "$SN_OUT" "remaining: tunnelsats.slice (systemd: no unit file, active)" "Removal read-back: a slice that is still active is remaining"
assert_contains "$SN_OUT" "remaining: lnd.service still loads tunnelsats-managed.conf" "Removal read-back: the Lightning drop-in still loaded is remaining"
assert_contains "$SN_OUT" "remaining: /etc/systemd/system/multi-user.target.wants/tunnelsats-killswitch.service" "Removal read-back: a leftover enablement link is remaining"
fx=$(new_fixture removal-slice)
install_files_fixture "$fx"
echo "loaded" > "$fx/state/unit_tunnelsats.slice_LoadState"
run_snippet "$fx" '
ts_m_inventory_read || { echo "read failed: $TS_M_ERROR"; exit 1; }
ts_m_remove_dataplane
echo "remaining=${#TS_M_REMAINING[@]}:${TS_M_REMAINING[*]}"'
assert_contains "$SN_OUT" "remaining=0:" "Removal read-back: an inactive slice without a unit file counts as removed although systemd loads it"

# A removal that fails keeps the record: the inventory says "removing" and lists what remained, and
# the script copy and the emergency records stay. uninstall --managed repeated once the cause is
# gone removes everything.
fx=$(new_fixture removal-retry)
install_files_fixture "$fx"
run_snippet "$fx" 'ts_m_emergency_arm 1001 >/dev/null && echo ARMED'
assert_contains "$SN_OUT" "ARMED" "Failed removal fixture: emergency block armed"
printf '%s\n' "rule del from all fwmark 0x1000000/0xff000000 lookup 51820 priority 21821" \
    "rule del priority 21819 uidrange 1001-1001 blackhole" > "$fx/state/fail_ip"
run_snippet "$fx" '
ts_m_inventory_read || { echo "read failed: $TS_M_ERROR"; exit 1; }
ts_m_remove_dataplane
printf "remaining: %s\n" "${TS_M_REMAINING[@]}"'
assert_contains "$SN_OUT" "remaining: still present: " "Failed removal: the rule that could not be deleted is remaining"
assert_contains "$SN_OUT" "remaining: emergency rules at priority 21817-21819" "Failed removal: the emergency rule that could not be deleted is remaining"
inv_doc=$(cat "$fx/fs/etc/tunnelsats/managed.json" 2>/dev/null || true)
assert_json "$inv_doc" '[d["state"], len(d["files"]), any("21821" in r for r in d["remaining"]), "emergency rules at priority 21817-21819" in d["remaining"]]' \
    '["removing", 8, true, true]' "Failed removal: the inventory stays, says removing and lists what remained"
if [[ -f "$fx/fs/usr/local/sbin/tunnelsats" ]] && [[ -f "$fx/fs/etc/wireguard/.tunnelsats-failclosed-rules" ]]; then
    pass "Failed removal: the script copy and the emergency record stay"
else
    fail "Failed removal: the script copy and the emergency record stay"
fi
run_snippet "$fx" 'ts_m_inventory_read && echo "read ok: ${TS_M_INV_STATE} ${#TS_M_INV_REMAINING[@]}"'
assert_contains "$SN_OUT" "read ok: removing 2" "Failed removal: the kept inventory reads back with its remaining items"
run_snippet "$fx" 'TS_JSON=1; TS_COMMAND=detect; TS_OUT_FD=1; cmd_detect'
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["install"]["kind"], d["install"]["managed_state"]]' '["managed", "removing"]' "Failed removal: detect reports managed_state removing"
run_snippet "$fx" "TS_JSON=1; TS_COMMAND=verify; TS_OUT_FD=1; TS_OPT_NO_PROBE=1; cmd_verify"
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["verdict"], [c["result"] + ": " + c["detail"] for c in d["checks"] if c["id"] == "install_state"][0]]' \
    "[\"unsafe\", \"fail: an uninstall did not complete (state removing); run 'tunnelsats.sh uninstall --managed' again\"]" \
    "Failed removal: verify reports the incomplete uninstall as unsafe"
rm -f "$fx/state/fail_ip"
run_snippet "$fx" "TS_JSON=1; TS_COMMAND=uninstall; TS_OUT_FD=1; TS_OPT_YES=1; cmd_uninstall_managed"
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["exit_code"], d["remaining"]]' '[0, []]' "Repeated uninstall: completes with nothing remaining"
left=""
for f in /etc/tunnelsats /usr/local/sbin/tunnelsats /etc/wireguard/.tunnelsats-failclosed-rules /run/tunnelsats \
    /etc/systemd/system/tunnelsats-killswitch.service /etc/systemd/system/lnd.service.d/tunnelsats-managed.conf; do
    if [[ -e "$fx/fs$f" ]]; then left+=" $f"; fi
done
assert_equals "" "$left" "Repeated uninstall: the record, the script copy, the emergency record and the runtime state are gone"
assert_not_contains "$(cat "$fx/state/rules4")" "2182" "Repeated uninstall: the policy rules are gone"
assert_not_contains "$(cat "$fx/state/rules4")" "21819" "Repeated uninstall: the emergency rule is gone"

# ts_m_install_file records the file right after writing it, even when the checksum fails
fx=$(new_fixture record)
run_snippet "$fx" '
ts_m_sha256() { return 1; }
TS_M_FILES=() TS_M_FILE_SHA=()
echo x | ts_m_install_file /etc/systemd/system/tunnelsats.slice 0644 && echo "unexpected success"
echo "recorded=${TS_M_FILES[*]:-none}"
TS_M_FILES=() TS_M_FILE_SHA=()
ts_m_install_file /etc/systemd/system/tunnelsats.slice 0644 < <(echo x) || echo "checksum failure reported"
echo "recorded=${TS_M_FILES[*]:-none}"'
assert_contains "$SN_OUT" "recorded=none" "Record: the right-hand side of a pipeline cannot record (why install never pipes into it)"
assert_contains "$SN_OUT" "checksum failure reported" "Record: a failing checksum fails the write"
assert_contains "$SN_OUT" "recorded=/etc/systemd/system/tunnelsats.slice" "Record: the written file is recorded anyway, so removal deletes it"

echo ""
echo "--- Group 10: Write-ahead inventory, unit selection, preflight, probes ---"

# install files leaves the inventory in state installing; install flips it before units start
fx=$(new_fixture writeahead)
install_files_fixture "$fx"
assert_contains "$SN_OUT" "state after files: installing" "Write-ahead: the inventory stays installing until install flips it"

# An install interrupted at the third file: the inventory written first lists every planned file
# (sha256 null for those not written yet), and removal follows it completely
fx=$(new_fixture interrupted)
cp "$TMP_ROOT/fx/render/sub.conf" "$fx/sub.conf"
printf '#!/bin/bash\necho tunnelsats\n' > "$fx/tunnelsats.sh"
run_snippet "$fx" '
eval "$(declare -f ts_m_write_file | sed "1s/ts_m_write_file/orig_write_file/")"
ts_m_write_file() { if [[ "$1" == *tunnelsats-killswitch.service ]]; then cat >/dev/null; return 1; fi; orig_write_file "$@"; }
TS_SCRIPT_PATH="$PWD/tunnelsats.sh" TS_M_SANITIZED="$PWD/sub.conf" TS_M_UNIT=lnd.service
TS_M_INV_PROFILE=baremetal TS_M_INV_IMPL=lnd TS_M_INV_UNIT=lnd.service TS_M_INV_USER=bitcoin TS_M_INV_UID=1001 TS_M_INV_BACKSTOP=0
ts_m_install_files && echo "unexpected success"
echo done'
inv_doc=$(cat "$fx/fs/etc/tunnelsats/managed.json" 2>/dev/null || true)
assert_json "$inv_doc" '[d["state"], len(d["files"]), [f["path"].rsplit("/", 1)[1] for f in d["files"] if f["sha256"]]]' \
    '["installing", 8, ["tunnelsats", "tunnelsats.slice"]]' "Write-ahead: an interrupted install leaves every planned file listed, the written ones with sha256"
assert_json "$inv_doc" 'd["dirs_created"]' '["/etc/tunnelsats", "/etc/systemd/system/lnd.service.d", "/etc/systemd/system/wg-quick@tunnelsatsv2.service.d"]' \
    "Write-ahead: the planned directories are listed before they exist"
run_snippet "$fx" '
ts_m_inventory_read || { echo "read failed: $TS_M_ERROR"; exit 1; }
ts_m_remove_dataplane
echo "remaining=${#TS_M_REMAINING[@]}:${TS_M_REMAINING[*]}"'
assert_contains "$SN_OUT" "remaining=0:" "Write-ahead: removal follows an inventory in state installing"
left=""
for f in /usr/local/sbin/tunnelsats /etc/systemd/system/tunnelsats.slice /etc/tunnelsats; do
    if [[ -e "$fx/fs$f" ]]; then left+=" $f"; fi
done
assert_equals "" "$left" "Write-ahead: nothing of the interrupted install is left"
run_snippet "$fx" 'TS_JSON=1; TS_COMMAND=detect; TS_OUT_FD=1; cmd_detect'
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" 'd["install"]["kind"]' "none" "Write-ahead: detect finds nothing after the removal"

# --impl picks the unit of that implementation (decision f)
fx=$(new_fixture select)
echo "loaded" > "$fx/state/unit_lnd.service_LoadState"
echo "loaded" > "$fx/state/unit_lightningd.service_LoadState"
run_snippet "$fx" 'TS_OPT_IMPL=""; ts_m_select_ln_unit; echo "picked ${TS_M_UNIT}"'
assert_equals "7" "$SN_RC" "Unit selection: several Lightning units without --impl are refused"
assert_contains "$SN_OUT" "choose the one to tunnel with --impl" "Unit selection: the refusal names --impl"
run_snippet "$fx" 'TS_OPT_IMPL=cln; ts_m_select_ln_unit; echo "picked ${TS_M_UNIT} ${TS_M_IMPL} others=${TS_M_OTHER_UNITS[*]}"'
assert_contains "$SN_OUT" "picked lightningd.service cln others=lnd.service" "Unit selection: --impl cln picks lightningd.service and lists lnd.service as not tunneled"
echo "loaded" > "$fx/state/unit_litd.service_LoadState"
echo "loaded" > "$fx/state/unit_lit.service_LoadState"
run_snippet "$fx" 'TS_OPT_IMPL=lit; ts_m_select_ln_unit; echo "picked ${TS_M_UNIT}"'
assert_contains "$SN_OUT" "several units are installed (litd.service lit.service)" "Unit selection: two candidates of one implementation are refused"
rm -f "$fx/state/unit_lnd.service_LoadState"
run_snippet "$fx" 'TS_OPT_IMPL=lnd; ts_m_select_ln_unit; echo "picked ${TS_M_UNIT}"'
assert_contains "$SN_OUT" "--impl lnd: no unit of this implementation is installed" "Unit selection: --impl without a unit is refused"

# A lone tunnelsatsv2.conf gets its own refusal (decision g)
fx=$(new_fixture loneconf)
cp "$TMP_ROOT/fx/render/sub.conf" "$fx/fs/etc/wireguard/tunnelsatsv2.conf"
run_snippet "$fx" 'TS_JSON=1; TS_COMMAND=install; TS_OUT_FD=1; ts_m_install_preflight'
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_equals "7" "$SN_RC" "Preflight: an existing tunnelsatsv2.conf is refused"
assert_json "$doc" 'd["errors"][0]["code"]' "E_CONFIG_PRESENT" "Preflight: with its own error code"
assert_contains "$SN_OUT" "if it is your own file, move it elsewhere" "Preflight: the message covers both cases"

# Each other refusal on a fixture that passes every remaining check (the real preflight)
preflight_fixture() {
    local pf
    pf=$(new_fixture "pf-$1")
    echo "loaded" > "$pf/state/unit_lnd.service_LoadState"
    echo "bitcoin" > "$pf/state/unit_lnd.service_User"
    echo "$pf"
}
preflight() {
    run_snippet "$1" "${2:-}"'
TS_JSON=1; TS_COMMAND=install; TS_OUT_FD=1; ts_m_install_preflight && echo PREFLIGHT_OK'
    doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
}
fx=$(preflight_fixture ok)
preflight "$fx"
assert_contains "$SN_OUT" "PREFLIGHT_OK" "Preflight: a clean bare-metal node passes"
fx=$(preflight_fixture platform)
preflight "$fx" "TS_OPT_PLATFORM=raspiblitz;"
assert_json "$doc" 'd["errors"][0]["code"]' "E_PLATFORM_UNSUPPORTED" "Preflight: other platforms are refused for now"
fx=$(preflight_fixture cgroup)
rm -f "$fx/fs/sys/fs/cgroup/cgroup.controllers"
preflight "$fx"
assert_json "$doc" 'd["errors"][0]["code"]' "E_CGROUP_V2_MISSING" "Preflight: no unified cgroup v2 hierarchy is refused"
fx=$(preflight_fixture rootuser)
rm -f "$fx/state/unit_lnd.service_User"
preflight "$fx"
assert_json "$doc" 'd["errors"][0]["code"]' "E_LN_USER" "Preflight: a Lightning unit that runs as root is refused"
fx=$(preflight_fixture tailscale)
echo "default dev tailscale0 table 52" > "$fx/state/table52"
preflight "$fx"
assert_json "$doc" 'd["errors"][0]["code"]' "E_TAILSCALE_EXIT_NODE" "Preflight: an active Tailscale exit node is refused"
fx=$(preflight_fixture table)
printf 'default via 192.0.2.99 dev eth9 \n' > "$fx/state/routes4"
preflight "$fx"
assert_json "$doc" 'd["errors"][0]["code"]' "E_TABLE_51820_IN_USE" "Preflight: routes of another tool in table 51820 are refused"
fx=$(preflight_fixture prio)
printf '21822:\tfrom all lookup main\n' > "$fx/state/rules4"
preflight "$fx"
assert_json "$doc" 'd["errors"][0]["code"]' "E_RULE_PRIORITY_IN_USE" "Preflight: a foreign rule at a TunnelSats priority is refused"
fx=$(preflight_fixture port)
mkdir -p "$fx/fs/home/bitcoin/.lnd"
printf 'listen=0.0.0.0:9736\n' > "$fx/fs/home/bitcoin/.lnd/lnd.conf"
preflight "$fx"
assert_json "$doc" 'd["errors"][0]["code"]' "E_LN_PORT" "Preflight: Lightning listening on another port than 9735 is refused"
fx=$(preflight_fixture systemd)
rm -rf "$fx/fs/run/systemd/system"
preflight "$fx"
assert_json "$doc" '[d["exit_code"], d["errors"][0]["code"]]' '[6, "E_SYSTEMD_MISSING"]' "Preflight: without systemd as PID 1 it is refused"
fx=$(preflight_fixture managed)
mkdir -p "$fx/fs/etc/tunnelsats"
echo '{}' > "$fx/fs/etc/tunnelsats/managed.json"
preflight "$fx"
assert_json "$doc" 'd["errors"][0]["code"]' "E_MANAGED_PRESENT" "Preflight: an existing managed install is refused"
fx=$(preflight_fixture legacy)
cp "$TMP_ROOT/fx/render/sub.conf" "$fx/fs/etc/wireguard/tunnelsatsv2.conf"
echo '#!/bin/bash' > "$fx/fs/etc/wireguard/tunnelsats-route-guard.sh"
preflight "$fx"
assert_json "$doc" 'd["errors"][0]["code"]' "E_LEGACY_INSTALL" "Preflight: a standard TunnelSats install is refused"
assert_contains "$SN_OUT" "Run 'tunnelsats.sh uninstall' first" "Preflight: the refusal points to uninstall"
fx=$(preflight_fixture nounit)
rm -f "$fx/state/unit_lnd.service_LoadState"
preflight "$fx"
assert_json "$doc" 'd["errors"][0]["code"]' "E_LN_UNIT" "Preflight: no Lightning unit is refused"
assert_contains "$SN_OUT" "No Lightning unit found" "Preflight: the refusal names the units it looked for"
fx=$(preflight_fixture dynuser)
echo "yes" > "$fx/state/unit_lnd.service_DynamicUser"
preflight "$fx"
assert_json "$doc" 'd["errors"][0]["code"]' "E_LN_USER" "Preflight: a Lightning unit with DynamicUser= is refused"
fx=$(preflight_fixture perl)
preflight "$fx" "PERL_BIN='$fx/no-such-perl';"
assert_json "$doc" '[d["exit_code"], d["errors"][0]["code"], d["errors"][0]["class"]]' '[6, "E_DEPENDENCY_MISSING", "capability"]' \
    "Preflight: a system without perl is refused (verify's datagram probes need it)"
assert_contains "$SN_OUT" "perl is missing" "Preflight: the refusal names perl"

# The capability probe loads the complete ruleset in a throwaway namespace, never on the host
fx=$(preflight_fixture capability)
mkdir -p "$fx/tmp"
run_snippet "$fx" "TS_M_TMP_DIR='$fx/tmp'; ts_m_capability_probe && echo PROBE_OK"
assert_contains "$SN_OUT" "PROBE_OK" "Capability probe: a kernel that accepts the ruleset passes"
assert_contains "$(cat "$fx/state/calls")" "nft [netns] -f $fx/tmp/probe.nft" "Capability probe: loads the ruleset in a throwaway namespace"
if [[ ! -e "$fx/state/nft_table" ]] && ! grep -q '^nft -f' "$fx/state/calls"; then
    pass "Capability probe: the host ruleset stays untouched"
else
    fail "Capability probe: the host ruleset stays untouched"
fi
touch "$fx/state/nft_refuse_all"
run_snippet "$fx" "TS_JSON=1; TS_COMMAND=install; TS_OUT_FD=1; TS_M_TMP_DIR='$fx/tmp'; ts_m_capability_probe && echo PROBE_OK"
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["exit_code"], d["errors"][0]["code"]]' '[6, "E_CAPABILITY_MISSING"]' "Capability probe: a kernel that refuses the ruleset is refused"

# The subscription config is checked before any change (exit 8)
fx=$(new_fixture config)
mkdir -p "$fx/tmp"
sed '/^Address/d' "$TMP_ROOT/fx/render/sub.conf" > "$fx/noaddr.conf"
sed 's|^AllowedIPs = .*|AllowedIPs = 10.0.0.0/8|' "$TMP_ROOT/fx/render/sub.conf" > "$fx/split.conf"
validate_config() {
    run_snippet "$fx" "TMPDIR='$fx/tmp'; TS_JSON=1; TS_COMMAND=install; TS_OUT_FD=1; CONFIG_FILE='$1'; ts_m_install_validate_config && echo CONFIG_OK"
    doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
}
validate_config "$TMP_ROOT/fx/render/sub.conf"
assert_contains "$SN_OUT" "CONFIG_OK" "Config: a subscription config passes"
validate_config "$fx/missing.conf"
assert_json "$doc" '[d["exit_code"], d["errors"][0]["code"]]' '[8, "E_CONFIG_INVALID"]' "Config: a missing file is refused"
validate_config "$fx/noaddr.conf"
assert_contains "$SN_OUT" "has no Address" "Config: a config without Address is refused"
validate_config "$fx/split.conf"
assert_contains "$SN_OUT" "AllowedIPs must include 0.0.0.0/0" "Config: AllowedIPs without 0.0.0.0/0 is refused"

# Non-interactive mode without --yes runs every check, then stops at the confirmation: nothing changed
fx=$(preflight_fixture confirm)
mkdir -p "$fx/tmp"
tree_before=$(cd "$fx/fs" && find . | sort)
run_snippet "$fx" "TMPDIR='$fx/tmp'; TS_JSON=1; TS_COMMAND=install; TS_OUT_FD=1; TS_NONINTERACTIVE=1; TS_OPT_PROFILE=baremetal; CONFIG_FILE='$TMP_ROOT/fx/render/sub.conf'; cmd_install_managed"
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["exit_code"], d["errors"][0]["code"]]' '[2, "E_INTERACTION_REQUIRED"]' "Install: non-interactive mode without --yes stops at the confirmation"
assert_contains "$(cat "$fx/state/calls")" "nft [netns] -f" "Install: the checks before the confirmation ran (capability probe)"
assert_equals "$tree_before" "$(cd "$fx/fs" && find . | sort)" "Install: no file was written before the confirmation"
assert_equals "" "$(grep -E '^(ip (-[46] )?(rule|route) (add|del|replace|flush)|nft -f|nft delete|systemctl (start|stop|restart|enable|disable|daemon-reload))' "$fx/state/calls" || true)" \
    "Install: no kernel or systemd change before the confirmation"

# Lifecycle lock: while one install or uninstall runs, another refuses with E_BUSY before it reads
# or changes anything; the kill switch lock stays free for the units. The test holds the lock on
# its own file descriptor, as a running install would.
fx=$(preflight_fixture busy)
mkdir -p "$fx/fs/run/tunnelsats" "$fx/tmp"
exec 7>"$fx/fs/run/tunnelsats/lifecycle.lock"
flock -n 7
tree_before=$(cd "$fx/fs" && find . | sort)
run_snippet "$fx" "TMPDIR='$fx/tmp'; TS_JSON=1; TS_COMMAND=install; TS_OUT_FD=1; TS_OPT_YES=1; TS_OPT_PROFILE=baremetal; CONFIG_FILE='$TMP_ROOT/fx/render/sub.conf'; cmd_install_managed"
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["exit_code"], d["errors"][0]["code"]]' '[7, "E_BUSY"]' "Lifecycle lock: install refuses while another install or uninstall runs"
assert_equals "$tree_before" "$(cd "$fx/fs" && find . | sort)" "Lifecycle lock: the refused install changed nothing"
mkdir -p "$fx/fs/etc/tunnelsats"
write_inventory "$fx"
run_snippet "$fx" "TS_JSON=1; TS_COMMAND=uninstall; TS_OUT_FD=1; TS_OPT_YES=1; cmd_uninstall_managed"
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["exit_code"], d["errors"][0]["code"]]' '[7, "E_BUSY"]' "Lifecycle lock: uninstall refuses as well"
if [[ -f "$fx/fs/etc/tunnelsats/managed.json" ]] && ! grep -qE '^systemctl (stop|disable)' "$fx/state/calls"; then
    pass "Lifecycle lock: the refused uninstall changed nothing"
else
    fail "Lifecycle lock: the refused uninstall changed nothing"
fi
run_snippet "$fx" 'ts_m_lock && echo KS_LOCK_FREE'
assert_contains "$SN_OUT" "KS_LOCK_FREE" "Lifecycle lock: the kill switch lock stays free for the units"
exec 7>&-
rm -f "$fx/fs/etc/tunnelsats/managed.json" "$fx/fs/run/tunnelsats/lock"
rmdir "$fx/fs/etc/tunnelsats"
run_snippet "$fx" "TMPDIR='$fx/tmp'; TS_JSON=1; TS_COMMAND=install; TS_OUT_FD=1; TS_NONINTERACTIVE=1; TS_OPT_PROFILE=baremetal; CONFIG_FILE='$TMP_ROOT/fx/render/sub.conf'; cmd_install_managed"
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" 'd["errors"][0]["code"]' "E_INTERACTION_REQUIRED" "Lifecycle lock: once released, the next install gets past it"
if [[ ! -e "$fx/fs/run/tunnelsats/lifecycle.lock" ]] && [[ ! -e "$fx/fs/run/tunnelsats" ]]; then
    pass "Lifecycle lock: a refused install leaves no lock file and no /run/tunnelsats behind"
else
    fail "Lifecycle lock: a refused install leaves no lock file and no /run/tunnelsats behind"
fi

# The datagram probe classes (ts_m_probe_classify): an immediate local error means the datagram was
# stopped on this host, "sent" means it left, any other word cannot tell and never passes
fx=$(new_fixture classify)
run_snippet "$fx" 'for w in EPERM EINVAL EHOSTUNREACH EACCES ENETUNREACH; do printf "%s " "$(ts_m_probe_classify "$w")"; done'
assert_equals "blocked blocked blocked blocked blocked " "$SN_OUT" \
    "Datagram classes: an nft drop (EPERM), a blackhole, unreachable or prohibit route or rule (EINVAL, EHOSTUNREACH, EACCES) and no route (ENETUNREACH) are stopped on this host"
run_snippet "$fx" 'ts_m_probe_classify sent'
assert_equals "left" "$SN_OUT" "Datagram classes: sent means the datagram left this host"
run_snippet "$fx" 'for w in ECONNREFUSED EAGAIN ENOBUFS error:helper error:no-perl error:bind-enodev ""; do printf "%s " "$(ts_m_probe_classify "$w")"; done'
assert_equals "error error error error error error error " "$SN_OUT" "Datagram classes: any other word cannot tell, never a pass"

# The datagram probe (ts_m_probe_send against a perl stub): the helper's one result word is passed
# on; any other output, a failing helper and a missing perl are errors
cat > "$STUB_BIN/perl-stub" <<'EOF'
#!/bin/bash
# Stub for perl: logs the probe arguments (not the script), prints perl_out and exits with perl_rc
s="${STUB_STATE:?}"
if [[ "${1:-}" == "-e" ]]; then shift 2; fi
printf 'perl %s\n' "$*" >> "$s/calls"
if [[ -f "$s/perl_out" ]]; then cat "$s/perl_out"; fi
exit "$(cat "$s/perl_rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$STUB_BIN/perl-stub"
fx=$(new_fixture send)
send_case() {  # $1 = helper output, $2 = expected word, $3 = description
    printf '%s' "$1" > "$fx/state/perl_out"
    run_snippet "$fx" "PERL_BIN='$STUB_BIN/perl-stub'; ts_m_probe_send 4 198.18.2.1 eth0"
    assert_equals "$2" "$SN_OUT" "$3"
}
send_case $'EPERM\n' "EPERM" "Datagram probe: the helper's errno name is passed on"
send_case $'sent\n' "sent" "Datagram probe: so is sent"
send_case $'error:bind-enodev\n' "error:bind-enodev" "Datagram probe: and the helper's own errors"
send_case $'connected to 198.18.2.1\n' "error:helper" "Datagram probe: any other output is an error"
send_case $'sent\nEPERM\n' "error:helper" "Datagram probe: more than one word is an error"
send_case '' "error:helper" "Datagram probe: no output is an error"
assert_contains "$(cat "$fx/state/calls")" "perl 4 198.18.2.1 eth0" "Datagram probe: the helper gets the family, the address and the interface"
echo 255 > "$fx/state/perl_rc"
send_case $'sent\n' "error:helper" "Datagram probe: a helper that fails is an error, whatever it printed"
rm -f "$fx/state/perl_rc"
run_snippet "$fx" "PERL_BIN='$fx/no-such-perl'; ts_m_probe_send 4 198.18.2.1 eth0"
assert_equals "error:no-perl" "$SN_OUT" "Datagram probe: a missing perl is an error, never a pass"
# managed-probe send: the cgroup line, then one line with the address and the result
printf 'EPERM\n' > "$fx/state/perl_out"
: > "$fx/state/calls"
run_snippet "$fx" "PERL_BIN='$STUB_BIN/perl-stub'; ts_m_cmd_probe send 6 - 2001:db8:113::40"
assert_contains "$(printf '%s\n' "$SN_OUT" | head -n 1)" "cgroup " "managed-probe send: the first line names the cgroup"
assert_equals "send 2001:db8:113::40 EPERM" "$(printf '%s\n' "$SN_OUT" | sed -n 2p)" "managed-probe send: then the address and the result"
assert_contains "$(cat "$fx/state/calls")" "perl 6 2001:db8:113::40 -" "managed-probe send: an unbound IPv6 datagram"
run_snippet "$fx" "PERL_BIN='$STUB_BIN/perl-stub'; ts_m_cmd_probe send 5 - 198.18.2.1"
assert_equals "2" "$SN_RC" "managed-probe send: an unknown family is a usage error"
run_snippet "$fx" "PERL_BIN='$STUB_BIN/perl-stub'; ts_m_cmd_probe send 4 eth0"
assert_equals "2" "$SN_RC" "managed-probe send: a missing address is a usage error"
# The real helper: an address it cannot parse is an error (no network needed)
run_snippet "$fx" 'ts_m_probe_send 4 not-an-address -; ts_m_probe_send 6 198.18.2.1 -'
assert_equals $'error:address\nerror:address' "$SN_OUT" "Datagram probe (real helper): an address that does not parse is an error"

# The real helper in a throwaway network namespace (unshare -rn), where the system allows one: no
# route, a datagram that leaves, an nft drop (IPv4 and IPv6), and a uid blackhole rule, which stops
# an unbound socket but not a bound one (the kernel then treats the destination as on-link). That
# is why verify's kill switch probe binds its socket only to test the nft kill chain, and runs
# unbound, as the node user, while the emergency block (a uid blackhole) is armed.
real_bin() {
    local b
    for b in "$(command -v "$1" 2>/dev/null || true)" "/usr/sbin/$1" "/sbin/$1"; do
        if [[ -n "$b" ]] && [[ -x "$b" ]]; then
            echo "$b"
            return 0
        fi
    done
    return 1
}
ip_real=$(real_bin ip || true)
nft_real=$(real_bin nft || true)
if [[ -n "$ip_real" ]] && unshare -rn true >/dev/null 2>&1; then
    e2e=$(unshare -rn bash -c '
source "$1"
ip="$2"
nft="$3"
r() { local w; w=$(ts_m_probe_send "$2" "$3" "$4"); echo "$1=${w}:$(ts_m_probe_classify "$w")"; }
"$ip" link set lo up
r noroute 4 192.0.2.1 -
if "$ip" link add v0 type veth peer name v1 2>/dev/null; then
    "$ip" addr add 192.0.2.10/24 dev v0
    "$ip" link set v0 up
    "$ip" link set v1 up
    "$ip" neigh add 192.0.2.1 lladdr 02:00:00:00:00:01 dev v0 nud permanent
    "$ip" route add default via 192.0.2.1 dev v0
    r left 4 203.0.113.5 v0
    r baddev 4 203.0.113.5 ts-no-such-dev
    if "$ip" rule add uidrange 0-0 blackhole priority 100 2>/dev/null; then
        r uid_unbound 4 203.0.113.5 -
        r uid_bound 4 203.0.113.5 v0
        "$ip" rule del priority 100
    fi
    if [[ -n "$nft" ]] && "$nft" add table inet t 2>/dev/null; then
        "$nft" add chain inet t post "{ type filter hook postrouting priority 0; policy accept; }"
        "$nft" add rule inet t post oifname v0 drop
        r dropped 4 203.0.113.5 v0
        if "$ip" -6 addr add 2001:db8:1::10/64 dev v0 nodad 2>/dev/null && "$ip" -6 route add default via 2001:db8:1::1 dev v0 2>/dev/null; then
            r dropped6 6 2001:db8:113::40 -
        fi
        "$nft" delete table inet t
    fi
fi
' _ "$SCRIPT_UNDER_TEST" "$ip_real" "$nft_real" 2>&1 || true)
    e2e_case() {  # $1 = key, $2 = expected "word:class", $3 = description
        local line
        line=$(printf '%s\n' "$e2e" | grep "^$1=" | head -n 1 || true)
        if [[ -n "$line" ]]; then
            assert_equals "$2" "${line#*=}" "$3"
        elif [[ "$1" == "noroute" ]]; then
            fail "$3 (the namespace run printed: ${e2e})"
        else
            echo "SKIP: $3 (not possible in this namespace)"
        fi
    }
    e2e_case noroute "ENETUNREACH:blocked" "Datagram probe (namespace): no route is stopped on this host (ENETUNREACH)"
    e2e_case left "sent:left" "Datagram probe (namespace): a datagram with a route leaves"
    e2e_case baddev "error:bind-enodev:error" "Datagram probe (namespace): a missing interface is an error"
    e2e_case dropped "EPERM:blocked" "Datagram probe (namespace): an nft drop stops a bound socket (EPERM)"
    e2e_case dropped6 "EPERM:blocked" "Datagram probe (namespace): an nft drop stops an IPv6 datagram (EPERM)"
    e2e_case uid_unbound "EINVAL:blocked" "Datagram probe (namespace): a uid blackhole stops an unbound socket (EINVAL)"
    e2e_case uid_bound "sent:left" "Datagram probe (namespace): a bound socket is not stopped by a uid blackhole (treated as on-link)"
else
    echo "SKIP: no unprivileged network namespace here; the real datagram probe runs in the kernel tests"
fi

# ---------------------------------------------------------------------------
# GROUP 11: RaspiBlitz profile (install --managed raspiblitz)
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 11: RaspiBlitz profile ---"

# A RaspiBlitz fixture: the marker directory and the data drive with the links RaspiBlitz puts into
# the home of bitcoin (blitz.data.sh, cl.install.sh; relative here, so they resolve in the fixture)
rb_fixture() {
    local f
    f=$(new_fixture "rb-$1")
    mkdir -p "$f/fs/home/admin/config.scripts" "$f/fs/home/bitcoin" "$f/fs/mnt/hdd/app-data/lnd" \
        "$f/fs/mnt/hdd/app-data/.lightning/testnet" "$f/fs/mnt/hdd/app-data/.lightning/signet"
    ln -s ../../mnt/hdd/app-data/lnd "$f/fs/home/bitcoin/.lnd"
    ln -s ../../mnt/hdd/app-data/.lightning "$f/fs/home/bitcoin/.lightning"
    echo "$f"
}
# Unit $2 in fixture $1 as RaspiBlitz writes it: loaded, User=bitcoin, ExecStart $3
rb_unit() {
    echo "loaded" > "$1/state/unit_${2}_LoadState"
    echo "bitcoin" > "$1/state/unit_${2}_User"
    printf '{ path=%s ; argv[]=%s ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }\n' \
        "${3%% *}" "$3" > "$1/state/unit_${2}_ExecStart"
}
# ExecStart of RaspiBlitz's LND unit (lnd.install.sh) for unit prefix $1
rb_lnd_exec() {
    echo "/usr/local/bin/lnd --configfile=/mnt/hdd/app-data/lnd/${1}lnd.conf"
}
# ExecStart of RaspiBlitz's CLN unit (cl.install-service.sh) for config $1, as systemctl shows it:
# with password file $2 (encrypted hsm_secret) the password pipe comes first; without it the empty
# option leaves two spaces
rb_cln_exec() {
    if [[ -n "${2:-}" ]]; then
        echo "/bin/sh -c (cat ${2};echo;cat ${2}) | /usr/local/bin/lightningd --conf=${1} --encrypted-hsm --rpc-file-mode 0660"
    else
        echo "/bin/sh -c /usr/local/bin/lightningd --conf=${1}  --rpc-file-mode 0660"
    fi
}
# RaspiBlitz's config templates (lnd.install.sh plus the Tor lines of lnd.check.sh; cl.install.sh),
# and the same with the TunnelSats hybrid settings
rb_lnd_conf=$'# LND configuration\n\n[Application Options]\n# alias=ALIAS # up to 32 UTF-8 characters\nlisten=0.0.0.0:9735\nrpclisten=0.0.0.0:10009\nrestlisten=0.0.0.0:8080\nnat=false\ndebuglevel=info\n\n[Bitcoin]\nbitcoin.active=1\nbitcoin.mainnet=1\nbitcoin.node=bitcoind\n\n[Tor]\ntor.socks=9050\ntor.control=9051\ntor.v3=true\ntor.active=true'
rb_lnd_conf_hybrid=$'# LND configuration\n\n[Application Options]\nlisten=0.0.0.0:9735\nexternalhosts=de2.tunnelsats.com:24556\nnat=false\n\n[Tor]\ntor.active=true\ntor.streamisolation=false\ntor.skip-proxy-for-clearnet-targets=true'
rb_cln_conf=$'# lightningd configuration for bitcoin mainnet\n\nnetwork=bitcoin\nlog-file=cl.log\nlog-level=info\nplugin-dir=/home/bitcoin/cl-plugins-enabled\nclnrest-port=7378\nclnrest-host=0.0.0.0\ngrpc-port=4772\n\n# Tor settings\nproxy=127.0.0.1:9050\nbind-addr=127.0.0.1:9736\naddr=statictor:127.0.0.1:9051/torport=9736\nalways-use-proxy=true'
rb_cln_conf_testnet=$'# lightningd configuration for bitcoin testnet\n\nnetwork=testnet\nlog-file=cl.log\nplugin-dir=/home/bitcoin/tcl-plugins-enabled\nclnrest-port=17378\n\n# Tor settings\nproxy=127.0.0.1:9050\nbind-addr=127.0.0.1:19736\naddr=statictor:127.0.0.1:9051/torport=19736\nalways-use-proxy=true'
rb_cln_conf_hybrid=$'network=testnet\nproxy=127.0.0.1:9050\nbind-addr=127.0.0.1:19736\naddr=statictor:127.0.0.1:9051/torport=19736\nbind-addr=0.0.0.0:9735\nannounce-addr=203.0.113.7:24556\nalways-use-proxy=false'

# Unit names: no prefix on mainnet, t on testnet, s on signet
fx=$(rb_fixture units)
run_snippet "$fx" 'for i in lnd cln; do for n in mainnet testnet signet; do printf "%s " "$(ts_m_raspiblitz_unit "$i" "$n")"; done; done'
assert_equals "lnd.service tlnd.service slnd.service lightningd.service tlightningd.service slightningd.service " "$SN_OUT" \
    "RaspiBlitz units: no prefix on mainnet, t on testnet, s on signet"
run_snippet "$fx" 'ts_m_raspiblitz_unit lit mainnet || echo "lit: none"; ts_m_raspiblitz_unit lnd regtest || echo "regtest: none"'
assert_equals $'lit: none\nregtest: none' "$SN_OUT" "RaspiBlitz units: no unit for another implementation or chain"
run_snippet "$fx" 'for e in $TS_M_LN_UNITS $TS_M_RASPIBLITZ_LN_UNITS; do ts_in_list "$e" "$TS_M_ALL_LN_UNITS" || echo "missing ${e}"; done; echo "$TS_M_ALL_LN_UNITS" | tr " " "\n" | sort | uniq -d; echo checked'
assert_equals "checked" "$SN_OUT" "RaspiBlitz units: every unit of both profiles is listed once among the units that can carry the drop-in"

# Unit and user selection for each implementation and chain (decision: --impl required,
# --network defaults to mainnet)
for spec in lnd:mainnet:lnd.service lnd:testnet:tlnd.service lnd:signet:slnd.service \
    cln:mainnet:lightningd.service cln:testnet:tlightningd.service cln:signet:slightningd.service; do
    IFS=: read -r rb_impl rb_net rb_unit_name <<< "$spec"
    fx=$(rb_fixture "select-${rb_impl}-${rb_net}")
    rb_unit "$fx" "$rb_unit_name" "/usr/local/bin/x"
    run_snippet "$fx" "TS_OPT_PROFILE=raspiblitz TS_OPT_IMPL=${rb_impl} TS_OPT_NETWORK=${rb_net}; ts_m_select_ln_unit; ts_m_select_ln_user; echo \"\${TS_M_IMPL} \${TS_M_UNIT} \${TS_M_USER} \${TS_M_UID} others=\${TS_M_OTHER_UNITS[*]}\""
    assert_equals "${rb_impl} ${rb_unit_name} bitcoin 1001 others=" "$SN_OUT" \
        "RaspiBlitz selection: --impl ${rb_impl} --network ${rb_net} tunnels ${rb_unit_name} as user bitcoin (uid 1001)"
done
fx=$(rb_fixture select-default)
for u in lnd.service tlnd.service lightningd.service; do
    rb_unit "$fx" "$u" "/usr/local/bin/x"
done
run_snippet "$fx" 'TS_OPT_PROFILE=raspiblitz TS_OPT_IMPL=cln TS_OPT_NETWORK=""; ts_m_select_ln_unit; echo "${TS_M_UNIT} others=${TS_M_OTHER_UNITS[*]}"'
assert_equals "lightningd.service others=lnd.service tlnd.service" "$SN_OUT" \
    "RaspiBlitz selection: --network defaults to mainnet; the other loaded instances are listed as not tunneled"
run_snippet "$fx" 'TS_OPT_PROFILE=baremetal TS_OPT_IMPL=lnd; ts_m_select_ln_unit; echo "${TS_M_UNIT} others=${TS_M_OTHER_UNITS[*]}"'
assert_equals "lnd.service others=lightningd.service" "$SN_OUT" "Bare-metal selection is unchanged: tlnd.service is no candidate"
run_snippet "$fx" 'TS_JSON=1; TS_COMMAND=install; TS_OUT_FD=1; TS_OPT_PROFILE=raspiblitz TS_OPT_IMPL=lnd TS_OPT_NETWORK=signet; ts_m_select_ln_unit'
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["exit_code"], d["errors"][0]["code"], d["errors"][0]["message"]]' \
    '[7, "E_LN_UNIT", "--impl lnd --network signet: slnd.service is not installed (LoadState not-found)"]' \
    "RaspiBlitz selection: an instance that is not installed is refused (E_LN_UNIT), naming the unit"

# The managed paths of every RaspiBlitz unit are allowed in the inventory, nothing else in their
# directories; the inventory records the profile and checks the unit against it
run_snippet "$fx" 'for u in lnd.service tlnd.service slnd.service lightningd.service tlightningd.service slightningd.service; do
ts_m_inventory_path_ok "/etc/systemd/system/${u}.d" && ts_m_inventory_path_ok "/etc/systemd/system/${u}.d/tunnelsats-managed.conf" && printf "%s " "$u"
done
ts_m_inventory_path_ok /etc/systemd/system/tlnd.service.d/override.conf || printf "| override.conf refused "
ts_m_inventory_path_ok /etc/systemd/system/tlnd.service || printf "| unit file refused"'
assert_equals "lnd.service tlnd.service slnd.service lightningd.service tlightningd.service slightningd.service | override.conf refused | unit file refused" "$SN_OUT" \
    "RaspiBlitz paths: the drop-in and its directory of each unit are allowed, nothing else"
fx=$(rb_fixture inventory)
mkdir -p "$fx/fs/etc/tunnelsats"
run_snippet "$fx" '
TS_M_INV_STATE=installed TS_M_INV_PROFILE=raspiblitz TS_M_INV_IMPL=cln TS_M_INV_UNIT=tlightningd.service TS_M_INV_USER=bitcoin TS_M_INV_UID=1001 TS_M_INV_BACKSTOP=0
TS_M_FILES=(/etc/systemd/system/tlightningd.service.d/tunnelsats-managed.conf) TS_M_FILE_SHA=("")
TS_M_CREATED_DIRS=(/etc/systemd/system/tlightningd.service.d) TS_M_ENABLED_UNITS=()
ts_m_inventory_write
TS_M_INV_PROFILE="" TS_M_INV_UNIT="" TS_M_FILES=() TS_M_CREATED_DIRS=()
ts_m_inventory_read && echo "read: ${TS_M_INV_PROFILE} ${TS_M_INV_IMPL} ${TS_M_INV_UNIT} ${TS_M_FILES[*]} ${TS_M_CREATED_DIRS[*]}"'
assert_equals "read: raspiblitz cln tlightningd.service /etc/systemd/system/tlightningd.service.d/tunnelsats-managed.conf /etc/systemd/system/tlightningd.service.d" "$SN_OUT" \
    "RaspiBlitz inventory: profile, prefixed unit and its drop-in round-trip"
cp "$fx/fs/etc/tunnelsats/managed.json" "$fx/state/inventory.ok"
sed -i 's/"unit": "tlightningd.service"/"unit": "litd.service"/' "$fx/fs/etc/tunnelsats/managed.json"
run_snippet "$fx" 'ts_m_inventory_read || echo "refused: $TS_M_ERROR"'
assert_contains "$SN_OUT" "holds invalid values" "RaspiBlitz inventory: a unit the profile cannot tunnel is refused"
cp "$fx/state/inventory.ok" "$fx/fs/etc/tunnelsats/managed.json"
sed -i 's/"profile": "raspiblitz"/"profile": "baremetal"/' "$fx/fs/etc/tunnelsats/managed.json"
run_snippet "$fx" 'ts_m_inventory_read || echo "refused: $TS_M_ERROR"'
assert_contains "$SN_OUT" "holds invalid values" "Bare-metal inventory: a RaspiBlitz testnet unit is refused"

# Node config detection on RaspiBlitz's paths: LND reads the file its unit names, CLN the config
# behind the link to the data drive; RaspiBlitz's shell command for CLN is read through
rb_nc() {  # $1 = impl, $2 = unit, $3 = ExecStart, $4 = config file on the data drive, $5 = content, $6 = profile
    local f
    f=$(rb_fixture "nc-$RANDOM")
    rb_unit "$f" "$2" "$3"
    printf '%s\n' "$5" > "$f/fs$4"
    run_snippet "$f" "ts_m_node_config_clearnet $1 $2 $6; echo \"\$TS_M_NC_STATUS\"; printf '%s\n' \"\${TS_M_NC_LINES[@]}\"; echo \"files=\${TS_M_NC_FILES[*]}\"; echo \"reason=\$TS_M_NC_REASON\""
}
rb_nc lnd lnd.service "$(rb_lnd_exec "")" /mnt/hdd/app-data/lnd/lnd.conf "$rb_lnd_conf" raspiblitz
assert_equals "clean" "${SN_OUT%%$'\n'*}" "RaspiBlitz detector: mainnet LND with RaspiBlitz's Tor-only lnd.conf is clean"
assert_contains "$SN_OUT" "files=/mnt/hdd/app-data/lnd/lnd.conf" "RaspiBlitz detector: LND's config is the file its unit names (--configfile)"
rb_nc lnd tlnd.service "$(rb_lnd_exec t)" /mnt/hdd/app-data/lnd/tlnd.conf "$rb_lnd_conf_hybrid" raspiblitz
assert_equals "clearnet" "${SN_OUT%%$'\n'*}" "RaspiBlitz detector: testnet LND with hybrid settings in tlnd.conf is clearnet"
assert_contains "$SN_OUT" "/mnt/hdd/app-data/lnd/tlnd.conf:5:externalhosts=de2.tunnelsats.com:24556" "RaspiBlitz detector: reports tlnd.conf, line and externalhosts"
assert_contains "$SN_OUT" "/mnt/hdd/app-data/lnd/tlnd.conf:11:tor.skip-proxy-for-clearnet-targets=true" "RaspiBlitz detector: and skip-proxy"
rb_nc cln lightningd.service "$(rb_cln_exec /home/bitcoin/.lightning/config)" /mnt/hdd/app-data/.lightning/config "$rb_cln_conf" raspiblitz
assert_equals "clean" "${SN_OUT%%$'\n'*}" "RaspiBlitz detector: mainnet CLN through RaspiBlitz's shell command with its Tor-only config is clean"
assert_contains "$SN_OUT" "files=/home/bitcoin/.lightning/config" "RaspiBlitz detector: CLN's config is read through the link to the data drive"
rb_nc cln lightningd.service "$(rb_cln_exec /home/bitcoin/.lightning/config)" /mnt/hdd/app-data/.lightning/config "$rb_cln_conf" ""
assert_equals "unknown" "${SN_OUT%%$'\n'*}" "Bare-metal detector is unchanged: the same shell command stays unknown"
assert_contains "$SN_OUT" "runs through a shell (/bin/sh)" "Bare-metal detector: with the shell named"
rb_nc cln tlightningd.service "$(rb_cln_exec /home/bitcoin/.lightning/testnet/config /home/bitcoin/.tcl.pw)" /mnt/hdd/app-data/.lightning/testnet/config "$rb_cln_conf_hybrid" raspiblitz
assert_equals "clearnet" "${SN_OUT%%$'\n'*}" "RaspiBlitz detector: testnet CLN (encrypted hsm_secret, password pipe) with hybrid settings is clearnet"
assert_contains "$SN_OUT" "/home/bitcoin/.lightning/testnet/config:5:bind-addr=0.0.0.0:9735" "RaspiBlitz detector: reports the testnet config and bind-addr"
assert_contains "$SN_OUT" "/home/bitcoin/.lightning/testnet/config:6:announce-addr=203.0.113.7:24556" "RaspiBlitz detector: announce-addr"
assert_contains "$SN_OUT" "/home/bitcoin/.lightning/testnet/config:7:always-use-proxy=false" "RaspiBlitz detector: always-use-proxy=false"
assert_not_contains "$SN_OUT" "127.0.0.1:19736" "RaspiBlitz detector: the Tor bind is never reported"
rb_nc cln slightningd.service "$(rb_cln_exec /home/bitcoin/.lightning/signet/config /dev/shm/.scl.pw)" /mnt/hdd/app-data/.lightning/signet/config "$rb_cln_conf_testnet" raspiblitz
assert_equals "clean" "${SN_OUT%%$'\n'*}" "RaspiBlitz detector: signet CLN with the password pipe from /dev/shm and a Tor-only config is clean"
rb_nc cln lightningd.service "/bin/sh -c /usr/local/bin/lightningd --conf=/home/bitcoin/.lightning/config --bind-addr=0.0.0.0:9735 --rpc-file-mode 0660" \
    /mnt/hdd/app-data/.lightning/config "$rb_cln_conf" raspiblitz
assert_equals "clearnet" "${SN_OUT%%$'\n'*}" "RaspiBlitz detector: a clearnet argument inside RaspiBlitz's shell command counts like a config line"
assert_contains "$SN_OUT" "lightningd.service ExecStart: --bind-addr=0.0.0.0:9735" "RaspiBlitz detector: reported with the unit"
rb_odd=0
for cmd in \
    "/bin/sh -c /usr/local/bin/lightningd --conf=/home/bitcoin/.lightning/config --rpc-file-mode 0660; /usr/bin/true" \
    "/bin/sh -c /usr/local/bin/lightningd --conf=/home/bitcoin/.lightning/config '--bind-addr=0.0.0.0:9735'" \
    "/bin/sh -c /usr/local/bin/lightningd --conf=/home/bitcoin/.lightning/c* --rpc-file-mode 0660" \
    "/bin/sh -c (cat /home/bitcoin/.cl.pw;echo;cat /tmp/other.pw) | /usr/local/bin/lightningd --conf=/home/bitcoin/.lightning/config" \
    "/bin/sh -c echo x | /usr/local/bin/lightningd --conf=/home/bitcoin/.lightning/config" \
    "/bin/sh -c /opt/cln/lightningd --conf=/home/bitcoin/.lightning/config" \
    "/bin/bash -c /usr/local/bin/lightningd --conf=/home/bitcoin/.lightning/config" \
    "/bin/sh -c /usr/local/bin/lightningd --conf=/home/bitcoin/.lightning/config"$'\n'"/usr/local/bin/lightningd --bind-addr=0.0.0.0:9735"; do
    rb_odd=$((rb_odd + 1))
    rb_nc cln lightningd.service "$cmd" /mnt/hdd/app-data/.lightning/config "$rb_cln_conf" raspiblitz
    assert_equals "unknown" "${SN_OUT%%$'\n'*}" "RaspiBlitz detector: a shell command other than RaspiBlitz's own stays unknown (case ${rb_odd})"
done

# RaspiBlitz's TunnelSats start guard (the RaspiBlitz integration, unit templates of lnd.install.sh
# and cl.install-service.sh): the flags of each start come through one variable at the end of the
# command line, read from the guard's env file. uninstall --managed reads the variable through when
# the unit carries the guard exactly; the env file then decides: absent or empty is clean, flags mean
# TunnelSats is still on in RaspiBlitz.
# $1 = fixture, $2 = lnd|cln, $3 = chain, $4 = CLN password file (encrypted hsm_secret) or empty.
# Writes the unit file as RaspiBlitz does, and what systemd shows for it (ExecStart with the variable,
# $$ included, FragmentPath, NeedDaemonReload=no). Prints the unit name.
rb_guard_unit() {
    local fx="$1" impl="$2" chain="$3" pw="${4:-}" p="" unit base gimpl var conf pwin="" enc="" shown exec_line
    case "$chain" in
        testnet) p="t" ;;
        signet) p="s" ;;
    esac
    if [[ "$impl" == "lnd" ]]; then
        unit="${p}lnd.service" base="${p}lnd" gimpl="lnd" var="TUNNELSATS_LND_ARGS"
        shown="$(rb_lnd_exec "$p") \$TUNNELSATS_LND_ARGS"
        exec_line="ExecStart=/usr/local/bin/lnd --configfile=/mnt/hdd/app-data/lnd/${p}lnd.conf \$TUNNELSATS_LND_ARGS"
    else
        unit="${p}lightningd.service" base="${p}lightningd" gimpl="cl" var="TUNNELSATS_CLN_ARGS"
        conf="/home/bitcoin/.lightning/config"
        if [[ "$chain" != "mainnet" ]]; then
            conf="/home/bitcoin/.lightning/${chain}/config"
        fi
        if [[ -n "$pw" ]]; then
            pwin="(cat ${pw};echo;cat ${pw}) | " enc="--encrypted-hsm"
        fi
        shown="$(rb_cln_exec "$conf" "$pw") \$\$TUNNELSATS_CLN_ARGS"
        exec_line="ExecStart=/bin/sh -c '${pwin}/usr/local/bin/lightningd --conf=${conf} ${enc} --rpc-file-mode 0660 \$\$TUNNELSATS_CLN_ARGS'"
    fi
    rb_unit "$fx" "$unit" "$shown"
    echo "/etc/systemd/system/${unit}" > "$fx/state/unit_${unit}_FragmentPath"
    echo "no" > "$fx/state/unit_${unit}_NeedDaemonReload"
    {
        printf '\n[Unit]\nDescription=Lightning on %s\nRequires=%sbitcoind.service\n\n[Service]\n' "$chain" "$p"
        if [[ "$impl" == "lnd" ]]; then
            printf 'EnvironmentFile=/mnt/hdd/app-data/raspiblitz.conf\n'
        fi
        printf '# TunnelSats start guard (no-op unless TunnelSats is on): clearnet flags for this start only\n'
        printf '# (without internet.tunnelsats.sh, for example older code after a PATCH, Lightning starts Tor-only)\n'
        printf 'Environment=%s=\nEnvironmentFile=-/run/tunnelsats/hybrid-%s.env\n' "$var" "$base"
        if [[ "$impl" == "lnd" ]]; then
            printf '\nExecStartPre=-/home/admin/config.scripts/lnd.check.sh prestart %s\n' "$chain"
        else
            printf 'ExecStartPre=-/home/admin/config.scripts/cl.check.sh prestart %s\n' "$chain"
        fi
        printf "ExecStartPre=+/bin/sh -c 'if [ -x /home/admin/config.scripts/internet.tunnelsats.sh ]; then exec /home/admin/config.scripts/internet.tunnelsats.sh guard %s %s; fi; echo tunnelsats-guard: internet.tunnelsats.sh is missing, Lightning starts Tor-only >&2; mkdir -p /run/tunnelsats && echo %s= > /run/tunnelsats/hybrid-%s.env'\n" \
            "$gimpl" "$chain" "$var" "$base"
        printf '%s\n' "$exec_line"
        printf '# avoid hanging on stop\n# ExecStop=/usr/local/bin/lncli stop\n\nUser=bitcoin\nGroup=bitcoin\nRestart=always\nRestartSec=60\n\n[Install]\nWantedBy=multi-user.target\n'
    } > "$fx/fs/etc/systemd/system/${unit}"
    echo "$unit"
}
# The flags the guard writes for a hybrid start (concept of the RaspiBlitz integration)
rb_flags_lnd="--tor.skip-proxy-for-clearnet-targets --externalhosts=de2.tunnelsats.com:24556"
rb_flags_cln="--bind-addr=0.0.0.0:9735 --announce-addr=203.0.113.7:24556 --always-use-proxy=false --announce-addr-discovered=false"
# Prints "<state>:<node config status>" for each env file state in fixture $1 for unit $2 (impl $3,
# variable $4, flags $5), then the reason of the last state. "zero" is an empty file.
rb_guard_states() {
    local base="${2%.service}"
    run_snippet "$1" "for s in absent zero empty flags; do
rm -f \"\$TS_FS_ROOT/run/tunnelsats/hybrid-${base}.env\"
mkdir -p \"\$TS_FS_ROOT/run/tunnelsats\"
case \$s in
    zero) : > \"\$TS_FS_ROOT/run/tunnelsats/hybrid-${base}.env\" ;;
    empty) printf '%s=\n' '$4' > \"\$TS_FS_ROOT/run/tunnelsats/hybrid-${base}.env\" ;;
    flags) printf '%s=%s\n' '$4' '$5' > \"\$TS_FS_ROOT/run/tunnelsats/hybrid-${base}.env\" ;;
esac
ts_m_node_config_clearnet $3 $2 raspiblitz
printf '%s:%s ' \"\$s\" \"\$TS_M_NC_STATUS\"
done
echo
echo \"lines=\${TS_M_NC_LINES[*]}\"
echo \"reason=\$TS_M_NC_REASON\""
}
for spec in lnd:mainnet: lnd:testnet: lnd:signet: cln:mainnet: cln:testnet: cln:signet: \
    cln:mainnet:/home/bitcoin/.cl.pw cln:testnet:/home/bitcoin/.tcl.pw cln:signet:/dev/shm/.scl.pw; do
    IFS=: read -r g_impl g_chain g_pw <<< "$spec"
    fx=$(rb_fixture "guard-${g_impl}-${g_chain}${g_pw:+-pw}")
    g_unit=$(rb_guard_unit "$fx" "$g_impl" "$g_chain" "$g_pw")
    if [[ "$g_impl" == "lnd" ]]; then
        g_p="${g_unit%lnd.service}"
        printf '%s\n' "$rb_lnd_conf" > "$fx/fs/mnt/hdd/app-data/lnd/${g_p}lnd.conf"
        rb_guard_states "$fx" "$g_unit" lnd TUNNELSATS_LND_ARGS "$rb_flags_lnd"
    else
        if [[ "$g_chain" == "mainnet" ]]; then
            printf '%s\n' "$rb_cln_conf" > "$fx/fs/mnt/hdd/app-data/.lightning/config"
        else
            printf '%s\n' "$rb_cln_conf_testnet" > "$fx/fs/mnt/hdd/app-data/.lightning/${g_chain}/config"
        fi
        rb_guard_states "$fx" "$g_unit" cln TUNNELSATS_CLN_ARGS "$rb_flags_cln"
    fi
    g_name="${g_unit} (${g_impl} ${g_chain}${g_pw:+, password pipe})"
    assert_equals "absent:clean zero:clean empty:clean flags:unknown " "${SN_OUT%%$'\n'*}" \
        "RaspiBlitz start guard: ${g_name} with the guard variable is clean while the env file is absent or empty, not while it holds flags"
    assert_contains "$SN_OUT" "reason=TunnelSats is still on in RaspiBlitz (/run/tunnelsats/hybrid-${g_unit%.service}.env holds the clearnet flags of the current start of ${g_unit}): remove it in the RaspiBlitz menu (SUBSCRIBE > TunnelSats > REMOVE), then enable and start ${g_unit}" \
        "RaspiBlitz start guard: ${g_name} with flags points to REMOVE in the RaspiBlitz menu"
    assert_contains "$SN_OUT" $'\nlines=\n' "RaspiBlitz start guard: ${g_name}: the flags are not reported as lines to remove"
done

# The env file holds anything but "<VAR>=" or "<VAR>=<flags>" on one line: unknown
fx=$(rb_fixture guard-env)
g_unit=$(rb_guard_unit "$fx" lnd mainnet "")
printf '%s\n' "$rb_lnd_conf" > "$fx/fs/mnt/hdd/app-data/lnd/lnd.conf"
mkdir -p "$fx/fs/run/tunnelsats"
rb_envs=0
for content in $'OTHER_ARGS=--externalhosts=x\n' $'TUNNELSATS_LND_ARGS=--a\nTUNNELSATS_LND_ARGS=--b\n' $'TUNNELSATS_LND_ARGS=--a\n\n' \
    $'TUNNELSATS_LND_ARGS=--a\tb\n' "garbage" $'\n'; do
    rb_envs=$((rb_envs + 1))
    printf '%s' "$content" > "$fx/fs/run/tunnelsats/hybrid-lnd.env"
    run_snippet "$fx" 'ts_m_node_config_clearnet lnd lnd.service raspiblitz; echo "$TS_M_NC_STATUS: $TS_M_NC_REASON"'
    assert_equals "unknown: /run/tunnelsats/hybrid-lnd.env of the RaspiBlitz start guard holds something other than TUNNELSATS_LND_ARGS=<flags>" "$SN_OUT" \
        "RaspiBlitz start guard: an env file with anything else is unknown (case ${rb_envs})"
done
rm -f "$fx/fs/run/tunnelsats/hybrid-lnd.env"
mkdir "$fx/fs/run/tunnelsats/hybrid-lnd.env"
run_snippet "$fx" 'ts_m_node_config_clearnet lnd lnd.service raspiblitz; echo "$TS_M_NC_STATUS"'
assert_equals "unknown" "$SN_OUT" "RaspiBlitz start guard: an env file that is no regular file is unknown"
rmdir "$fx/fs/run/tunnelsats/hybrid-lnd.env"
ln -s /dev/null "$fx/fs/run/tunnelsats/hybrid-lnd.env"
run_snippet "$fx" 'ts_m_node_config_clearnet lnd lnd.service raspiblitz; echo "$TS_M_NC_STATUS"'
assert_equals "unknown" "$SN_OUT" "RaspiBlitz start guard: a symlink is unknown"
rm -f "$fx/fs/run/tunnelsats/hybrid-lnd.env"
# Read before the removal clears /run/tunnelsats: the state passed in decides, not the file
run_snippet "$fx" 'ts_m_node_config_clearnet lnd lnd.service raspiblitz flags; echo "$TS_M_NC_STATUS"; ts_m_node_config_clearnet lnd lnd.service raspiblitz empty; echo "$TS_M_NC_STATUS"'
assert_equals $'unknown\nclean' "$SN_OUT" "RaspiBlitz start guard: the env file state read before the removal decides"
run_snippet "$fx" 'ts_m_node_config_clearnet lnd lnd.service raspiblitz; echo "$TS_M_NC_STATUS"'
assert_equals "clean" "$SN_OUT" "RaspiBlitz start guard: the reference fixture is clean"

# Anything but the exact form stays unknown: one change at a time to the reference fixture
cp "$fx/fs/etc/systemd/system/lnd.service" "$fx/state/lnd.service.ok"
cp "$fx/state/unit_lnd.service_ExecStart" "$fx/state/ExecStart.ok"
rb_guard_case() {  # $1 = expected reason part, $2 = name; checks and restores the fixture
    run_snippet "$fx" 'ts_m_node_config_clearnet lnd lnd.service raspiblitz; echo "$TS_M_NC_STATUS: $TS_M_NC_REASON"'
    assert_equals "unknown" "${SN_OUT%%:*}" "RaspiBlitz start guard: ${2} stays unknown"
    assert_contains "$SN_OUT" "$1" "RaspiBlitz start guard: ${2}: reason"
    cp "$fx/state/lnd.service.ok" "$fx/fs/etc/systemd/system/lnd.service"
    cp "$fx/state/ExecStart.ok" "$fx/state/unit_lnd.service_ExecStart"
    echo "no" > "$fx/state/unit_lnd.service_NeedDaemonReload"
    echo "/etc/systemd/system/lnd.service" > "$fx/state/unit_lnd.service_FragmentPath"
    rm -f "$fx/state/unit_lnd.service_DropInPaths"
}
rb_unit_edit() {  # $1 = sed expression for the unit file
    sed -i "$1" "$fx/fs/etc/systemd/system/lnd.service"
}
rb_shown() {  # $1 = ExecStart as systemctl shows it
    rb_unit "$fx" lnd.service "$1"
}
rb_form="ends with \$TUNNELSATS_LND_ARGS of the RaspiBlitz start guard, but the unit does not carry the guard in the expected form"
rb_unit_edit 's/guard lnd mainnet/guard lnd testnet/'
rb_guard_case "$rb_form" "a guard line for another chain"
rb_unit_edit 's/Lightning starts Tor-only >&2/Lightning starts >\&2/'
rb_guard_case "$rb_form" "a changed guard line"
rb_unit_edit '/^ExecStartPre=+/d'
rb_guard_case "$rb_form" "a unit without the guard line"
rb_unit_edit 's/^\(ExecStartPre=+.*\)$/\1\n\1/'
rb_guard_case "$rb_form" "a guard line twice"
rb_unit_edit 's/^\(ExecStartPre=+.*\)$/[Unit]\n\1\n[Service]/'
rb_guard_case "$rb_form" "a guard line outside [Service]"
rb_guard_last_pre="${rb_form} (it does not run the guard line (guard lnd mainnet) once, as its last ExecStartPre=)"
rb_unit_edit 's/^\(ExecStartPre=+.*\)$/\1\nExecStartPre=/'
rb_guard_case "$rb_guard_last_pre" "an empty ExecStartPre= after the guard line (it clears the guard)"
rb_unit_edit 's/^\(ExecStartPre=+.*\)$/\1\n  ExecStartPre = /'
rb_guard_case "$rb_guard_last_pre" "the same reset with whitespace around ="
rb_unit_edit 's|^\(ExecStartPre=+.*\)$|\1\nExecStartPre=/bin/true|'
rb_guard_case "$rb_guard_last_pre" "another command after the guard line"
rb_unit_edit '/^Environment=TUNNELSATS_LND_ARGS=$/d'
rb_guard_case "$rb_form" "a unit without Environment=TUNNELSATS_LND_ARGS="
rb_unit_edit 's/^\(Environment=TUNNELSATS_LND_ARGS=\)$/\1\nEnvironment=/'
rb_guard_case "${rb_form} (an empty Environment= after Environment=TUNNELSATS_LND_ARGS= clears that default)" "an empty Environment= after the default"
# What systemd reads the same way still counts
rb_guard_ok() {  # $1 = name; checks that the fixture is still clean and restores it
    run_snippet "$fx" 'ts_m_node_config_clearnet lnd lnd.service raspiblitz; echo "$TS_M_NC_STATUS: $TS_M_NC_REASON"'
    assert_equals "clean: " "$SN_OUT" "RaspiBlitz start guard: ${1} still counts"
    cp "$fx/state/lnd.service.ok" "$fx/fs/etc/systemd/system/lnd.service"
}
rb_unit_edit 's/^\(ExecStartPre=-.*\)$/ExecStartPre=\n\1/'
rb_guard_ok "an empty ExecStartPre= before the guard line (the guard still runs last)"
rb_unit_edit 's/^Environment=TUNNELSATS_LND_ARGS=$/Environment = TUNNELSATS_LND_ARGS=/; s/^ExecStart=/  ExecStart = /'
rb_guard_ok "whitespace around = and before a line"
rb_unit_edit 's|^EnvironmentFile=-/run/tunnelsats/hybrid-lnd.env$|EnvironmentFile=-/run/tunnelsats/hybrid-tlnd.env|'
rb_guard_case "$rb_form" "an env file of another unit"
rb_unit_edit '\|^EnvironmentFile=-/run/tunnelsats/hybrid-lnd.env$|d'
rb_guard_case "$rb_form" "a unit without the env file"
rb_unit_edit 's|^\(EnvironmentFile=-/run/tunnelsats/hybrid-lnd.env\)$|\1\nEnvironmentFile=-/etc/default/lnd|'
rb_guard_case "${rb_form} (it does not read /run/tunnelsats/hybrid-lnd.env once, as its last EnvironmentFile=)" "another env file read after the guard's"
rb_unit_edit 's|^\(Environment=TUNNELSATS_LND_ARGS=\)$|\1\nEnvironment="TUNNELSATS_LND_ARGS=--externalhosts=de2.tunnelsats.com:24556"|'
rb_guard_case "${rb_form} (its unit file names TUNNELSATS_LND_ARGS elsewhere)" "a second assignment of the variable"
rb_unit_edit 's/^\(User=bitcoin\)$/Description=x \\\n\1/'
rb_guard_case "${rb_form} (its unit file continues lines with a backslash)" "a unit file with a line continuation"
echo "yes" > "$fx/state/unit_lnd.service_NeedDaemonReload"
rb_guard_case "${rb_form} (its unit file changed since systemd loaded it" "a unit file changed since the last daemon-reload"
echo "/etc/systemd/system/lnd.service.d/override.conf" > "$fx/state/unit_lnd.service_DropInPaths"
rb_guard_case "${rb_form} (the drop-in /etc/systemd/system/lnd.service.d/override.conf can change it)" "a unit with a drop-in of its own"
rm -f "$fx/state/unit_lnd.service_FragmentPath"
rb_guard_case "${rb_form} (its unit file (none) cannot be read)" "a unit whose unit file systemd does not name"
rb_shown "/usr/local/bin/lnd --configfile=/mnt/hdd/app-data/lnd/lnd.conf --externalhosts=de2.tunnelsats.com:24556 \$TUNNELSATS_LND_ARGS"
rb_guard_case "${rb_form} (the ExecStart= of its unit file differs from the one systemd runs)" "an ExecStart systemd runs from elsewhere (drop-in or quoting)"
rb_unit_edit 's/^\(ExecStart=.*\)$/\1\nExecStart=/'
rb_guard_case "$rb_form" "a second ExecStart= line"
rb_shown "/opt/lnd/lnd --configfile=/mnt/hdd/app-data/lnd/lnd.conf \$TUNNELSATS_LND_ARGS"
rb_unit_edit 's|^ExecStart=/usr/local/bin/lnd|ExecStart=/opt/lnd/lnd|'
rb_guard_case "${rb_form} (it does not run /usr/local/bin/lnd)" "another lnd binary"
rb_shown "/usr/local/bin/lnd --configfile=/mnt/hdd/app-data/lnd/lnd.conf \${TUNNELSATS_LND_ARGS}"
rb_unit_edit 's/\$TUNNELSATS_LND_ARGS$/${TUNNELSATS_LND_ARGS}/'
rb_guard_case "takes values from environment variables" "the \${VAR} form"
rb_shown "/usr/local/bin/lnd --configfile=\$LND_CONF \$TUNNELSATS_LND_ARGS"
rb_unit_edit 's|--configfile=/mnt/hdd/app-data/lnd/lnd.conf|--configfile=$LND_CONF|'
rb_guard_case "takes values from environment variables" "another variable before the guard's"
rb_shown "/usr/local/bin/lnd \$TUNNELSATS_LND_ARGS --configfile=/mnt/hdd/app-data/lnd/lnd.conf"
rb_unit_edit 's|^ExecStart=.*$|ExecStart=/usr/local/bin/lnd $TUNNELSATS_LND_ARGS --configfile=/mnt/hdd/app-data/lnd/lnd.conf|'
rb_guard_case "takes values from environment variables" "the variable before other arguments"
run_snippet "$fx" 'ts_m_node_config_clearnet lnd lnd.service baremetal; echo "$TS_M_NC_STATUS: $TS_M_NC_REASON"'
assert_equals "unknown: the command line (ExecStart) of lnd.service takes values from environment variables (\$VAR or \${VAR})" "$SN_OUT" \
    "RaspiBlitz start guard: the bare-metal profile does not read the variable through"
run_snippet "$fx" 'ts_m_node_config_clearnet lnd lnd.service raspiblitz; echo "$TS_M_NC_STATUS"'
assert_equals "clean" "$SN_OUT" "RaspiBlitz start guard: every case restored the reference fixture"

# CLN: the variable must be RaspiBlitz's $$ word, last inside the single sh -c string
fx=$(rb_fixture guard-cln-forms)
g_unit=$(rb_guard_unit "$fx" cln mainnet "")
printf '%s\n' "$rb_cln_conf" > "$fx/fs/mnt/hdd/app-data/.lightning/config"
cp "$fx/fs/etc/systemd/system/lightningd.service" "$fx/state/lightningd.service.ok"
rb_cln_case() {  # $1 = ExecStart as systemctl shows it, $2 = sed expression for the unit file, $3 = expected status, $4 = name
    rb_unit "$fx" lightningd.service "$1"
    cp "$fx/state/lightningd.service.ok" "$fx/fs/etc/systemd/system/lightningd.service"
    sed -i "$2" "$fx/fs/etc/systemd/system/lightningd.service"
    run_snippet "$fx" 'ts_m_node_config_clearnet cln lightningd.service raspiblitz; echo "$TS_M_NC_STATUS: $TS_M_NC_REASON"'
    assert_equals "$3" "${SN_OUT%%:*}" "RaspiBlitz start guard (CLN): ${4}"
}
rb_cln_base="/bin/sh -c /usr/local/bin/lightningd --conf=/home/bitcoin/.lightning/config  --rpc-file-mode 0660"
rb_cln_case "${rb_cln_base} \$\$TUNNELSATS_CLN_ARGS" 's/^$//' "clean" "RaspiBlitz's form is clean"
rb_cln_case "${rb_cln_base} \$TUNNELSATS_CLN_ARGS" 's/\$\$TUNNELSATS_CLN_ARGS/$TUNNELSATS_CLN_ARGS/' "unknown" "a single \$ (systemd would expand it) stays unknown"
rb_cln_case "${rb_cln_base} \$\$TUNNELSATS_CLN_ARGS" "s/ \\\$\\\$TUNNELSATS_CLN_ARGS'\$/' \$\$TUNNELSATS_CLN_ARGS/" "unknown" "the variable outside the sh -c string stays unknown"
rb_cln_case "${rb_cln_base} --bind-addr=0.0.0.0:9735 \$\$TUNNELSATS_CLN_ARGS" 's/0660 \$\$/0660 --bind-addr=0.0.0.0:9735 $$/' "clearnet" "a clearnet argument before the variable is still reported"
rb_cln_case "/bin/sh -c /usr/local/bin/lightningd --conf=/home/bitcoin/.lightning/config; /usr/bin/true \$\$TUNNELSATS_CLN_ARGS" \
    "s|--conf=/home/bitcoin/.lightning/config  --rpc-file-mode 0660|--conf=/home/bitcoin/.lightning/config; /usr/bin/true|" "unknown" "another shell command stays unknown"

# Drop-in units, the verifier's stop and its restart work for prefixed units: from the unit
# directory while the install record is damaged, and from the record otherwise
fx=$(rb_fixture dropins)
mkdir -p "$fx/fs/etc/tunnelsats" "$fx/fs/etc/systemd/system/tlnd.service.d" "$fx/fs/etc/systemd/system/slightningd.service.d" \
    "$fx/fs/etc/systemd/system/wg-quick@tunnelsatsv2.service.d"
run_snippet "$fx" 'for u in tlnd.service slightningd.service; do ts_m_render_ln_dropin > "$TS_FS_ROOT/etc/systemd/system/${u}.d/tunnelsats-managed.conf"; done
ts_m_render_wg_dropin > "$TS_FS_ROOT/etc/systemd/system/wg-quick@tunnelsatsv2.service.d/tunnelsats-managed.conf"
ts_m_dropin_units'
assert_equals $'tlnd.service\nslightningd.service' "$SN_OUT" "Drop-in units: RaspiBlitz testnet and signet units with the drop-in are found"
echo "garbage" > "$fx/fs/etc/tunnelsats/managed.json"
printf '{ path=/usr/local/sbin/tunnelsats ; argv[]=/usr/local/sbin/tunnelsats managed-arm --fallback-uid 1001 ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }\n' \
    > "$fx/state/unit_tunnelsats-killswitch.service_ExecStart"
printf '100:\tfrom all lookup main\n' > "$fx/state/rules4"
touch "$fx/state/stateful_units"
echo "active" > "$fx/state/unit_tlnd.service_ActiveState"
echo "active" > "$fx/state/unit_slightningd.service_ActiveState"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "1" "$SN_RC" "Damaged record, block bypassed: the verifier fails"
assert_contains "$SN_OUT" "tlnd.service slightningd.service stopped" "Damaged record: the verifier stops the prefixed units that carry the drop-in"
assert_equals "inactive inactive" "$(cat "$fx/state/unit_tlnd.service_ActiveState") $(cat "$fx/state/unit_slightningd.service_ActiveState")" \
    "Damaged record: both are stopped"
assert_equals $'tlnd.service stopped 0\nslightningd.service stopped 0' "$(cat "$fx/fs/run/tunnelsats/stopped-units" 2>/dev/null)" \
    "Damaged record: and recorded"
sed -i '/^100:/d' "$fx/state/rules4"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_contains "$SN_OUT" "protection holds again; starting tlnd.service again" "Damaged record: once the block holds, tlnd.service starts again"
assert_contains "$SN_OUT" "protection holds again; starting slightningd.service again" "Damaged record: and slightningd.service"
assert_equals "active active" "$(cat "$fx/state/unit_tlnd.service_ActiveState") $(cat "$fx/state/unit_slightningd.service_ActiveState")" \
    "Damaged record: both run again"
fx=$(rb_fixture quarantine)
mkdir -p "$fx/fs/etc/tunnelsats"
run_snippet "$fx" '
TS_M_INV_STATE=installed TS_M_INV_PROFILE=raspiblitz TS_M_INV_IMPL=lnd TS_M_INV_UNIT=tlnd.service TS_M_INV_USER=bitcoin TS_M_INV_UID=1001 TS_M_INV_BACKSTOP=0
TS_M_FILES=() TS_M_FILE_SHA=() TS_M_CREATED_DIRS=() TS_M_ENABLED_UNITS=()
ts_m_inventory_write && ts_m_cmd_arm'
assert_equals "0" "$SN_RC" "RaspiBlitz record: managed-arm arms for tlnd.service"
assert_json "$(cat "$fx/fs/run/tunnelsats/attest.json")" '[d["profile"], d["impl"], d["unit"]]' '["raspiblitz", "lnd", "tlnd.service"]' \
    "RaspiBlitz record: the attestation names the profile and the unit"
touch "$fx/state/nft_refuse" "$fx/state/stateful_units"
rm -f "$fx/state/nft_table"
printf '%s\n' "rule add uidrange 1001-1001 blackhole priority 21819" > "$fx/state/fail_ip"
echo "active" > "$fx/state/unit_tlnd.service_ActiveState"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_equals "1" "$SN_RC" "RaspiBlitz record: neither the kill switch nor the block holds: the verifier fails"
assert_contains "$SN_OUT" "tlnd.service stopped" "RaspiBlitz record: the verifier stops tlnd.service"
assert_equals "tlnd.service stopped 0" "$(cat "$fx/fs/run/tunnelsats/stopped-units" 2>/dev/null)" "RaspiBlitz record: and records it"
rm -f "$fx/state/nft_refuse" "$fx/state/fail_ip"
run_snippet "$fx" 'ts_m_cmd_verifier'
assert_contains "$SN_OUT" "protection holds again; starting tlnd.service again" "RaspiBlitz record: once the kill switch holds, tlnd.service starts again"
assert_equals "active" "$(cat "$fx/state/unit_tlnd.service_ActiveState")" "RaspiBlitz record: it runs again"

# Restart decision: install restarts a Lightning unit that runs, starts or stops (to move it into
# the slice) and never starts one that is not running; on RaspiBlitz a unit waiting for its
# automatic restart is left to that restart
fx=$(new_fixture rb-restart)
run_snippet "$fx" 'for p in baremetal raspiblitz; do TS_OPT_PROFILE=$p; printf "%s:" "$p"
for s in active:running reloading:reload deactivating:stop activating:start-pre activating:auto-restart inactive:dead failed:failed; do
if ts_m_ln_restart_needed "${s%%:*}" "${s#*:}"; then printf " %s=restart" "$s"; else printf " %s=leave" "$s"; fi
done; echo; done'
assert_equals $'baremetal: active:running=restart reloading:reload=restart deactivating:stop=restart activating:start-pre=restart activating:auto-restart=restart inactive:dead=leave failed:failed=leave\nraspiblitz: active:running=restart reloading:reload=restart deactivating:stop=restart activating:start-pre=restart activating:auto-restart=leave inactive:dead=leave failed:failed=leave' \
    "$SN_OUT" "Restart decision: unchanged on bare metal; on RaspiBlitz a unit in auto-restart is left to its own restart"

# Preflight: the raspiblitz profile needs a RaspiBlitz, the baremetal profile refuses one
rb_preflight_fixture() {  # a RaspiBlitz with its mainnet LND (lnd.service and RaspiBlitz's lnd.conf)
    local f
    f=$(rb_fixture "pf-$1")
    rb_unit "$f" lnd.service "$(rb_lnd_exec "")"
    printf '%s\n' "$rb_lnd_conf" > "$f/fs/mnt/hdd/app-data/lnd/lnd.conf"
    echo "$f"
}
fx=$(rb_preflight_fixture ok)
preflight "$fx" "TS_OPT_PROFILE=raspiblitz TS_OPT_IMPL=lnd;"
assert_contains "$SN_OUT" "PREFLIGHT_OK" "RaspiBlitz preflight: a RaspiBlitz with its mainnet LND passes"
preflight "$fx" "TS_OPT_PROFILE=raspiblitz TS_OPT_IMPL=lnd TS_OPT_PLATFORM=raspiblitz;"
assert_contains "$SN_OUT" "PREFLIGHT_OK" "RaspiBlitz preflight: --platform raspiblitz matches"
preflight "$fx" "TS_OPT_PROFILE=raspiblitz TS_OPT_IMPL=lnd TS_OPT_PLATFORM=baremetal;"
assert_json "$doc" 'd["errors"][0]["code"]' "E_PLATFORM_UNSUPPORTED" "RaspiBlitz preflight: --platform baremetal does not match the profile"
preflight "$fx" "TS_OPT_PROFILE=baremetal;"
assert_json "$doc" '[d["exit_code"], d["errors"][0]["code"], d["errors"][0]["message"]]' \
    "[7, \"E_PLATFORM_UNSUPPORTED\", \"This node is a RaspiBlitz: use 'install --managed raspiblitz --impl lnd|cln'\"]" \
    "Bare-metal preflight on a RaspiBlitz: refused, pointing to the raspiblitz profile"
fx=$(preflight_fixture rb-elsewhere)
preflight "$fx" "TS_OPT_PROFILE=raspiblitz TS_OPT_IMPL=lnd;"
assert_json "$doc" '[d["errors"][0]["code"], d["errors"][0]["message"]]' '["E_PLATFORM_UNSUPPORTED", "The raspiblitz profile needs a RaspiBlitz (detected: no RaspiBlitz)"]' \
    "RaspiBlitz preflight: refused on a node that is no RaspiBlitz"
fx=$(rb_fixture pf-testnet-port)
rb_unit "$fx" tlnd.service "$(rb_lnd_exec t)"
printf '%s\n' "${rb_lnd_conf//listen=0.0.0.0:9735/listen=0.0.0.0:19735}" > "$fx/fs/mnt/hdd/app-data/lnd/tlnd.conf"
preflight "$fx" "TS_OPT_PROFILE=raspiblitz TS_OPT_IMPL=lnd TS_OPT_NETWORK=testnet;"
assert_json "$doc" '[d["errors"][0]["code"], d["errors"][0]["message"]]' '["E_LN_PORT", "Lightning listens on port(s) 19735; the TunnelSats server forwards to 9735"]' \
    "RaspiBlitz preflight: testnet LND on RaspiBlitz's default port 19735 is refused (the server forwards to 9735)"
# A leftover drop-in of a prefixed unit is a managed artifact: detect reports it, install refuses
fx=$(rb_preflight_fixture leftover)
mkdir -p "$fx/fs/etc/systemd/system/tlnd.service.d"
run_snippet "$fx" 'ts_m_render_ln_dropin > "$TS_FS_ROOT/etc/systemd/system/tlnd.service.d/tunnelsats-managed.conf"; TS_JSON=1; TS_COMMAND=detect; TS_OUT_FD=1; cmd_detect'
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["install"]["kind"], d["install"]["candidates"], [a["status"] for a in d["install"]["artifacts"] if a["location"] == "/etc/systemd/system/tlnd.service.d/tunnelsats-managed.conf"]]' \
    '["unknown", ["managed"], ["present"]]' "detect: a leftover drop-in of tlnd.service is a managed artifact"
preflight "$fx" "TS_OPT_PROFILE=raspiblitz TS_OPT_IMPL=lnd;"
assert_json "$doc" 'd["errors"][0]["code"]' "E_LEGACY_INSTALL" "RaspiBlitz preflight: install refuses while that drop-in exists"

# CLI: --impl is required for the raspiblitz profile, --network takes mainnet, testnet or signet and
# belongs to install --managed raspiblitz only (usage errors come before anything else)
assert_equals "raspiblitz cln signet ." "$(bash -c 'source "$1"; shift; ts_parse_cli "$@"; echo "${TS_OPT_PROFILE} ${TS_OPT_IMPL} ${TS_OPT_NETWORK} .${TS_USAGE_ERROR}"' _ "$SCRIPT_UNDER_TEST" install --managed raspiblitz --impl cln --network signet)" \
    "CLI: install --managed raspiblitz --impl cln --network signet"
cli --json install --managed raspiblitz --config "$TMP_ROOT/fx/render/sub.conf"
assert_equals "2" "$CLI_RC" "CLI: install --managed raspiblitz without --impl exits 2"
assert_json "$CLI_OUT" '[d["errors"][0]["code"], d["errors"][0]["message"]]' '["E_USAGE", "install --managed raspiblitz requires --impl lnd or --impl cln"]' \
    "CLI: missing --impl is a usage error"
cli --json install --managed raspiblitz --impl lit --config "$TMP_ROOT/fx/render/sub.conf"
assert_json "$CLI_OUT" 'd["errors"][0]["message"]' "install --managed raspiblitz supports --impl lnd or --impl cln, not lit" "CLI: --impl lit is a usage error for RaspiBlitz"
cli --json install --managed raspiblitz --impl lnd --network regtest --config "$TMP_ROOT/fx/render/sub.conf"
assert_equals "2" "$CLI_RC" "CLI: an invalid --network exits 2"
assert_json "$CLI_OUT" '[d["errors"][0]["code"], d["errors"][0]["message"]]' "[\"E_USAGE\", \"Invalid --network 'regtest' (expected: mainnet, testnet, signet)\"]" \
    "CLI: an invalid --network is a usage error naming the values"
cli --json install --managed raspiblitz --impl lnd --network
assert_json "$CLI_OUT" 'd["errors"][0]["message"]' "--network requires a value" "CLI: --network without a value is a usage error"
cli --json install --managed baremetal --network testnet --config "$TMP_ROOT/fx/render/sub.conf"
assert_json "$CLI_OUT" 'd["errors"][0]["message"]' "--network is used by 'install --managed raspiblitz' only" "CLI: --network is refused for the baremetal profile"
cli --json verify --network testnet
assert_json "$CLI_OUT" 'd["errors"][0]["message"]' "--network is not supported by 'verify'" "CLI: verify rejects --network"
cli help
assert_contains "$CLI_OUT" "install --managed raspiblitz --impl lnd|cln [--network mainnet|testnet|signet]" "Help: documents the raspiblitz profile"
assert_contains "$CLI_OUT" "--network <chain>" "Help: documents --network"

# Full install as provisioning runs it (--non-interactive --yes --json) against the stubs: starting
# the kill switch unit runs the production managed-arm, as systemd runs its ExecStart; the tunnel
# stays down (wg show fails)
RB_BIN="$TMP_ROOT/rb-bin"
mkdir -p "$RB_BIN"
cat > "$RB_BIN/systemctl" <<EOF
#!/bin/bash
# systemctl for full installs: starting the kill switch unit runs its ExecStart (managed-arm)
if [[ "\${1:-}" == "start" ]] && [[ "\${!#}" == "tunnelsats-killswitch.service" ]]; then
    printf 'systemctl %s\n' "\$*" >> "\${STUB_STATE:?}/calls"
    bash -c 'source "\$SCRIPT_UNDER_TEST"; ts_m_expected_owner() { id -u; }; ts_m_cmd_arm' >> "\$STUB_STATE/arm.log" 2>&1
    exit \$?
fi
exec "$STUB_BIN/systemctl" "\$@"
EOF
printf '#!/bin/bash\nexit 1\n' > "$RB_BIN/wg"
printf '#!/bin/bash\nexit 0\n' > "$RB_BIN/wg-quick"
chmod +x "$RB_BIN"/*
rb_env="SYSTEMCTL_BIN='$RB_BIN/systemctl'; WG_BIN='$RB_BIN/wg'; WG_QUICK_BIN='$RB_BIN/wg-quick';"
rb_install() {  # $1 = fixture, $2 = impl, $3 = network, $4 = 1 for JSON (default) or 0 for the human output
    mkdir -p "$1/tmp" "$1/fs/lib/systemd/system"
    : > "$1/fs/lib/systemd/system/wg-quick@.service"
    run_snippet "$1" "$rb_env export TMPDIR='$1/tmp'
TS_JSON=${4:-1}; TS_COMMAND=install; TS_OUT_FD=1; TS_NONINTERACTIVE=1; TS_OPT_YES=1
TS_OPT_MANAGED=1 TS_OPT_PROFILE=raspiblitz TS_OPT_IMPL=$2 TS_OPT_NETWORK=$3 CONFIG_FILE='$TMP_ROOT/fx/render/sub.conf'
cmd_install_managed"
    doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
}
ln_starts() {  # $1 = fixture, $2 = unit: prints the calls that start or restart the unit
    grep -E "^systemctl (start|restart)( --no-block)? $2\$" "$1/state/calls" || true
}

# Testnet CLN, not running: installed, not started
fx=$(rb_fixture full-cln-testnet)
rb_unit "$fx" tlightningd.service "$(rb_cln_exec /home/bitcoin/.lightning/testnet/config)"
printf '%s\n' "$rb_cln_conf_testnet" > "$fx/fs/mnt/hdd/app-data/.lightning/testnet/config"
rb_install "$fx" cln testnet
assert_equals "0" "$SN_RC" "Provisioning install: testnet CLN, unit inactive: exits 0"
assert_json "$doc" '[d["ok"], d["profile"], d["impl"], d["unit"], d["node_user"], d["ln_was_active"], d["ln_restarted"], d["node_config"], d["tunnel_started"]]' \
    '[true, "raspiblitz", "cln", "tlightningd.service", "bitcoin", false, false, "clean", true]' \
    "Provisioning install: the document names profile and unit; Lightning was not running and is not started"
assert_equals "" "$(ln_starts "$fx" tlightningd.service)" "Provisioning install: tlightningd.service is never started or restarted"
assert_contains "$(cat "$fx/state/calls")" "systemctl start tunnelsats-killswitch.service" "Provisioning install: the kill switch unit is started"
assert_contains "$SN_OUT" "tlightningd.service is not running (inactive); install does not start it" "Provisioning install: and says so"
inv_doc=$(cat "$fx/fs/etc/tunnelsats/managed.json" 2>/dev/null || true)
assert_json "$inv_doc" '[d["state"], d["profile"], d["unit"], "/etc/systemd/system/tlightningd.service.d/tunnelsats-managed.conf" in [f["path"] for f in d["files"]]]' \
    '["installed", "raspiblitz", "tlightningd.service", true]' "Provisioning install: the inventory records the profile, the unit and its drop-in"
assert_contains "$(cat "$fx/fs/etc/systemd/system/tlightningd.service.d/tunnelsats-managed.conf" 2>/dev/null)" "Slice=tunnelsats.slice" \
    "Provisioning install: the drop-in puts tlightningd.service into the slice"
assert_contains "$(cat "$fx/fs/etc/systemd/system/tunnelsats-killswitch.service" 2>/dev/null)" "Before=tlightningd.service wg-quick@tunnelsatsv2.service" \
    "Provisioning install: the kill switch starts before tlightningd.service"
assert_json "$(cat "$fx/fs/run/tunnelsats/attest.json" 2>/dev/null)" '[d["profile"], d["unit"]]' '["raspiblitz", "tlightningd.service"]' \
    "Provisioning install: attested by the production managed-arm"

# Guard contract: verify --json --no-probe exits 0 or 5 only while the dataplane holds for the unit
echo "activating" > "$fx/state/unit_tlightningd.service_ActiveState"
echo "start-pre" > "$fx/state/unit_tlightningd.service_SubState"
echo "/etc/systemd/system/tlightningd.service.d/tunnelsats-managed.conf" > "$fx/state/unit_tlightningd.service_DropInPaths"
echo "tunnelsats.slice" > "$fx/state/unit_tlightningd.service_Slice"
: > "$fx/state/calls"
run_snippet "$fx" "$rb_env TS_JSON=1; TS_COMMAND=verify; TS_OUT_FD=1; TS_OPT_NO_PROBE=1; cmd_verify"
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_equals "5" "$SN_RC" "Guard contract: while the guarded unit starts (kill switch armed, tunnel down) verify exits 5"
assert_json "$doc" '[d["verdict"], d["profile"], d["unit"], d["probes"], sorted(c["id"] for c in d["checks"] if c["result"] == "fail"), [c["id"] for c in d["checks"] if c["result"] != "pass" and c["class"] == "unsafe"]]' \
    '["degraded", "raspiblitz", "tlightningd.service", "skipped", ["ln_membership", "wg_endpoint", "wg_handshake"], []]' \
    "Guard contract: degraded, with the unit named and only degraded checks failing"
assert_json "$doc" '[d["contract"], d["command"], d["ok"], d["exit_code"], d["managed"], d["profile"], d["install_state"], d["unit"], d["impl"], d["emergency_block"], d["verdict"], d["probes"], all({"id", "class", "result"} <= set(c) for c in d["checks"]), sorted({"host", "ipv4", "vpn_port"} & set(d["endpoint"]))]' \
    '[1, "verify", false, 5, true, "raspiblitz", "installed", "tlightningd.service", "cln", false, "degraded", "skipped", true, ["host", "ipv4", "vpn_port"]]' \
    "Guard contract: the fields of contract 1 the guard relies on (docs/managed-mode.md) are there"
assert_equals "" "$(grep -E '^(systemd-run|curl) ' "$fx/state/calls" || true)" "Guard contract: --no-probe sends no probe"
assert_equals "" "$(grep -E '^(ip (-[46] )?(rule|route) (add|del)|nft -f|nft delete|systemctl (start|stop|restart|enable|disable))' "$fx/state/calls" || true)" \
    "Guard contract: verify changes nothing"
cp "$fx/state/nft_table" "$fx/state/nft_table.saved"
rm -f "$fx/state/nft_table"
run_snippet "$fx" "$rb_env TS_JSON=1; TS_COMMAND=verify; TS_OUT_FD=1; TS_OPT_NO_PROBE=1; cmd_verify"
assert_equals "4" "$SN_RC" "Guard contract: without the kill switch table verify exits 4 (no clearnet flags: Tor-only start)"
mv "$fx/state/nft_table.saved" "$fx/state/nft_table"
fx2=$(rb_fixture after-sd-update)
rb_unit "$fx2" lnd.service "$(rb_lnd_exec "")"
run_snippet "$fx2" "$rb_env TS_JSON=1; TS_COMMAND=verify; TS_OUT_FD=1; TS_OPT_NO_PROBE=1; cmd_verify"
assert_equals "3" "$SN_RC" "Guard contract: after an SD-card update (no managed install yet) verify exits 3 (no clearnet flags: Tor-only start)"
assert_contains "$SN_OUT" '"code":"E_NOT_INSTALLED"' "Guard contract: reported as E_NOT_INSTALLED"

# Uninstall of the RaspiBlitz install removes everything; the unit was not running and stays so
echo "inactive" > "$fx/state/unit_tlightningd.service_ActiveState"
rm -f "$fx/state/unit_tlightningd.service_DropInPaths" "$fx/state/unit_tlightningd.service_Slice"
run_snippet "$fx" "$rb_env TS_JSON=1; TS_COMMAND=uninstall; TS_OUT_FD=1; TS_NONINTERACTIVE=1; TS_OPT_YES=1; TS_OPT_MANAGED=1; cmd_uninstall_managed"
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["exit_code"], d["unit"], d["remaining"], d["node_config"], d["ln_started"]]' '[0, "tlightningd.service", [], "clean", false]' \
    "Uninstall (RaspiBlitz): complete, Tor-only config checked through RaspiBlitz's shell command, unit not started"
left=""
for f in /etc/systemd/system/tlightningd.service.d /etc/systemd/system/tunnelsats-killswitch.service /etc/tunnelsats /usr/local/sbin/tunnelsats /run/tunnelsats; do
    if [[ -e "$fx/fs$f" ]]; then left+=" $f"; fi
done
assert_equals "" "$left" "Uninstall (RaspiBlitz): the prefixed drop-in directory and every managed file are gone"

# Install and uninstall of mainnet LND whose unit carries RaspiBlitz's start guard; Lightning ran.
# The guard's env file, read before the removal clears /run/tunnelsats, decides whether it starts
# again. $1 = name, $2 = env file content ("-": none), $3 = mode settings (default: JSON)
rb_guard_uninstall() {
    fx=$(rb_fixture "guard-uninstall-$1")
    rb_guard_unit "$fx" lnd mainnet "" > /dev/null
    printf '%s\n' "$rb_lnd_conf" > "$fx/fs/mnt/hdd/app-data/lnd/lnd.conf"
    rb_install "$fx" lnd mainnet
    install_doc="$doc"
    echo "active" > "$fx/state/unit_lnd.service_ActiveState"
    touch "$fx/state/stateful_units"
    if [[ "$2" != "-" ]]; then
        printf '%s' "$2" > "$fx/fs/run/tunnelsats/hybrid-lnd.env"
    fi
    : > "$fx/state/calls"
    run_snippet "$fx" "$rb_env ${3:-TS_JSON=1; TS_OUT_FD=1; TS_NONINTERACTIVE=1;} TS_COMMAND=uninstall; TS_OPT_YES=1; TS_OPT_MANAGED=1; cmd_uninstall_managed"
    doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
}
rb_guard_uninstall flags "TUNNELSATS_LND_ARGS=${rb_flags_lnd}"$'\n'
assert_json "$install_doc" '[d["exit_code"], d["node_config"]]' '[0, "clean"]' \
    "Install (RaspiBlitz start guard): the unit with the guard variable and a Tor-only lnd.conf is clean"
assert_json "$doc" '[d["exit_code"], d["remaining"], d["ln_was_active"], d["ln_started"], d["ln_disabled"], d["node_config"]]' \
    '[0, [], true, false, true, "unknown"]' "Uninstall (RaspiBlitz start guard, flags): complete; Lightning stays stopped and is disabled"
assert_json "$doc" '[d["action_required"]["reason"], d["action_required"]["lines"], d["action_required"]["then"]]' \
    '["node_config_unknown", [], "systemctl enable --now lnd.service"]' "Uninstall (RaspiBlitz start guard, flags): action_required in the usual form"
assert_json "$doc" 'd["action_required"]["detail"]' \
    "TunnelSats is still on in RaspiBlitz (/run/tunnelsats/hybrid-lnd.env holds the clearnet flags of the current start of lnd.service): remove it in the RaspiBlitz menu (SUBSCRIBE > TunnelSats > REMOVE), then enable and start lnd.service" \
    "Uninstall (RaspiBlitz start guard, flags): its detail points to REMOVE in the RaspiBlitz menu"
assert_contains "$(cat "$fx/state/calls")" "systemctl disable lnd.service" "Uninstall (RaspiBlitz start guard, flags): the unit is disabled"
assert_equals "" "$(ln_starts "$fx" lnd.service)" "Uninstall (RaspiBlitz start guard, flags): and not started"
if [[ ! -e "$fx/fs/run/tunnelsats" ]]; then
    pass "Uninstall (RaspiBlitz start guard, flags): the env file was read before the removal cleared /run/tunnelsats"
else
    fail "Uninstall (RaspiBlitz start guard, flags): the env file was read before the removal cleared /run/tunnelsats"
fi
for g_env in empty absent; do
    g_content="-"
    if [[ "$g_env" == "empty" ]]; then
        g_content=$'TUNNELSATS_LND_ARGS=\n'
    fi
    rb_guard_uninstall "$g_env" "$g_content"
    assert_json "$doc" '[d["exit_code"], d["ln_started"], d["ln_disabled"], d["node_config"], d["action_required"]]' '[0, true, false, "clean", null]' \
        "Uninstall (RaspiBlitz start guard, env file ${g_env}): clean, so Lightning starts again"
    assert_equals "systemctl start lnd.service" "$(ln_starts "$fx" lnd.service)" "Uninstall (RaspiBlitz start guard, env file ${g_env}): through one start"
done
# Interactively, nothing the operator edits changes the flags read before the removal: no re-check
rb_guard_uninstall interactive "TUNNELSATS_LND_ARGS=${rb_flags_lnd}"$'\n' "TS_JSON=0; TS_NONINTERACTIVE=0; exec </dev/null;"
assert_equals "1" "$(grep -c "could not be checked" <<< "$SN_OUT")" \
    "Uninstall (RaspiBlitz start guard, interactive): the flags are reported once, without a re-check loop"
assert_contains "$SN_OUT" "SUBSCRIBE > TunnelSats > REMOVE" "Uninstall (RaspiBlitz start guard, interactive): pointing to REMOVE in the RaspiBlitz menu"
assert_contains "$(cat "$fx/state/calls")" "systemctl disable lnd.service" "Uninstall (RaspiBlitz start guard, interactive): the unit is disabled"
assert_equals "" "$(ln_starts "$fx" lnd.service)" "Uninstall (RaspiBlitz start guard, interactive): and not started"

# Mainnet LND that waits for its automatic restart (auto-restart, for example while a start guard
# holds it back): left to its own restart; a running one is restarted into the slice
fx=$(rb_preflight_fixture full-autorestart)
echo "activating" > "$fx/state/unit_lnd.service_ActiveState"
echo "auto-restart" > "$fx/state/unit_lnd.service_SubState"
rb_install "$fx" lnd mainnet
assert_json "$doc" '[d["exit_code"], d["unit"], d["ln_was_active"], d["ln_restarted"]]' '[0, "lnd.service", false, false]' \
    "Provisioning install: mainnet LND in auto-restart is left to its own restart"
assert_equals "" "$(ln_starts "$fx" lnd.service)" "Provisioning install: lnd.service is not restarted"
assert_contains "$SN_OUT" "lnd.service waits for its next automatic restart (auto-restart)" "Provisioning install: and says so"
fx=$(rb_preflight_fixture full-active)
echo "active" > "$fx/state/unit_lnd.service_ActiveState"
rb_install "$fx" lnd ""
assert_json "$doc" '[d["exit_code"], d["unit"], d["ln_was_active"], d["ln_restarted"]]' '[0, "lnd.service", true, true]' \
    "Install (RaspiBlitz): a running LND is restarted into the slice"
assert_equals "systemctl restart lnd.service" "$(ln_starts "$fx" lnd.service)" "Install (RaspiBlitz): through one restart"

# The human output names the config file the unit reads (it depends on the chain on RaspiBlitz)
fx=$(rb_fixture full-human)
rb_unit "$fx" tlightningd.service "$(rb_cln_exec /home/bitcoin/.lightning/testnet/config)"
printf '%s\n' "$rb_cln_conf_testnet" > "$fx/fs/mnt/hdd/app-data/.lightning/testnet/config"
rb_install "$fx" cln testnet 0
assert_equals "0" "$SN_RC" "Install (RaspiBlitz, human output): exits 0"
assert_contains "$(printf '%s\n' "$SN_OUT" | sed 's/\x1b\[[0-9;]*m//g')" "Edit: /home/bitcoin/.lightning/testnet/config" \
    "Install (RaspiBlitz, human output): names the testnet config"
run_snippet "$fx" 'LN_IMPL=lnd PLATFORM=raspiblitz node_user=bitcoin TS_NODE_CONF_FILE=/mnt/hdd/app-data/lnd/tlnd.conf print_node_config_instructions de2.tunnelsats.com 24556 install | sed "s/\x1b\[[0-9;]*m//g" | grep "^Edit:"
LN_IMPL=lnd PLATFORM=baremetal node_user=bitcoin print_node_config_instructions de2.tunnelsats.com 24556 install | sed "s/\x1b\[[0-9;]*m//g" | grep "^Edit:"'
assert_equals $'Edit: sudo nano /mnt/hdd/app-data/lnd/tlnd.conf\nEdit: sudo nano /home/bitcoin/.lnd/lnd.conf' "$SN_OUT" \
    "Node config instructions: the RaspiBlitz install names tlnd.conf; without a known file the bare-metal guess is unchanged"

# A missing --config file is a clear JSON error during provisioning (through the CLI entry point)
fx=$(rb_preflight_fixture missing-config)
mkdir -p "$fx/tmp"
run_snippet "$fx" "$rb_env export TMPDIR='$fx/tmp'; parse_args --json install --managed raspiblitz --impl lnd --non-interactive --yes --config '$fx/missing.conf'"
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["exit_code"], d["errors"][0]["code"], d["errors"][0]["message"]]' "[8, \"E_CONFIG_INVALID\", \"WireGuard config not found: $fx/missing.conf\"]" \
    "Provisioning install: a missing --config file is reported as E_CONFIG_INVALID (exit 8)"
if [[ ! -e "$fx/fs/etc/tunnelsats" ]] && [[ ! -e "$fx/fs/run/tunnelsats" ]]; then
    pass "Provisioning install: and nothing is left behind"
else
    fail "Provisioning install: and nothing is left behind"
fi
# The same on bare metal: E_CONFIG_INVALID (exit 8), not an internal error
fx=$(preflight_fixture missing-config)
mkdir -p "$fx/tmp"
run_snippet "$fx" "export TMPDIR='$fx/tmp'; parse_args --json install --managed baremetal --non-interactive --yes --config '$fx/missing.conf'"
doc=$(printf '%s\n' "$SN_OUT" | grep '^{"contract"' || true)
assert_json "$doc" '[d["exit_code"], d["errors"][0]["code"], d["errors"][0]["message"]]' "[8, \"E_CONFIG_INVALID\", \"WireGuard config not found: $fx/missing.conf\"]" \
    "Bare-metal install: a missing --config file is reported as E_CONFIG_INVALID (exit 8) as well"
if [[ ! -e "$fx/fs/etc/tunnelsats" ]] && [[ ! -e "$fx/fs/run/tunnelsats" ]]; then
    pass "Bare-metal install: and nothing is left behind"
else
    fail "Bare-metal install: and nothing is left behind"
fi

echo ""
echo "Passed: $pass_count"
echo "Failed: $fail_count"
if [[ "$fail_count" -ne 0 ]]; then
    exit 1
fi
