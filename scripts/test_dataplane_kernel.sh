#!/bin/bash
# Real-kernel tests of managed mode (bare-metal profile): install --managed baremetal, verify, the
# verifier timer and uninstall --managed against the kernel's nftables, policy routing, WireGuard,
# cgroups and systemd. For disposable VMs only (the GitHub Actions runners of kernel.yml): it
# creates a user, systemd units, network namespaces and nftables tables, and changes routing and
# sysctls. Needs root and TS_KERNEL_TEST=1; without TS_KERNEL_TEST it prints SKIP and exits 0.
#
# Topology
#   ts-net   the "internet": echo services on 203.0.113.10:80 and 203.0.113.11:80 answer with the
#            client's source address; 2001:db8:113::40 stands in for the TunnelSats host's IPv6
#            address (the target of verify's IPv6 probe); a peer on 203.0.113.20:9735 accepts and
#            closes connections; 203.0.113.30 is an inbound client.
#   host <-> ts-net   veth ts-home (host 198.18.1.1/30, 2001:db8:1::1/64): the regular internet
#            connection; 198.18.1.1 is the "home address".
#   ts-lan   a local network next to the host: veth ts-lan (host 192.168.77.1/24, a connected
#            route in table main) and a service on 192.168.77.2:80 that answers with the client's
#            address. The slice reaches it directly, the emergency block keeps it.
#   ts-srv   fake TunnelSats server. veth ts-under (host 198.18.0.1/30, server 198.18.0.2/30)
#            carries the WireGuard packets; veth ts-up (server 198.18.2.1/30, ts-net
#            198.18.2.2/30) is its upstream. WireGuard listens on 51820 (tunnel 10.9.0.1/24,
#            client 10.9.0.2/32), masquerades the client toward ts-net and forwards
#            198.18.2.1:<vpn port> to 10.9.0.2:9735. The client config uses 198.18.2.1:51820 as
#            endpoint, so the exit address equals the endpoint address, as on a real server.
#            verify's kill switch probe sends one datagram from the slice to 198.18.2.1, port 9,
#            bound to ts-under (the interface of the host's route to the endpoint).
#
# Routing of the host: the "internet" routes (203.0.113.0/24, the server's 198.18.2.0/30 and
# 2001:db8:113::/64) live in table 100, looked up by a rule at priority 32000, after the TunnelSats
# rules 21820-21822 and before table main. That reproduces how a default route behaves: rule 21820
# (lookup main suppress_prefixlength 0) skips only /0 routes, so a /24 in table main would win at
# 21820 and send the slice's packets out of the home interface (where the kill switch drops them)
# instead of into the tunnel. The runner's own default route stays untouched.
#
# Traffic outside the tunnel is counted twice: on the host by a test-only nft table (packets of
# the node user leaving through ts-home to non-LAN addresses), and in ts-net (packets from the
# home address to the peer 203.0.113.20). The second counter also works across "nft flush ruleset"
# on the host (S7), which removes the first one. A third counter in ts-net (packets from the home
# address to the echo services) shows that verify never reveals the home address to them.
#
# Scenarios: cycle 1 runs S1-S6, S11 (kill chain removed), S12 (arming fails, emergency block, a
# rule that bypasses it, the local network), S13 (damaged install record), S8 (strict rp_filter)
# and S9 (uninstall, clean node config); cycle 2 runs S7 (nft flush ruleset) and S9 with TunnelSats
# settings in the node config; cycle 3 runs S7 with the uid backstop.

set -euo pipefail

if [[ "${TS_KERNEL_TEST:-}" != "1" ]]; then
    echo "SKIP: real-kernel dataplane tests run only with TS_KERNEL_TEST=1 as root on a disposable VM"
    exit 0
fi
if [[ "$EUID" -ne 0 ]]; then
    echo "FAIL: real-kernel dataplane tests need root"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="${SCRIPT_DIR}/tunnelsats.sh"
WORK="$(mktemp -d /tmp/ts-kernel.XXXXXX)"
CI_DIR="/opt/ts-ci"
NODE_USER="bitcoin"
NODE_CONF="/home/${NODE_USER}/.lnd/lnd.conf"
LN_UNIT_FILE="/etc/systemd/system/lnd.service"
VPN_PORT=24556
ECHO1="http://203.0.113.10/"
ECHO2="http://203.0.113.11/"
TSHOST6="http://[2001:db8:113::40]/"
HOME_ADDR="198.18.1.1"
SERVER_ADDR="198.18.2.1"
export TS_VERIFY_ECHO_URLS="${ECHO1} ${ECHO2}"
export TS_VERIFY_IPV6_URL="${TSHOST6}"
export NO_COLOR=1

pass_count=0
fail_count=0
NODE_UID=""

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

json_get() {
    printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    v = eval(sys.argv[1])
    print(v if isinstance(v, str) else json.dumps(v))
except Exception as e:
    print("<invalid: %s>" % e)
' "$2"
}

nsx() {
    local ns="$1"
    shift
    ip netns exec "$ns" "$@"
}

step() {
    echo ""
    echo "=== $* ==="
}

# ---------------------------------------------------------------------------
# Diagnostics and cleanup
# ---------------------------------------------------------------------------
diagnostics() {
    echo ""
    echo "=== Diagnostics ==="
    set +e
    ip -4 rule show
    ip -6 rule show
    echo "--- table 51820"
    ip -4 route show table 51820
    ip -6 route show table 51820
    echo "--- nft"
    nft list ruleset 2>&1 | head -n 150
    echo "--- wg"
    wg show 2>&1 | sed -E 's/(private key|preshared key): .*/\1: (hidden)/'
    echo "--- units"
    systemctl --no-pager status tunnelsats.slice tunnelsats-killswitch.service tunnelsats-verifier.timer \
        wg-quick@tunnelsatsv2.service lnd.service 2>&1 | head -n 80
    echo "--- journal"
    journalctl --no-pager -n 120 -u tunnelsats-killswitch.service -u tunnelsats-verifier.service \
        -u wg-quick@tunnelsatsv2.service -u lnd.service 2>&1 | tail -n 120
    echo "--- run state"
    cat /run/tunnelsats/attest.json /run/tunnelsats/verifier.state 2>&1
    set -e
}

