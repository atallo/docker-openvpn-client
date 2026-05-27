#!/usr/bin/env bash

# Sets up port forwarding into the VPN using nftables (the modern nft command).
# Intended to be called from the OpenVPN config via an "up" directive, e.g.:
#
#     script-security 2
#     up /usr/local/bin/portforward.sh
#
# It can also be run standalone inside the container.
#
# Configuration comes from the PORT_FORWARDS environment variable, so it can be
# set entirely from docker-compose. Format: whitespace- or comma-separated
# entries, each:
#
#     <proto>:<listen_port>:<dest_ip>[:<dest_port>]
#
#   proto      tcp | udp | both   (both = tcp and udp)
#   dest_port  optional; defaults to listen_port
#
# Examples:
#     PORT_FORWARDS="both:3389:10.160.150.220"
#     PORT_FORWARDS="tcp:443:10.0.0.5:8443 udp:53:10.0.0.5"
#
# Requires net.ipv4.ip_forward=1 (set it via the compose `sysctls:` key).

set -o errexit
set -o nounset
set -o pipefail

PORT_FORWARDS="${PORT_FORWARDS:-}"

if [[ -z "$PORT_FORWARDS" ]]; then
    echo "portforward: PORT_FORWARDS is empty, nothing to do"
    exit 0
fi

# Outbound interface towards the VPN. OpenVPN exports $dev to up scripts
# (e.g. tun0); VPN_INTERFACE lets you override it explicitly if needed.
vpn_if="${VPN_INTERFACE:-${dev:-tun0}}"

# Create our own NAT table/chains (idempotent) and start from a clean slate so
# re-running on reconnect doesn't pile up duplicate rules.
nft add table ip nat 2> /dev/null || true
nft add chain ip nat prerouting  '{ type nat hook prerouting  priority dstnat; policy accept; }' 2> /dev/null || true
nft add chain ip nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2> /dev/null || true
nft flush chain ip nat prerouting
nft flush chain ip nat postrouting

# Normalize commas to spaces and process each forward.
for entry in ${PORT_FORWARDS//,/ }; do
    IFS=':' read -r proto lport dip dport <<< "$entry"

    if [[ -z "${proto:-}" || -z "${lport:-}" || -z "${dip:-}" ]]; then
        echo "portforward: invalid entry '$entry' (expected proto:listen_port:dest_ip[:dest_port])" >&2
        exit 1
    fi
    dport="${dport:-$lport}"

    case "$proto" in
        tcp|udp)     protos="$proto" ;;
        both|tcp+udp) protos="tcp udp" ;;
        *) echo "portforward: invalid protocol '$proto' in '$entry'" >&2; exit 1 ;;
    esac

    for p in $protos; do
        echo "portforward: $p :$lport -> $dip:$dport"
        nft add rule ip nat prerouting "$p" dport "$lport" dnat to "$dip:$dport"
    done
done

# Masquerade traffic leaving through the VPN interface so replies from the
# destination come back through this container.
nft add rule ip nat postrouting oifname "$vpn_if" masquerade

echo "portforward: done (vpn interface: $vpn_if)"
