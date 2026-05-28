#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

cleanup() {
    kill -TERM "$openvpn_pid"
    exit 0
}

is_enabled() {
    [[ ${1,,} =~ ^(true|t|yes|y|1|on|enable|enabled)$ ]]
}

# Either a specific file name or a pattern.
if [[ ${CONFIG_FILE:-} ]]; then
    config_file=$(find /config -name "$CONFIG_FILE" 2> /dev/null | sort | shuf -n 1)
else
    config_file=$(find /config -name '*.conf' -o -name '*.ovpn' 2> /dev/null | sort | shuf -n 1)
fi

if [[ -z $config_file ]]; then
    echo "no openvpn configuration file found" >&2
    exit 1
fi

echo "using openvpn configuration file: $config_file"

if [[ ${TZ:-} ]]; then
    cp "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
fi

# Port forwarding: when PORT_FORWARDS is set, set up the nftables rules directly
# from here (portforward.sh reads PORT_FORWARDS from the environment). This runs
# before OpenVPN starts; the rules reference the VPN interface by name, so they
# take effect as soon as the tunnel comes up. Doing it here avoids OpenVPN's "up"
# hook, which does not pass our environment variables through to the script.
if [[ ${PORT_FORWARDS:-} ]]; then
    # Best effort: many runtimes mount /proc/sys read-only, in which case this is
    # a no-op and net.ipv4.ip_forward must be set via the compose `sysctls:` key.
    if [[ -w /proc/sys/net/ipv4/ip_forward ]]; then
        echo 1 > /proc/sys/net/ipv4/ip_forward
    fi
    /usr/local/bin/portforward.sh || echo "warning: port forwarding setup failed" >&2
fi

openvpn_args=(
    "--config" "$config_file"
    "--cd" "/config"
)

if is_enabled "$KILL_SWITCH"; then
    openvpn_args+=("--route-up" "/usr/local/bin/killswitch.sh ${ALLOWED_SUBNETS:-}")
fi

# VPN credentials for --auth-user-pass. They can come from environment variables
# (VPN_USERNAME / VPN_PASSWORD, settable straight from docker-compose) or from a
# Docker secret (AUTH_SECRET: first line user, second line password). When
# TOTP_KEY is set, the current TOTP code is appended to the password.
auth_user=""
auth_pass=""
if [[ ${VPN_USERNAME:-} ]]; then
    auth_user=$VPN_USERNAME
    auth_pass=${VPN_PASSWORD:-}
elif [[ ${AUTH_SECRET:-} ]]; then
    auth_user=$(head -n 1 "/run/secrets/$AUTH_SECRET" | tr -d '\r\n')
    auth_pass=$(tail -n 1 "/run/secrets/$AUTH_SECRET" | tr -d '\r\n')
fi

if [[ $auth_user ]]; then
    if [[ ${TOTP_KEY:-} ]]; then
        totp=$(/usr/local/bin/totp.py "$TOTP_KEY")
        echo "using totp code: $totp"
        auth_pass="${auth_pass}${totp}"
    fi
    credentials_file=/tmp/openvpn-credentials
    ( umask 077; printf '%s\n%s\n' "$auth_user" "$auth_pass" > "$credentials_file" )
    openvpn_args+=("--auth-user-pass" "$credentials_file")
fi

openvpn "${openvpn_args[@]}" &
openvpn_pid=$!

trap cleanup TERM

wait $openvpn_pid
