#!/usr/bin/env bash

# Userspace port forwarding with socat. For each entry in PORT_FORWARDS it starts
# a socat process that listens on a port inside the container and relays to a host
# that lives behind the VPN. This needs no netfilter, no DNAT/masquerade and no
# ip_forward, so it works in any environment (including unprivileged LXC and other
# runtimes where the kernel does not expose nf_tables to the container).
#
# Called from entry.sh. PORT_FORWARDS is read from the environment, format:
#   <proto>:<listen_port>:<dest_ip>[:<dest_port>]   (proto = tcp | udp | both)
# Multiple entries separated by spaces or commas. dest_port defaults to listen_port.
# Example: PORT_FORWARDS="both:3389:192.168.0.10"

set -o errexit
set -o nounset
set -o pipefail

PORT_FORWARDS="${PORT_FORWARDS:-}"

if [[ -z "$PORT_FORWARDS" ]]; then
    echo "portforward: PORT_FORWARDS is empty, nothing to do"
    exit 0
fi

for entry in ${PORT_FORWARDS//,/ }; do
    IFS=':' read -r proto lport dip dport <<< "$entry"

    if [[ -z "${proto:-}" || -z "${lport:-}" || -z "${dip:-}" ]]; then
        echo "portforward: invalid entry '$entry' (expected proto:listen_port:dest_ip[:dest_port])" >&2
        exit 1
    fi
    dport="${dport:-$lport}"

    case "$proto" in
        tcp|udp)      protos="$proto" ;;
        both|tcp+udp) protos="tcp udp" ;;
        *) echo "portforward: invalid protocol '$proto' in '$entry'" >&2; exit 1 ;;
    esac

    for p in $protos; do
        case "$p" in
            tcp) listen="TCP4-LISTEN:$lport,fork,reuseaddr"; target="TCP4:$dip:$dport" ;;
            udp) listen="UDP4-LISTEN:$lport,fork,reuseaddr"; target="UDP4:$dip:$dport" ;;
        esac
        echo "portforward: $p :$lport -> $dip:$dport (socat)"
        socat "$listen" "$target" &
    done
done