cleanup() {
    local rc=$?
    set +e
    if [[ "$rc" -ne 0 ]] || [[ "$fail_count" -ne 0 ]]; then
        diagnostics
    fi
    if [[ -f /etc/tunnelsats/managed.json ]]; then
        TS_M_ANNOUNCE_WAIT=0 bash "$TS" uninstall --managed --yes --non-interactive >/dev/null 2>&1
    fi
    systemctl stop lnd.service >/dev/null 2>&1
    rm -f "$LN_UNIT_FILE"
    systemctl daemon-reload >/dev/null 2>&1
    if [[ -f "$WORK/echo.pid" ]]; then
        kill "$(cat "$WORK/echo.pid")" >/dev/null 2>&1
    fi
    if [[ -f "$WORK/lan.pid" ]]; then
        kill "$(cat "$WORK/lan.pid")" >/dev/null 2>&1
    fi
    ip netns del ts-lan >/dev/null 2>&1
    ip link del ts-lan >/dev/null 2>&1
    ip netns del ts-net >/dev/null 2>&1
    ip netns del ts-srv >/dev/null 2>&1
    ip link del ts-home >/dev/null 2>&1
    ip link del ts-under >/dev/null 2>&1
    ip rule del priority 32000 lookup 100 >/dev/null 2>&1
    ip rule del priority 100 lookup 100 >/dev/null 2>&1
    ip -6 rule del priority 32000 lookup 100 >/dev/null 2>&1
    nft delete table inet ts_test_outside >/dev/null 2>&1
    rm -rf "$WORK" "$CI_DIR"
    exit "$rc"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixtures: stub Lightning daemon, echo services, topology, fake server, client config
# ---------------------------------------------------------------------------
write_helpers() {
    mkdir -p "$CI_DIR"
    cat > "$CI_DIR/stub_ln.py" <<'EOF'
#!/usr/bin/env python3
"""Stub Lightning daemon for the kernel tests (lnd.service, user bitcoin).

Listens on 0.0.0.0:9735 like a node and answers every connection with a banner. A control API
on 127.0.0.1:9911 makes the daemon, or a child process it starts (like a CLN subdaemon), open
outbound connections, and runs a loop of short connections to a peer (a gossip stand-in).
"""
import json, os, socket, subprocess, sys, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

FETCH = """
import json, os, sys, urllib.request
body = ""
try:
    with urllib.request.urlopen(sys.argv[1], timeout=5) as r:
        body = r.read().decode().strip()
except Exception:
    pass
cg = [l[3:].strip() for l in open("/proc/self/cgroup") if l.startswith("0::")]
print(json.dumps({"pid": os.getpid(), "cgroup": cg[0] if cg else "", "body": body}))
"""

gossip = {"run": False, "attempts": 0, "connected": 0}


def p2p():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", 9735))
    srv.listen(64)
    while True:
        conn, _ = srv.accept()
        try:
            conn.sendall(b"TS-STUB-LN\n")
        except OSError:
            pass
        finally:
            conn.close()


def fetch_here(url):
    out = subprocess.run([sys.executable, "-c", FETCH, url], capture_output=True, text=True, timeout=20)
    child = json.loads(out.stdout or "{}")
    return child


def gossip_loop(host, port, interval):
    while gossip["run"]:
        gossip["attempts"] += 1
        try:
            s = socket.create_connection((host, port), timeout=1)
            gossip["connected"] += 1
            s.close()
        except OSError:
            pass
        time.sleep(interval)


class Ctl(BaseHTTPRequestHandler):
    def reply(self, obj):
        body = (json.dumps(obj) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path == "/egress":
            body = ""
            try:
                with urllib.request.urlopen(q["url"], timeout=5) as r:
                    body = r.read().decode().strip()
            except Exception:
                pass
            self.reply({"pid": os.getpid(), "body": body})
        elif u.path == "/child-egress":
            child = fetch_here(q["url"])
            child["parent"] = os.getpid()
            self.reply(child)
        elif u.path == "/gossip/start":
            gossip.update(run=True, attempts=0, connected=0)
            args = (q["host"], int(q["port"]), float(q.get("interval", "0.5")))
            threading.Thread(target=gossip_loop, args=args, daemon=True).start()
            self.reply(gossip)
        elif u.path == "/gossip/stop":
            gossip["run"] = False
            self.reply(gossip)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass


threading.Thread(target=p2p, daemon=True).start()
ThreadingHTTPServer(("127.0.0.1", 9911), Ctl).serve_forever()
EOF
    cat > "$CI_DIR/echo.py" <<'EOF'
#!/usr/bin/env python3
"""Echo services and a peer for the kernel tests (network namespace ts-net), or with addresses as
arguments a local network service (network namespace ts-lan)."""
import socket, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Echo(BaseHTTPRequestHandler):
    def do_GET(self):
        body = (self.client_address[0] + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class Echo6(ThreadingHTTPServer):
    address_family = socket.AF_INET6


def peer():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("203.0.113.20", 9735))
    s.listen(64)
    while True:
        c, _ = s.accept()
        c.close()


# Echo services (verify's datagram probes need no answer, so the TunnelSats host stand-in has no
# server). With addresses as arguments it serves only those (the local network service).
if len(sys.argv) > 1:
    servers = [ThreadingHTTPServer((a, 80), Echo) for a in sys.argv[1:]]
else:
    servers = [ThreadingHTTPServer((a, 80), Echo) for a in ("203.0.113.10", "203.0.113.11")]
    for a in ("2001:db8:113::10",):
        try:
            servers.append(Echo6((a, 80), Echo))
        except OSError:
            pass
    threading.Thread(target=peer, daemon=True).start()
for s in servers:
    threading.Thread(target=s.serve_forever, daemon=True).start()
threading.Event().wait()
EOF
    chmod 0755 "$CI_DIR" "$CI_DIR"/*.py
}

# The stub Lightning unit as a package would ship it (no TunnelSats edits). $1 = description.
write_ln_unit() {
    cat > "$LN_UNIT_FILE" <<EOF
[Unit]
Description=$1
After=network-online.target

[Service]
User=${NODE_USER}
ExecStart=/usr/bin/python3 ${CI_DIR}/stub_ln.py --configfile=${NODE_CONF}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

# Node config of the stub. $1 = clean (Tor-only) or hybrid (the settings TunnelSats asks for).
write_node_conf() {
    mkdir -p "$(dirname "$NODE_CONF")"
    {
        echo "[Application Options]"
        echo "alias=ts-kernel-test"
        echo "listen=0.0.0.0:9735"
        if [[ "$1" == "hybrid" ]]; then
            echo "externalhosts=${SERVER_ADDR}:${VPN_PORT}"
        fi
        echo ""
        echo "[Tor]"
        echo "tor.active=true"
        echo "tor.streamisolation=false"
        if [[ "$1" == "hybrid" ]]; then
            echo "tor.skip-proxy-for-clearnet-targets=true"
        fi
    } > "$NODE_CONF"
    chown -R "${NODE_USER}:" "$(dirname "$NODE_CONF")"
}

setup_topology() {
    local ns
    ip netns add ts-net
    ip netns add ts-srv
    for ns in ts-net ts-srv; do
        nsx "$ns" ip link set lo up
        nsx "$ns" sysctl -q -w net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0
    done
    # Home link: host <-> ts-net
    ip link add ts-home type veth peer name ts-home-n
    ip link set ts-home-n netns ts-net
    ip addr add "${HOME_ADDR}/30" dev ts-home
    ip -6 addr add 2001:db8:1::1/64 dev ts-home nodad
    ip link set ts-home up
    nsx ts-net ip addr add 198.18.1.2/30 dev ts-home-n
    nsx ts-net ip -6 addr add 2001:db8:1::2/64 dev ts-home-n nodad
    nsx ts-net ip link set ts-home-n up
    for a in 203.0.113.10 203.0.113.11 203.0.113.20 203.0.113.30; do
        nsx ts-net ip addr add "${a}/32" dev lo
    done
    for a in 2001:db8:113::10 2001:db8:113::40; do
        nsx ts-net ip -6 addr add "${a}/128" dev lo nodad
    done
    # Underlay: host <-> ts-srv
    ip link add ts-under type veth peer name ts-under-s
    ip link set ts-under-s netns ts-srv
    ip addr add 198.18.0.1/30 dev ts-under
    ip link set ts-under up
    nsx ts-srv ip addr add 198.18.0.2/30 dev ts-under-s
    nsx ts-srv ip link set ts-under-s up
    # Server upstream: ts-srv <-> ts-net
    ip link add ts-up-s type veth peer name ts-up-n
    ip link set ts-up-s netns ts-srv
    ip link set ts-up-n netns ts-net
    nsx ts-srv ip addr add "${SERVER_ADDR}/30" dev ts-up-s
    nsx ts-srv ip link set ts-up-s up
    nsx ts-net ip addr add 198.18.2.2/30 dev ts-up-n
    nsx ts-net ip link set ts-up-n up
    nsx ts-srv ip route add default via 198.18.2.2
    nsx ts-srv sysctl -q -w net.ipv4.ip_forward=1
    # Host "internet" routes in table 100 (see the header for why not in table main)
    ip route add 203.0.113.0/24 via 198.18.1.2 dev ts-home table 100
    ip route add 198.18.2.0/30 via 198.18.0.2 dev ts-under table 100
    ip -6 route add 2001:db8:113::/64 via 2001:db8:1::2 dev ts-home table 100
    ip rule add priority 32000 lookup 100
    ip -6 rule add priority 32000 lookup 100
}

setup_server() {
    umask 077
    wg genkey > "$WORK/srv.key"
    wg pubkey < "$WORK/srv.key" > "$WORK/srv.pub"
    wg genkey > "$WORK/cli.key"
    wg pubkey < "$WORK/cli.key" > "$WORK/cli.pub"
    wg genpsk > "$WORK/psk"
    umask 022
    nsx ts-srv ip link add wg0 type wireguard
    nsx ts-srv wg set wg0 listen-port 51820 private-key "$WORK/srv.key" \
        peer "$(cat "$WORK/cli.pub")" preshared-key "$WORK/psk" allowed-ips 10.9.0.2/32
    nsx ts-srv ip addr add 10.9.0.1/24 dev wg0
    nsx ts-srv ip link set wg0 up
    nsx ts-srv nft -f - <<EOF
table inet ts_srv {
	chain pre {
		type nat hook prerouting priority dstnat; policy accept;
		iifname "ts-up-s" ip daddr ${SERVER_ADDR} tcp dport ${VPN_PORT} dnat ip to 10.9.0.2:9735
	}
	chain post {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "ts-up-s" ip saddr 10.9.0.0/24 masquerade
	}
}
EOF
    # A client config shaped like one from the TunnelSats website
    cat > "$WORK/tunnelsats_ci-test.conf" <<EOF
[Interface]
# StartTunnel
# inbound: yes
# TunnelSats WireGuard Configuration
# Server: ci-test
# Port Forwarding: ${VPN_PORT}
# myPubKey: $(cat "$WORK/cli.pub")
# Valid Until: 2030-01-01T00:00:00.000Z
PrivateKey = $(cat "$WORK/cli.key")
Address = 10.9.0.2/32
DNS = 8.8.8.8

[Peer]
PublicKey = $(cat "$WORK/srv.pub")
PresharedKey = $(cat "$WORK/psk")
Endpoint = ${SERVER_ADDR}:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
}

start_echo() {
    nsx ts-net python3 "$CI_DIR/echo.py" >/dev/null 2>&1 &
    echo $! > "$WORK/echo.pid"
    for _ in $(seq 1 50); do
        if nsx ts-net python3 -c 'import socket; socket.create_connection(("203.0.113.10", 80), 1)' 2>/dev/null; then
            return 0
        fi
        sleep 0.2
    done
    echo "FAIL: echo services did not start"
    exit 1
}

# A local network next to the host: 192.168.77.0/24 over the veth ts-lan (host 192.168.77.1, a
# connected route in table main), with a service on 192.168.77.2:80 that answers with the client's
# address
setup_lan() {
    ip netns add ts-lan
    nsx ts-lan ip link set lo up
    ip link add ts-lan type veth peer name ts-lan-n
    ip link set ts-lan-n netns ts-lan
    ip addr add 192.168.77.1/24 dev ts-lan
    ip link set ts-lan up
    nsx ts-lan ip addr add 192.168.77.2/24 dev ts-lan-n
    nsx ts-lan ip link set ts-lan-n up
    nsx ts-lan python3 "$CI_DIR/echo.py" 192.168.77.2 >/dev/null 2>&1 &
    echo $! > "$WORK/lan.pid"
    for _ in $(seq 1 50); do
        if nsx ts-lan python3 -c 'import socket; socket.create_connection(("192.168.77.2", 80), 1)' 2>/dev/null; then
            return 0
        fi
        sleep 0.2
    done
    echo "FAIL: the local network service did not start"
    exit 1
}

# Test-only counters of traffic outside the tunnel
setup_outside_counter() {
    nft -f - <<EOF
table inet ts_test_outside {
	chain post {
		type filter hook postrouting priority 300; policy accept;
		oifname "ts-home" meta skuid ${NODE_UID} ip daddr != { 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } counter
		oifname "ts-home" meta skuid ${NODE_UID} ip6 daddr != { ::1/128, fc00::/7, fe80::/10 } counter
	}
}
EOF
}

outside_count() {
    { nft list table inet ts_test_outside 2>/dev/null || true; } | sed -nE 's/.*counter packets ([0-9]+).*/\1/p' | awk '{ s += $1 } END { print s + 0 }'
}

reset_outside_counter() {
    nft delete table inet ts_test_outside >/dev/null 2>&1 || true
    setup_outside_counter
}

setup_arrival_counter() {
    nsx ts-net nft delete table inet ts_count >/dev/null 2>&1 || true
    nsx ts-net nft -f - <<EOF
table inet ts_count {
	chain pre {
		type filter hook prerouting priority -300; policy accept;
		ip saddr ${HOME_ADDR} ip daddr 203.0.113.20 counter
	}
}
EOF
}

arrival_count() {
    { nsx ts-net nft list table inet ts_count 2>/dev/null || true; } | sed -nE 's/.*counter packets ([0-9]+).*/\1/p' | awk '{ s += $1 } END { print s + 0 }'
}

# Counts packets from the home address to the echo services (verify must never cause any)
setup_echo_counter() {
    nsx ts-net nft delete table inet ts_echo >/dev/null 2>&1 || true
    nsx ts-net nft -f - <<EOF
table inet ts_echo {
	chain pre {
		type filter hook prerouting priority -300; policy accept;
		ip saddr ${HOME_ADDR} ip daddr { 203.0.113.10, 203.0.113.11 } counter
	}
}
EOF
}

echo_count() {
    { nsx ts-net nft list table inet ts_echo 2>/dev/null || true; } | sed -nE 's/.*counter packets ([0-9]+).*/\1/p' | awk '{ s += $1 } END { print s + 0 }'
}

# ---------------------------------------------------------------------------
# Probes and helpers
# ---------------------------------------------------------------------------

# Egress address seen by the echo service for a process of the node user inside the slice.
slice_egress() {
    systemd-run --quiet --wait --pipe --collect --slice=tunnelsats.slice --uid="$NODE_USER" \
        curl -s -4 --connect-timeout 4 --max-time 6 "$ECHO1" 2>/dev/null </dev/null | tr -d '[:space:]' || true
}

# Address the local network service sees for a process of the node user inside the slice.
lan_egress() {
    systemd-run --quiet --wait --pipe --collect --slice=tunnelsats.slice --uid="$NODE_USER" \
        curl -s -4 --connect-timeout 4 --max-time 6 "http://192.168.77.2/" 2>/dev/null </dev/null | tr -d '[:space:]' || true
}

root_egress() {
    curl -s -4 --connect-timeout 4 --max-time 6 "$ECHO1" 2>/dev/null | tr -d '[:space:]' || true
}

stub_get() {
    curl -s --max-time 25 "http://127.0.0.1:9911$1" 2>/dev/null || true
}

stub_egress() {
    json_get "$(stub_get "/egress?url=${ECHO1}")" 'd.get("body", "")'
}

wait_stub() {
    for _ in $(seq 1 50); do
        if curl -s --max-time 2 -o /dev/null "http://127.0.0.1:9911/nothing" 2>/dev/null; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

# Starts the stub's loop of short connections to the peer (a gossip stand-in) once the stub
# answers after its restart, and asserts that the loop runs. $1 = scenario label.
start_gossip() {
    local reply=""
    wait_stub || true
    reply=$(stub_get "/gossip/start?host=203.0.113.20&port=9735&interval=0.3")
    assert_equals "true" "$(json_get "$reply" 'd["run"]')" "$1: the stub's connection loop runs"
}

# Asserts that the loop (stop reply $2) kept running into the gap: about 10 attempts happen
# before the flush, so at least 20 means it went on during the gap. $1 = scenario label.
assert_gossip_ran() {
    local attempts
    attempts=$(json_get "$2" 'd["attempts"]')
    if [[ "$attempts" =~ ^[0-9]+$ ]] && [[ "$attempts" -ge 20 ]]; then
        pass "$1: the connection loop kept running during the gap (${attempts} attempts)"
    else
        fail "$1: the connection loop kept running during the gap (got ${attempts})"
    fi
}

# Waits up to 40 s for a WireGuard handshake, sending traffic through the tunnel meanwhile.
wait_handshake() {
    local ts
    for _ in $(seq 1 20); do
        ts=$(wg show tunnelsatsv2 latest-handshakes 2>/dev/null | awk 'NR == 1 { print $2 }')
        if [[ "${ts:-0}" =~ ^[0-9]+$ ]] && [[ "${ts:-0}" -gt 0 ]]; then
            return 0
        fi
        stub_egress >/dev/null
        sleep 2
    done
    return 1
}

ln_cgroup() {
    systemctl show -p ControlGroup --value lnd.service
}

# Runs verify; sets V_RC and V_DOC. Extra arguments go to verify.
run_verify() {
    set +e
    V_DOC=$(bash "$TS" verify --json "$@" 2>"$WORK/verify.err")
    V_RC=$?
    set -e
}

# Asserts verdict $1 of the last run_verify ($2 = description); on a mismatch it also prints the
# checks that did not pass.
assert_verdict() {
    local got
    got=$(json_get "$V_DOC" 'd["verdict"]')
    assert_equals "$1" "$got" "$2"
    if [[ "$got" != "$1" ]]; then
        echo "  checks not passing: $(json_get "$V_DOC" '[c["id"] + ": " + c["detail"] for c in d["checks"] if c["result"] != "pass"]')"
    fi
}

inbound_banner() {
    nsx ts-net python3 - "$SERVER_ADDR" "$VPN_PORT" <<'EOF' 2>/dev/null || true
import socket, sys
s = socket.socket()
s.settimeout(6)
s.bind(("203.0.113.30", 0))
try:
    s.connect((sys.argv[1], int(sys.argv[2])))
    print(s.recv(64).decode().strip())
except OSError:
    print("")
EOF
}

snapshot_rules() {
    ip -4 rule show
    echo "--"
    ip -6 rule show
}

snapshot_ruleset() {
    nft list ruleset | sed -E 's/counter packets [0-9]+ bytes [0-9]+/counter/g'
}

snapshot_etc() {
    (
        cd /etc
        find . -xdev \( -path ./ld.so.cache -o -path ./mtab \) -prune -o -printf '%y %m %u %g %p %l\n' 2>/dev/null | LC_ALL=C sort
        find . -xdev -type f ! -path ./ld.so.cache -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 sha256sum 2>/dev/null || true
    )
}

# Compares snapshot files $1 and $2; prints a short diff on mismatch.
assert_same_file() {
    if cmp -s "$1" "$2"; then
        pass "$3"
    else
        fail "$3"
        diff "$1" "$2" | head -n 30 || true
    fi
}

install_managed() {
    set +e
    I_DOC=$(bash "$TS" install --managed baremetal --config "$WORK/tunnelsats_ci-test.conf" --yes --json "$@" 2>"$WORK/install.err")
    I_RC=$?
    set -e
    if [[ "$I_RC" -ne 0 ]]; then
        tail -n 30 "$WORK/install.err"
    fi
}

uninstall_managed() {
    set +e
    # The stub Lightning daemon has no RPC: the announcement step does not wait for lncli getinfo
    U_DOC=$(TS_M_ANNOUNCE_WAIT=0 bash "$TS" uninstall --managed --yes --json 2>"$WORK/uninstall.err")
    U_RC=$?
    set -e
    if [[ "$U_RC" -ne 0 ]]; then
        tail -n 30 "$WORK/uninstall.err"
    fi
}

# Waits until the verifier re-created the kill switch table after a flush; prints the seconds.
wait_rearm() {
    local start now
    start=$(date +%s)
    while true; do
        now=$(date +%s)
        if nft list table inet tunnelsats >/dev/null 2>&1; then
            echo $((now - start))
            return 0
        fi
        if [[ $((now - start)) -gt 70 ]]; then
            echo "timeout"
            return 0
        fi
        sleep 1
    done
}

# Waits until the verifier re-armed the kill switch and released the whole emergency block (no
# rule at priority 21817, 21818 or 21819 left in either family); prints the seconds. The release
# removes those rules one by one, so waiting for the first of them alone would race the rest.
wait_release() {
    local start now rules
    start=$(date +%s)
    while true; do
        now=$(date +%s)
        rules=$(ip -4 rule show 2>/dev/null || true; ip -6 rule show 2>/dev/null || true)
        if nft list table inet tunnelsats >/dev/null 2>&1 && [[ "$rules" != *"21817:"* ]] && \
            [[ "$rules" != *"21818:"* ]] && [[ "$rules" != *"21819:"* ]]; then
            echo $((now - start))
            return 0
        fi
        if [[ $((now - start)) -gt 70 ]]; then
            echo "timeout"
            return 0
        fi
        sleep 1
    done
}

# Stops the verifier timer and waits until a verifier run in progress has finished.
pause_verifier() {
    local st
    systemctl stop tunnelsats-verifier.timer
    for _ in $(seq 1 30); do
        st=$(systemctl is-active tunnelsats-verifier.service 2>/dev/null || true)
        if [[ "$st" != "activating" ]] && [[ "$st" != "active" ]] && [[ "$st" != "deactivating" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
step "Setup: user, stub Lightning unit, topology, fake TunnelSats server"
# Prints "<IPv4> <IPv6>": how many local network exemptions (priority 21817) the node uid has.
lan_rule_count() {
    local v4 v6 sel="uidrange ${NODE_UID}-${NODE_UID} lookup main suppress_prefixlength 0"
    v4=$(ip -4 rule show 2>/dev/null | grep -c "^21817:.*${sel}" || true)
    v6=$(ip -6 rule show 2>/dev/null | grep -c "^21817:.*${sel}" || true)
    echo "${v4} ${v6}"
}
# The exemptions armed with the block: 5 IPv4 ranges, plus 2 IPv6 ranges where the host has IPv6.
if [[ -e /proc/net/if_inet6 ]]; then LAN_EXPECT="5 2"; else LAN_EXPECT="5 0"; fi
echo "Kernel $(uname -r), $(nft --version), $(wg --version | head -n 1), systemd $(systemctl --version | head -n 1 | awk '{ print $2 }')"
if ! id "$NODE_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "/home/${NODE_USER}" --shell /usr/sbin/nologin "$NODE_USER"
fi
NODE_UID=$(id -u "$NODE_USER")
write_helpers
write_node_conf clean
write_ln_unit "LND stub for the TunnelSats kernel tests"
ORIG_LN_UNIT=$(cat "$LN_UNIT_FILE")
systemctl daemon-reload
systemctl start lnd.service
setup_topology
setup_server
start_echo
setup_lan
wait_stub || { echo "FAIL: stub Lightning daemon did not start"; exit 1; }
setup_outside_counter
setup_arrival_counter
assert_equals "$HOME_ADDR" "$(root_egress)" "Setup: root reaches the echo service with the home address"
assert_equals "$HOME_ADDR" "$(stub_egress)" "Setup: before install the stub uses the home address (the unmanaged baseline)"
# The baseline above is traffic outside the tunnel by design: count from zero from here on
reset_outside_counter

# ---------------------------------------------------------------------------
# Cycle 1: S1-S6, S11-S13, S8, then S9 with a clean node config
# ---------------------------------------------------------------------------
snapshot_rules > "$WORK/b1.rules"
snapshot_ruleset > "$WORK/b1.ruleset"
snapshot_etc > "$WORK/b1.etc"
sha256sum "$NODE_CONF" > "$WORK/b1.conf"

step "S1 install, verify protected, slice egress through the tunnel"
install_managed
assert_equals "0" "$I_RC" "S1: install --managed baremetal exits 0"
assert_equals '[true, "lnd.service", true]' "$(json_get "$I_DOC" '[d["ok"], d["unit"], d["ln_restarted"]]')" "S1: install document"
assert_equals "/tunnelsats.slice/lnd.service" "$(ln_cgroup)" "S1: lnd.service runs in tunnelsats.slice"
wait_handshake || fail "S1: no WireGuard handshake within 40 s"
assert_equals "$SERVER_ADDR" "$(slice_egress)" "S1: slice egress equals the server address"
assert_equals "$SERVER_ADDR" "$(stub_egress)" "S1: the Lightning stub's egress equals the server address"
assert_equals "$HOME_ADDR" "$(root_egress)" "S1: root outside the slice keeps the home address (split tunnel)"
assert_equals "192.168.77.1" "$(lan_egress)" "S1: the slice reaches the local network directly"
assert_contains "$(nft list table inet tunnelsats)" 'socket cgroupv2 level 1 "tunnelsats.slice"' "S1: kill switch table references the slice"
assert_contains "$(ip -4 rule show)" "21821:	from all fwmark 0x1000000/0xff000000 lookup 51820" "S1: rule 21821 present"
assert_contains "$(ip -4 route show table 51820)" "blackhole default metric 4294967295" "S1: blackhole in table 51820"
assert_contains "$(ip -4 route show table 51820)" "default dev tunnelsatsv2" "S1: tunnel route in table 51820"
setup_echo_counter
run_verify
assert_equals "0" "$V_RC" "S1: verify exits 0"
assert_verdict protected "S1: verify verdict protected"
assert_equals "[]" "$(json_get "$V_DOC" '[c["id"] + ": " + c["detail"] for c in d["checks"] if c["result"] != "pass"]')" "S1: every verify check passes"
assert_equals "0" "$(echo_count)" "S1: verify never shows the home address to the echo services"
assert_equals "a datagram from inside the slice to ${SERVER_ADDR} through ts-under was stopped on this host (EPERM)" \
    "$(json_get "$V_DOC" '[c["detail"] for c in d["checks"] if c["id"] == "killswitch_probe"][0]')" \
    "S1: the kill chain drops the kill switch datagram to the WireGuard endpoint (EPERM)"
assert_contains "$(json_get "$V_DOC" '[c["detail"] for c in d["checks"] if c["id"] == "ipv6_probe"][0]')" \
    "an IPv6 datagram from inside the slice to 2001:db8:113::40 was stopped on this host" "S1: the IPv6 datagram is stopped on the host"
assert_not_contains "$V_DOC" "direct" "S1: verify fetches and reports no direct address"
assert_equals "0" "$(outside_count)" "S1: no traffic outside the tunnel"
set +e
ST_OUT=$(bash "$TS" status 2>&1 </dev/null)
ST_RC=$?
set -e
if [[ "$ST_RC" -ne 0 ]]; then
    printf '%s\n' "$ST_OUT" | tail -n 25
fi
assert_equals "0" "$ST_RC" "S1: status on a managed install runs verify (exit 0)"
assert_contains "$ST_OUT" "Protected" "S1: status reports Protected"

step "S2 inbound through the tunnel"
assert_equals "TS-STUB-LN" "$(inbound_banner)" "S2: a peer on the internet reaches the stub through ${SERVER_ADDR}:${VPN_PORT}"

step "S3 tunnel stopped"
systemctl stop wg-quick@tunnelsatsv2.service
assert_equals "" "$(slice_egress)" "S3: slice egress gets no answer"
assert_equals "" "$(stub_egress)" "S3: the stub gets no answer"
assert_equals "0" "$(outside_count)" "S3: no traffic outside the tunnel"
run_verify
assert_equals "5" "$V_RC" "S3: verify exits 5"
assert_equals '["degraded", true]' "$(json_get "$V_DOC" '[d["verdict"], d["clearnet_blocked"]]')" "S3: verify degraded with clearnet_blocked"
ks_since=$(systemctl show -p ActiveEnterTimestampMonotonic --value tunnelsats-killswitch.service)
set +e
R_OUT=$(bash "$TS" restart 2>&1 </dev/null)
R_RC=$?
set -e
if [[ "$R_RC" -ne 0 ]]; then
    printf '%s\n' "$R_OUT" | tail -n 20
fi
assert_equals "0" "$R_RC" "S3: tunnelsats.sh restart brings the tunnel back (exit 0)"
assert_equals "active" "$(systemctl is-active wg-quick@tunnelsatsv2.service || true)" "S3: restart started the tunnel"
assert_equals "$ks_since" "$(systemctl show -p ActiveEnterTimestampMonotonic --value tunnelsats-killswitch.service)" \
    "S3: restart leaves the kill switch unit alone"
wait_handshake || fail "S3: no handshake after the restart"

step "S4 boot-like order with handshakes blocked"
nsx ts-srv nft -f - <<'EOF'
table inet ts_block {
	chain in {
		type filter hook input priority -10; policy accept;
		udp dport 51820 drop
	}
}
EOF
systemctl restart tunnelsats-killswitch.service
systemctl restart lnd.service
systemctl restart wg-quick@tunnelsatsv2.service
wait_stub || true
assert_equals "active" "$(systemctl is-active lnd.service)" "S4: Lightning runs while the server is unreachable"
assert_equals "/tunnelsats.slice/lnd.service" "$(ln_cgroup)" "S4: Lightning runs in the slice"
assert_equals "" "$(stub_egress)" "S4: the stub gets no answer"
assert_equals "0" "$(outside_count)" "S4: no traffic outside the tunnel"
run_verify
assert_equals '["degraded", true]' "$(json_get "$V_DOC" '[d["verdict"], d["clearnet_blocked"]]')" "S4: verify degraded with clearnet_blocked"
nsx ts-srv nft delete table inet ts_block
wait_handshake || fail "S4: no handshake after unblocking"
run_verify
assert_verdict protected "S4: protected again once the server answers"

step "S5 Lightning unit replaced as a package upgrade does"
write_ln_unit "LND stub for the TunnelSats kernel tests (upgraded package)"
systemctl daemon-reload
systemctl restart lnd.service
wait_stub || true
assert_equals "/tunnelsats.slice/lnd.service" "$(ln_cgroup)" "S5: still in the slice after the unit file was replaced"
assert_equals "$SERVER_ADDR" "$(stub_egress)" "S5: egress through the tunnel"
run_verify
assert_verdict protected "S5: verify protected"
printf '%s\n' "$ORIG_LN_UNIT" > "$LN_UNIT_FILE"
systemctl daemon-reload
systemctl restart lnd.service
wait_stub || true

step "S6 a child process of the daemon connects out"
child=$(stub_get "/child-egress?url=${ECHO1}")
assert_equals "$SERVER_ADDR" "$(json_get "$child" 'd["body"]')" "S6: the child's egress equals the server address"
assert_equals "/tunnelsats.slice/lnd.service" "$(json_get "$child" 'd["cgroup"]')" "S6: the child runs in the slice"
if [[ "$(json_get "$child" 'd["pid"] != d["parent"]')" == "true" ]]; then pass "S6: the probe ran in a separate process"; else fail "S6: the probe ran in a separate process"; fi
assert_equals "0" "$(outside_count)" "S6: no traffic outside the tunnel"

step "S11 kill chain removed: verify finds the datagram leaving, before any echo service is asked"
# The verifier is paused, so the removed kill switch table stays removed while verify runs
if pause_verifier; then pass "S11: the verifier is paused"; else fail "S11: the verifier is paused"; fi
nft delete table inet tunnelsats
setup_echo_counter
run_verify
assert_equals "4" "$V_RC" "S11: verify exits 4 without the kill chain"
assert_verdict unsafe "S11: verify verdict unsafe"
assert_equals "fail: a datagram from inside the slice to ${SERVER_ADDR} through ts-under left this host; nothing stopped it" \
    "$(json_get "$V_DOC" '[c["result"] + ": " + c["detail"] for c in d["checks"] if c["id"] == "killswitch_probe"][0]')" \
    "S11: the kill switch probe finds its datagram leaving the host"
assert_equals '["skip", "skip"]' "$(json_get "$V_DOC" '[c["result"] for c in d["checks"] if c["id"] in ("egress_probe", "ipv6_probe")]')" \
    "S11: the echo services and the IPv6 probe are not contacted"
assert_equals "0" "$(echo_count)" "S11: verify never shows the home address to the echo services"
assert_equals "0" "$(outside_count)" "S11: no traffic of the node user outside the tunnel"
# The verifier re-arms the kill switch
systemctl start tunnelsats-verifier.service || true
if nft list table inet tunnelsats >/dev/null 2>&1; then
    pass "S11: the verifier re-armed the kill switch"
else
    fail "S11: the verifier re-armed the kill switch"
fi
systemctl start tunnelsats-verifier.timer
wait_handshake || fail "S11: no handshake after the re-arm"
run_verify
assert_verdict protected "S11: protected again"

step "S12 arming fails: Lightning starts only behind the emergency block"
# The kill switch cannot be armed (nft replaced by /bin/false for the kill switch and the verifier)
# and its table is gone, as after a failed first arm at boot: the Lightning unit requires the kill
# switch unit, which succeeds only because the emergency block holds Lightning's clearnet traffic.
# The verifier is paused until the release, so the kill switch unit is the one that arms the block
# (the state change is logged once, by whoever arms it first).
if pause_verifier; then pass "S12: the verifier is paused"; else fail "S12: the verifier is paused"; fi
for d in tunnelsats-killswitch.service.d tunnelsats-verifier.service.d; do
    mkdir -p "/etc/systemd/system/${d}"
    printf '[Service]\nEnvironment=NFT_BIN=/bin/false\n' > "/etc/systemd/system/${d}/ci-arm-fails.conf"
done
systemctl daemon-reload
systemctl stop lnd.service tunnelsats-killswitch.service
nft delete table inet tunnelsats
systemctl start lnd.service
wait_stub || true
assert_equals "active active" "$(systemctl is-active lnd.service) $(systemctl is-active tunnelsats-killswitch.service)" \
    "S12: Lightning and the kill switch unit run (the emergency block holds)"
assert_contains "$(ip -4 rule show)" "21819:	from all uidrange ${NODE_UID}-${NODE_UID} blackhole" "S12: emergency block armed for the node uid"
if nft list table inet tunnelsats >/dev/null 2>&1; then
    fail "S12: the kill switch table stays absent while arming fails"
else
    pass "S12: the kill switch table stays absent while arming fails"
fi
assert_equals "" "$(stub_egress)" "S12: the stub gets no answer"
assert_equals "" "$(slice_egress)" "S12: the Lightning user gets no answer from the internet"
assert_contains "$(ip -4 rule show)" "21817:	from all to 192.168.0.0/16 uidrange ${NODE_UID}-${NODE_UID} lookup main suppress_prefixlength 0" \
    "S12: the local network exemption is armed with the block"
assert_equals "$LAN_EXPECT" "$(lan_rule_count)" "S12: exactly ${LAN_EXPECT/ / + } local network exemptions while the block is armed"
assert_equals "192.168.77.1" "$(lan_egress)" "S12: the Lightning user still reaches the local network behind the block"
assert_equals "0" "$(outside_count)" "S12: no traffic outside the tunnel"
assert_contains "$(journalctl --no-pager -u tunnelsats-killswitch.service --since '-3 min' 2>/dev/null)" "emergency block armed" \
    "S12: the kill switch unit logged the emergency block"
# verify while only the emergency block holds: the node user's datagram (unbound, as the daemon's
# sockets are) meets the uid blackhole; the kernel checks failed, so no echo service is asked
setup_echo_counter
run_verify
assert_equals "5" "$V_RC" "S12: verify exits 5 while the emergency block holds"
assert_equals '["degraded", true, true, "active"]' "$(json_get "$V_DOC" '[d["verdict"], d["clearnet_blocked"], d["emergency_block"], d["emergency_state"]]')" \
    "S12: verify degraded, clearnet blocked, emergency block active"
assert_equals "pass: a datagram from inside the slice to ${SERVER_ADDR} was stopped on this host (EINVAL)" \
    "$(json_get "$V_DOC" '[c["result"] + ": " + c["detail"] for c in d["checks"] if c["id"] == "killswitch_probe"][0]')" \
    "S12: the uid blackhole stops the node user's datagram (EINVAL)"
assert_equals '["skip", "skip"]' "$(json_get "$V_DOC" '[c["result"] for c in d["checks"] if c["id"] in ("egress_probe", "ipv6_probe")]')" \
    "S12: the echo services and the IPv6 probe are not contacted"
assert_equals "0" "$(echo_count)" "S12: verify never shows the home address to the echo services"
# A rule of another tool before the emergency block (priority 100, lookup 100: the test internet
# table) routes the node's traffic around it: verify must not call that blocked
ip rule add priority 100 lookup 100
run_verify --no-probe
assert_equals "4" "$V_RC" "S12: with a rule before the emergency block, verify --no-probe exits 4"
assert_equals '["unsafe", false, false, "bypassed"]' "$(json_get "$V_DOC" '[d["verdict"], d["clearnet_blocked"], d["emergency_block"], d["emergency_state"]]')" \
    "S12: verify --no-probe: unsafe, not reported as blocked, emergency_state bypassed"
assert_equals "fail: present for uid ${NODE_UID} but not in effect: IPv4 rule before 21818: 100: from all lookup 100" \
    "$(json_get "$V_DOC" '[c["result"] + ": " + c["detail"] for c in d["checks"] if c["id"] == "emergency_block"][0]')" \
    "S12: the emergency_block check names the rule"
setup_echo_counter
run_verify
assert_equals "4" "$V_RC" "S12: with a rule before the emergency block, verify exits 4"
assert_equals "fail: a datagram from inside the slice to ${SERVER_ADDR} left this host; nothing stopped it" \
    "$(json_get "$V_DOC" '[c["result"] + ": " + c["detail"] for c in d["checks"] if c["id"] == "killswitch_probe"][0]')" \
    "S12: the node user's unbound datagram gets around the block"
assert_equals "0" "$(echo_count)" "S12: the echo services are still not contacted"
# A verifier run in this state (it still cannot arm the kill switch) finds that neither protection
# holds: it stops Lightning, reads back that it stopped, and records the unit
systemctl start tunnelsats-verifier.service || true
assert_equals "inactive" "$(systemctl is-active lnd.service || true)" \
    "S12: the verifier stops Lightning while neither the kill switch nor the emergency block holds"
assert_contains "$(journalctl --no-pager -u tunnelsats-verifier.service --since '-3 min' 2>/dev/null)" "lnd.service stopped" \
    "S12: the verifier logged that it stopped Lightning"
assert_equals "lnd.service stopped 0" "$(cat /run/tunnelsats/stopped-units 2>/dev/null)" "S12: and recorded the unit it stopped"
ip rule del priority 100 lookup 100
run_verify --no-probe
assert_equals '["degraded", true, true, "active"]' "$(json_get "$V_DOC" '[d["verdict"], d["clearnet_blocked"], d["emergency_block"], d["emergency_state"]]')" \
    "S12: without that rule the emergency block is in effect again (degraded)"
# The next verifier run finds the block in effect and starts Lightning again, behind the block
systemctl start tunnelsats-verifier.service || true
for _ in $(seq 1 30); do
    if systemctl is-active --quiet lnd.service; then
        break
    fi
    sleep 1
done
assert_equals "active" "$(systemctl is-active lnd.service || true)" "S12: the verifier starts Lightning again once the block holds"
assert_contains "$(journalctl --no-pager -u tunnelsats-verifier.service --since '-3 min' 2>/dev/null)" "starting lnd.service again" \
    "S12: the verifier logged that it starts Lightning again"
# The run after that finds Lightning running, logs it and clears the record
systemctl start tunnelsats-verifier.service || true
assert_contains "$(journalctl --no-pager -u tunnelsats-verifier.service --since '-3 min' 2>/dev/null)" "lnd.service runs again" \
    "S12: the next verifier run confirms that Lightning runs again"
if [[ -e /run/tunnelsats/stopped-units ]]; then
    fail "S12: no record of stopped units remains"
else
    pass "S12: no record of stopped units remains"
fi
wait_stub || true
assert_equals "" "$(slice_egress)" "S12: Lightning, started again, still gets no answer from the internet (the block holds)"
# Arming works again: the resumed verifier re-arms and releases the block
for d in tunnelsats-killswitch.service.d tunnelsats-verifier.service.d; do
    rm -f "/etc/systemd/system/${d}/ci-arm-fails.conf"
    rmdir "/etc/systemd/system/${d}"
done
systemctl daemon-reload
systemctl start tunnelsats-verifier.timer
released_s=$(wait_release)
if [[ "$released_s" =~ ^[0-9]+$ ]]; then
    pass "S12: the verifier re-armed and released the emergency block after ${released_s} s"
else
    fail "S12: the verifier re-armed and released the emergency block (got ${released_s})"
fi
assert_not_contains "$(ip -4 rule show; ip -6 rule show)" "21817:" "S12: the local network exemptions are released with the block"
wait_handshake || fail "S12: no handshake after the re-arm"
assert_equals "$SERVER_ADDR" "$(stub_egress)" "S12: egress through the tunnel again"
assert_equals "0" "$(outside_count)" "S12: no traffic outside the tunnel"
# Leftover emergency rules beside the armed kill switch, as in the middle of a release (only the
# IPv6 blackhole left): verify reports degraded, not unsafe; its kill switch probe runs as root
# through the regular interface, and the echo services are not contacted
if pause_verifier; then pass "S12: the verifier is paused again"; else fail "S12: the verifier is paused again"; fi
if [[ -e /proc/net/if_inet6 ]]; then
    ip -6 rule add uidrange "${NODE_UID}-${NODE_UID}" blackhole priority 21819
    setup_echo_counter
    run_verify
    assert_equals '["degraded", false, "incomplete", "pass", "skip"]' \
        "$(json_get "$V_DOC" '[d["verdict"], d["emergency_block"], d["emergency_state"]] + [c["result"] for c in d["checks"] if c["id"] in ("killswitch_probe", "egress_probe")]')" \
        "S12: with only the IPv6 blackhole left, verify is degraded (incomplete), the kill switch probe passes, no echo probe"
    assert_equals "5" "$V_RC" "S12: and exits 5"
    assert_contains "$(json_get "$V_DOC" '[c["detail"] for c in d["checks"] if c["id"] == "killswitch_probe"][0]')" "through " \
        "S12: the kill switch probe is bound to the regular interface"
    assert_equals "0" "$(echo_count)" "S12: the echo services are not contacted while emergency rules are present"
    ip -6 rule del uidrange "${NODE_UID}-${NODE_UID}" blackhole priority 21819
else
    pass "S12: leftover IPv6 blackhole not checked (this host has no IPv6)"
fi
systemctl start tunnelsats-verifier.timer

step "S13 damaged install record: Lightning starts behind the emergency block"
# The kill switch unit's ExecStart carries the Lightning uid, so a damaged install record still lets
# it arm the emergency block for that uid. The verifier is paused until the record is restored, so
# the start shows what the kill switch unit does on its own.
if pause_verifier; then pass "S13: the verifier is paused"; else fail "S13: the verifier is paused"; fi
assert_contains "$(systemctl show -p ExecStart --value tunnelsats-killswitch.service)" "managed-arm --fallback-uid ${NODE_UID}" \
    "S13: the kill switch unit carries the Lightning uid"
systemctl stop lnd.service tunnelsats-killswitch.service
cp -p /etc/tunnelsats/managed.json "$WORK/managed.json.saved"
echo "not an inventory" > /etc/tunnelsats/managed.json
set +e
systemctl start lnd.service >/dev/null 2>&1
S13_RC=$?
set -e
assert_equals "0" "$S13_RC" "S13: Lightning starts with a damaged install record"
wait_stub || true
assert_equals "active active" "$(systemctl is-active lnd.service || true) $(systemctl is-active tunnelsats-killswitch.service || true)" \
    "S13: Lightning and the kill switch unit run"
assert_contains "$(ip -4 rule show)" "21819:	from all uidrange ${NODE_UID}-${NODE_UID} blackhole" "S13: the emergency block holds for the Lightning uid"
assert_contains "$(journalctl --no-pager -u tunnelsats-killswitch.service --since '-3 min' 2>/dev/null)" "emergency block armed for uid ${NODE_UID}" \
    "S13: the kill switch unit logged why"
assert_equals "" "$(stub_egress)" "S13: the stub gets no answer from the internet"
assert_equals "192.168.77.1" "$(lan_egress)" "S13: the Lightning user reaches the local network"
assert_equals "0" "$(outside_count)" "S13: no traffic outside the tunnel"
systemctl start tunnelsats-verifier.service || true
assert_contains "$(journalctl --no-pager -u tunnelsats-verifier.service --since '-3 min' 2>/dev/null)" "emergency block active for uid ${NODE_UID}" \
    "S13: the verifier logged the damaged record and kept the block"
assert_equals "$LAN_EXPECT" "$(lan_rule_count)" "S13: still exactly ${LAN_EXPECT/ / + } local network exemptions after the verifier armed the block again"
setup_echo_counter
run_verify
assert_equals "5" "$V_RC" "S13: verify exits 5"
assert_equals '["degraded", true, true, "active", "damaged", "install_record_damaged"]' \
    "$(json_get "$V_DOC" '[d["verdict"], d["clearnet_blocked"], d["emergency_block"], d["emergency_state"], d["install_state"], (d["action_required"] or {}).get("reason")]')" \
    "S13: verify degraded and blocked, install record damaged, with the action to take"
assert_equals "0" "$(echo_count)" "S13: verify never shows the home address to the echo services"
# The record restored: the resumed verifier re-arms the kill switch and releases the block
cp -p "$WORK/managed.json.saved" /etc/tunnelsats/managed.json
systemctl start tunnelsats-verifier.timer
released_s=$(wait_release)
if [[ "$released_s" =~ ^[0-9]+$ ]]; then
    pass "S13: the verifier re-armed and released the emergency block after ${released_s} s"
else
    fail "S13: the verifier re-armed and released the emergency block (got ${released_s})"
fi
assert_not_contains "$(ip -4 rule show; ip -6 rule show)" "21817:" "S13: the local network exemptions are released too"
wait_handshake || fail "S13: no handshake after the re-arm"
run_verify
assert_verdict protected "S13: protected again"

step "S8 strict reverse-path filtering"
# systemd's sysctl defaults on Ubuntu set net.ipv4.conf.*.rp_filter=2 on every new interface (udev
# runs systemd-sysctl for it), and the kernel applies the higher of the "all" and the interface
# value. Strict mode therefore needs the tunnel's own value set to 1 after udev processed the
# interface, on every start of the tunnel.
strict_tunnel_rp_filter() {
    udevadm settle --timeout=10 >/dev/null 2>&1 || true
    sysctl -q -w net.ipv4.conf.tunnelsatsv2.rp_filter=1
}
orig_all=$(sysctl -n net.ipv4.conf.all.rp_filter)
orig_default=$(sysctl -n net.ipv4.conf.default.rp_filter)
sysctl -q -w net.ipv4.conf.all.rp_filter=1 net.ipv4.conf.default.rp_filter=1
systemctl restart wg-quick@tunnelsatsv2.service
strict_tunnel_rp_filter
wait_handshake || fail "S8: no handshake with strict rp_filter"
assert_equals "1 1" "$(sysctl -n net.ipv4.conf.all.rp_filter) $(sysctl -n net.ipv4.conf.tunnelsatsv2.rp_filter)" "S8: strict rp_filter is active on the tunnel"
assert_equals "1" "$(sysctl -n net.ipv4.conf.tunnelsatsv2.src_valid_mark)" "S8: src_valid_mark is set on the tunnel only"
assert_equals "$SERVER_ADDR" "$(slice_egress)" "S8: tunneled egress works with strict rp_filter"
assert_equals "TS-STUB-LN" "$(inbound_banner)" "S8: inbound works with strict rp_filter"
sysctl -q -w net.ipv4.conf.tunnelsatsv2.src_valid_mark=0
assert_equals "" "$(slice_egress)" "S8: without src_valid_mark strict rp_filter drops the replies (the setting is what makes it work)"
sysctl -q -w net.ipv4.conf.tunnelsatsv2.src_valid_mark=1
assert_equals "0" "$(outside_count)" "S8: no traffic outside the tunnel"
sysctl -q -w "net.ipv4.conf.all.rp_filter=${orig_all}" "net.ipv4.conf.default.rp_filter=${orig_default}"
systemctl restart wg-quick@tunnelsatsv2.service
wait_handshake || fail "S8: no handshake after restoring rp_filter"

step "S9 uninstall --managed with a clean node config"
uninstall_managed
assert_equals "0" "$U_RC" "S9: uninstall --managed exits 0"
assert_equals '[true, true, [], "clean"]' "$(json_get "$U_DOC" '[d["ok"], d["ln_started"], d["remaining"], d["node_config"]]')" "S9: Lightning started again, nothing left"
assert_equals '["lnd_not_ready", 1]' "$(json_get "$U_DOC" '[d["announce_cleanup"], len(d["warnings"])]')" \
    "S9: the announcement step ran (the stub daemon has no RPC) and names the command in a warning"
assert_equals "active" "$(systemctl is-active lnd.service)" "S9: lnd.service runs"
assert_equals "/system.slice/lnd.service" "$(ln_cgroup)" "S9: lnd.service runs outside the slice again"
snapshot_rules > "$WORK/a1.rules"
snapshot_ruleset > "$WORK/a1.ruleset"
snapshot_etc > "$WORK/a1.etc"
sha256sum "$NODE_CONF" > "$WORK/a1.conf"
assert_same_file "$WORK/b1.rules" "$WORK/a1.rules" "S9: ip rules equal the state before install"
assert_same_file "$WORK/b1.ruleset" "$WORK/a1.ruleset" "S9: nft ruleset equals the state before install"
assert_same_file "$WORK/b1.etc" "$WORK/a1.etc" "S9: /etc (unit files included) equals the state before install"
assert_same_file "$WORK/b1.conf" "$WORK/a1.conf" "S9: node config byte for byte unchanged"
assert_equals "not-found" "$(systemctl show -p LoadState --value tunnelsats-killswitch.service)" "S9: kill switch unit gone"
if [[ ! -e /sys/fs/cgroup/tunnelsats.slice ]] && [[ ! -e /usr/local/sbin/tunnelsats ]] && [[ ! -e /run/tunnelsats ]]; then
    pass "S9: slice cgroup, script copy and runtime state gone"
else
    fail "S9: slice cgroup, script copy and runtime state gone"
fi

# ---------------------------------------------------------------------------
# Cycle 2: S7 without the uid backstop, then S9 with TunnelSats settings in the node config
# ---------------------------------------------------------------------------
step "S7 nft flush ruleset without the uid backstop"
# Cycle 2 starts from a running Lightning unit, whatever S9 left behind (S9 asserts its own outcome)
if ! systemctl is-active --quiet lnd.service; then
    echo "INFO: lnd.service is not running after cycle 1; starting it for cycle 2"
    systemctl start lnd.service
    wait_stub || true
fi
snapshot_rules > "$WORK/b2.rules"
snapshot_etc > "$WORK/b2.etc"
install_managed
assert_equals "0" "$I_RC" "S7: install exits 0"
assert_equals "true" "$(json_get "$I_DOC" 'd["ln_restarted"]')" "S7: Lightning restarted inside the slice"
wait_handshake || fail "S7: no handshake"
start_gossip "S7"
sleep 3
setup_arrival_counter
nft flush ruleset
rearm_s=$(wait_rearm)
gap_arrivals=$(arrival_count)
gossip=$(stub_get "/gossip/stop")
if [[ "$rearm_s" =~ ^[0-9]+$ ]] && [[ "$rearm_s" -le 35 ]]; then
    pass "S7: the verifier re-armed the kill switch after ${rearm_s} s (limit 35 s)"
else
    fail "S7: the verifier re-armed the kill switch within 35 s (got ${rearm_s})"
fi
assert_gossip_ran "S7" "$gossip"
echo "INFO: S7 without --uid-backstop: ${gap_arrivals} packet(s) from the home address reached the peer during the ${rearm_s} s gap (expected window, documented); loop: $gossip"
assert_contains "$(journalctl --no-pager -u tunnelsats-verifier.service --since '-3 min' 2>/dev/null)" "re-armed and verified" "S7: the verifier logged the re-arm"
setup_outside_counter
run_verify
assert_verdict protected "S7: protected after the re-arm"

step "S9 uninstall --managed with TunnelSats settings in the node config"
write_node_conf hybrid
uninstall_managed
assert_equals "0" "$U_RC" "S9: uninstall exits 0"
assert_equals '[false, "clearnet"]' "$(json_get "$U_DOC" '[d["ln_started"], d["node_config"]]')" "S9: Lightning stays stopped"
assert_contains "$(json_get "$U_DOC" 'd["action_required"]["lines"]')" "externalhosts=${SERVER_ADDR}:${VPN_PORT}" "S9: the lines to remove are reported"
assert_equals "inactive" "$(systemctl is-active lnd.service || true)" "S9: lnd.service is stopped"
snapshot_rules > "$WORK/a2.rules"
snapshot_etc > "$WORK/a2.etc"
assert_same_file "$WORK/b2.rules" "$WORK/a2.rules" "S9: ip rules equal the state before install (cycle 2)"
assert_same_file "$WORK/b2.etc" "$WORK/a2.etc" "S9: /etc equals the state before install (cycle 2)"
write_node_conf clean
systemctl start lnd.service
wait_stub || true

# ---------------------------------------------------------------------------
# Cycle 3: S7 with the uid backstop
# ---------------------------------------------------------------------------
step "S7 nft flush ruleset with --uid-backstop"
install_managed --uid-backstop
assert_equals "0" "$I_RC" "S7: install --uid-backstop exits 0"
assert_contains "$(ip -4 rule show)" "21822:	from all uidrange ${NODE_UID}-${NODE_UID} lookup 51820" "S7: uid backstop rule present"
wait_handshake || fail "S7: no handshake (backstop)"
run_verify
assert_verdict protected "S7: protected with the uid backstop"
start_gossip "S7 (backstop)"
sleep 3
setup_arrival_counter
nft flush ruleset
rearm_s=$(wait_rearm)
gap_arrivals=$(arrival_count)
gossip=$(stub_get "/gossip/stop")
if [[ "$rearm_s" =~ ^[0-9]+$ ]] && [[ "$rearm_s" -le 35 ]]; then
    pass "S7: the verifier re-armed the kill switch after ${rearm_s} s with the backstop (limit 35 s)"
else
    fail "S7: the verifier re-armed the kill switch within 35 s with the backstop (got ${rearm_s})"
fi
assert_gossip_ran "S7 (backstop)" "$gossip"
assert_equals "0" "$gap_arrivals" "S7: with --uid-backstop no packet from the home address reached the peer during the gap"
echo "INFO: gossip loop during S7 with the backstop: $gossip"
uninstall_managed
assert_equals "0" "$U_RC" "S7: uninstall after the backstop cycle exits 0"

# ---------------------------------------------------------------------------
# Cycle 4: Standard (unmanaged) install IPv6 & boot failure scenarios (#236)
# ---------------------------------------------------------------------------
step "S14 standard (unmanaged) install: scoped IPv6 drop, verify probe, and fail-closed boot/refusal (#236)"
if ! systemctl is-active --quiet lnd.service; then
    systemctl start lnd.service
    wait_stub || true
fi
stub_egress6() {
    json_get "$(stub_get "/egress?url=http://[2001:db8:113::10]/")" 'd.get("body", "")'
}
root_egress6() {
    curl -s -6 --connect-timeout 4 --max-time 6 "http://[2001:db8:113::10]/" 2>/dev/null | tr -d '[:space:]' || true
}
assert_equals "2001:db8:1::1" "$(stub_egress6)" "S14: before standard install the stub reaches IPv6 peers with the home IPv6 address"
reset_outside_counter
grep -v '^DNS' "$WORK/tunnelsats_ci-test.conf" > "$WORK/tunnelsats_std.conf"
bash -c '
    source "$1"
    PLATFORM="baremetal"
    LN_IMPL="lnd"
    WG_INTERFACE="tunnelsatsv2"
    CONFIG_FILE="$2"
    node_user="$3"
    write_route_guard_script
    configure_wireguard
    setup_cgroups
' _ "$TS" "$WORK/tunnelsats_std.conf" "$NODE_USER" >/dev/null
systemctl daemon-reload
systemctl start wg-quick@tunnelsatsv2.service
wait_handshake || fail "S14: no handshake on standard install"
# Simulate a NetworkManager reconnect re-enabling IPv6 on the home interface while the tunnel is up
sysctl -q -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 net.ipv6.conf.ts-home.disable_ipv6=0
assert_equals "2001:db8:1::1" "$(root_egress6)" "S14: root outside the node user keeps native IPv6"
assert_equals "" "$(stub_egress6)" "S14: the Lightning stub cannot reach IPv6 peers even with host IPv6 enabled"
assert_equals "0" "$(outside_count)" "S14: zero packets from the Lightning user left through ts-home"
run_verify
assert_equals "9" "$V_RC" "S14: verify on a protected standard install exits 9 (unmanaged)"
assert_equals '["unmanaged", ["wg_handshake:pass", "legacy_killswitch:pass", "ipv6_probe:pass"]]' \
    "$(json_get "$V_DOC" '[d["verdict"], [c["id"] + ":" + c["result"] for c in d["checks"]]]')" \
    "S14: verify reports unmanaged with ipv6_probe:pass"
# Remove the standard install's inet IPv6 table and verify that verify detects the open IPv6 path
nft delete table inet tunnelsatsv2
run_verify
assert_equals "4" "$V_RC" "S14: verify exits 4 (unsafe) when standard install IPv6 drop is missing"
assert_equals '["unsafe", ["E_IPV6_PROBE"], ["ipv6_probe:fail"]]' \
    "$(json_get "$V_DOC" '[d["verdict"], [e["code"] for e in d["errors"]], [c["id"] + ":" + c["result"] for c in d["checks"] if c["id"] == "ipv6_probe"]]')" \
    "S14: verify reports unsafe and E_IPV6_PROBE when IPv6 datagram leaves the host"
assert_contains "$(json_get "$V_DOC" '[c["detail"] for c in d["checks"] if c["id"] == "ipv6_probe"][0]')" \
    "left this host; nothing stopped it" \
    "S14: verify ipv6_probe detail confirms the datagram left the host"
reset_outside_counter
# Refused tunnel start at boot (foreign route in table 51820): emergency block covers both IPv4 and IPv6
systemctl stop wg-quick@tunnelsatsv2.service
ip route add 10.20.0.0/16 dev ts-lan table 51820
set +e
systemctl start wg-quick@tunnelsatsv2.service >/dev/null 2>&1
set -e
assert_contains "$(nft list table inet tunnelsats_failclosed 2>/dev/null)" "meta skuid ${NODE_UID}" \
    "S14: refused start arms table inet tunnelsats_failclosed for the node uid"
assert_equals "" "$(stub_egress)" "S14: IPv4 egress from the stub is blocked after refused tunnel start"
assert_equals "" "$(stub_egress6)" "S14: IPv6 egress from the stub is blocked after refused tunnel start"
assert_equals "0" "$(outside_count)" "S14: zero IPv4 or IPv6 packets left through ts-home after refused start"
ip route del 10.20.0.0/16 dev ts-lan table 51820
# Pre-hook boot failure (e.g. endpoint DNS failure before PreUp): tunnelsats-create-cgroup.sh arms the block
nft delete table inet tunnelsats_failclosed >/dev/null 2>&1 || true
/etc/wireguard/tunnelsats-create-cgroup.sh >/dev/null 2>&1
assert_contains "$(nft list table inet tunnelsats_failclosed 2>/dev/null)" "meta skuid ${NODE_UID}" \
    "S14: tunnelsats-create-cgroup.sh arms table inet tunnelsats_failclosed when tunnel is down at boot"
assert_equals "" "$(stub_egress6)" "S14: IPv6 egress from the stub is blocked when tunnel fails before PreUp"
# Routing-policy blackhole fallback covers both IPv4 and IPv6 when nft is unavailable
nft delete table inet tunnelsats_failclosed >/dev/null 2>&1 || true
bash -c 'source "$1"; ts_arm_failclosed_rules 10.9.9.0/25 "$2"' _ "$TS" "$NODE_UID"
assert_contains "$(ip -6 rule show)" "21819:	from all uidrange ${NODE_UID}-${NODE_UID} blackhole" \
    "S14: routing-policy fallback adds IPv6 uidrange blackhole at priority 21819"
assert_equals "" "$(stub_egress)" "S14: IPv4 egress blocked by routing-policy fallback"
assert_equals "" "$(stub_egress6)" "S14: IPv6 egress blocked by routing-policy fallback"
assert_equals "0" "$(outside_count)" "S14: zero packets left through ts-home under routing-policy fallback"
TS_M_ANNOUNCE_WAIT=0 bash "$TS" uninstall --managed --legacy-artifacts --yes --non-interactive >/dev/null 2>&1 || true

echo ""
echo "Passed: $pass_count"
echo "Failed: $fail_count"
if [[ "$fail_count" -ne 0 ]]; then
    exit 1
fi
