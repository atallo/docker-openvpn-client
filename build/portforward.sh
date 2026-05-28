#!/usr/bin/env bash

# Userspace port forwarding with socat. For each entry in PORT_FORWARDS it starts
# a socat process that listens on a port inside the container and relays to a host
# behind the VPN. No netfilter, no DNAT/masquerade, no ip_forward, so it works in
# any environment (including unprivileged LXC).
#
# Called from entry.sh once the tunnel is up. PORT_FORWARDS format:
#   <proto>:<listen_port>:<dest>[:<dest_port>]   (proto = tcp | udp | both)
# <dest> may be an IP address or a hostname. Multiple entries separated by spaces
# or commas. dest_port defaults to listen_port.
# Example: PORT_FORWARDS="both:3389:server.internal"
#
# If PORT_FORWARDS_DNS is set, hostnames are resolved against that DNS server
# (useful for names that only the VPN's DNS knows). Otherwise the default
# resolver is used.

set -o errexit
set -o nounset
set -o pipefail

PORT_FORWARDS="${PORT_FORWARDS:-}"

if [[ -z "$PORT_FORWARDS" ]]; then
    echo "portforward: PORT_FORWARDS is empty, nothing to do"
    exit 0
fi

resolve_host() {
    local host=$1
    # Already an IPv4 literal?
    if [[ $host =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$host"
        return 0
    fi
    local server=()
    [[ ${PORT_FORWARDS_DNS:-} ]] && server=("@${PORT_FORWARDS_DNS}")
    local ip=""
    # Retry: the VPN's DNS may take a moment to become reachable.
    for _ in 1 2 3 4 5; do
        ip=$(dig +short +time=2 +tries=1 "${server[@]}" "$host" 2> /dev/null \
                | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
        [[ $ip ]] && break
        sleep 1
    done
    echo "$ip"
}

for entry in ${PORT_FORWARDS//,/ }; do
    IFS=':' read -r proto lport dest dport <<< "$entry"

    if [[ -z "${proto:-}" || -z "${lport:-}" || -z "${dest:-}" ]]; then
        echo "portforward: invalid entry '$entry' (expected proto:listen_port:dest[:dest_port])" >&2
        exit 1
    fi
    dport="${dport:-$lport}"

    case "$proto" in
        tcp|udp)      protos="$proto" ;;
        both|tcp+udp) protos="tcp udp" ;;
        *) echo "portforward: invalid protocol '$proto' in '$entry'" >&2; exit 1 ;;
    esac

    dip=$(resolve_host "$dest")
    if [[ -z "$dip" ]]; then
        echo "portforward: could not resolve '$dest', skipping '$entry'" >&2
        continue
    fi
    [[ "$dip" != "$dest" ]] && echo "portforward: resolved $dest -> $dip"

    for p in $protos; do
        case "$p" in
            tcp) listen="TCP4-LISTEN:$lport,fork,reuseaddr"; target="TCP4:$dip:$dport" ;;
            udp) listen="UDP4-LISTEN:$lport,fork,reuseaddr"; target="UDP4:$dip:$dport" ;;
        esac
        echo "portforward: $p :$lport -> $dip:$dport (socat)"
        socat "$listen" "$target" &
    done
done
