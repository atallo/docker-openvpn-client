#!/usr/bin/env bash

# Kill switch implemented with nftables (native nft, no iptables/legacy).
# Invoked by OpenVPN via --route-up, with ALLOWED_SUBNETS passed as $1.
# OpenVPN exports $dev (the tunnel interface) and $config (first --config file).

set -o errexit
set -o nounset
set -o pipefail

allowed_subnets="${1:-}"
vpn_if="${dev:?kill switch: \$dev not set by OpenVPN}"

# Local network on eth0 (e.g. 192.168.0.0/24) and the default gateway.
eth0_cidr=$(ip -4 -oneline addr show dev eth0 | awk 'NR == 1 { print $4 }')
default_gateway=$(ip -4 route | awk '$1 == "default" { print $3 }')

# Recreate our table from scratch so re-runs (reconnects) stay idempotent.
nft delete table inet killswitch 2> /dev/null || true
nft add table inet killswitch
nft add chain inet killswitch output '{ type filter hook output priority 0; policy drop; }'

# Always allow loopback and anything leaving through the VPN tunnel.
nft add rule inet killswitch output oifname "lo" accept
nft add rule inet killswitch output oifname "$vpn_if" accept
# Allow the local network so the container stays reachable and can reach the
# gateway (needed to establish the tunnel and to return forwarded traffic).
nft add rule inet killswitch output ip daddr "$eth0_cidr" accept

# Create static routes for any ALLOWED_SUBNETS and allow them out.
for subnet in ${allowed_subnets//,/ }; do
    ip route add "$subnet" via "$default_gateway" 2> /dev/null || true
    nft add rule inet killswitch output ip daddr "$subnet" accept
done

# Punch holes for the OpenVPN server addresses so (re)connections can be made.
global_port=$(awk '$1 == "port" { print $2 }' "$config")
global_protocol=$(awk '$1 == "proto" { print $2 }' "$config")
remotes=$(awk '$1 == "remote" { print $2, $3, $4 }' "$config")
ip_regex='^(([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))\.){3}([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))$'
while IFS= read -r line; do
    [[ $line ]] || continue
    # Strip inline comments (fixes upstream #84).
    IFS=" " read -ra remote <<< "${line%%\#*}"
    address=${remote[0]:-}
    [[ $address ]] || continue
    port=${remote[1]:-${global_port:-1194}}
    protocol=${remote[2]:-${global_protocol:-udp}}

    if [[ $address =~ $ip_regex ]]; then
        nft add rule inet killswitch output ip daddr "$address" "$protocol" dport "$port" accept
    else
        for ip in $(dig -4 +short "$address"); do
            nft add rule inet killswitch output ip daddr "$ip" "$protocol" dport "$port" accept
            echo "$ip $address" >> /etc/hosts
        done
    fi
done <<< "$remotes"
