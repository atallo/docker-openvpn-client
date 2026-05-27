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

# Port forwarding: when PORT_FORWARDS is set, enable IP forwarding and wire
# portforward.sh in as the OpenVPN "up" script automatically. We run OpenVPN on
# a copy of the config with any existing "up"/"script-security" lines stripped,
# so the config never has to be edited by hand (whatever it had for those is
# ignored). OpenVPN resolves relative paths against --cd (/config), so the copy
# can live in /tmp without breaking references to ca/cert/key files.
if [[ ${PORT_FORWARDS:-} ]]; then
    echo 1 > /proc/sys/net/ipv4/ip_forward 2> /dev/null \
        || echo "warning: could not enable net.ipv4.ip_forward; set it via compose sysctls" >&2

    modified_config="/tmp/openvpn-portforward.conf"
    { grep -viE '^[[:space:]]*(up|script-security)([[:space:]]|$)' "$config_file" || true; } > "$modified_config"
    printf '%s\n' "script-security 2" "up /usr/local/bin/portforward.sh" >> "$modified_config"
    config_file=$modified_config
    echo "port forwarding enabled; wired portforward.sh into a modified config copy"
fi

openvpn_args=(
    "--config" "$config_file"
    "--cd" "/config"
)

if is_enabled "$KILL_SWITCH"; then
    openvpn_args+=("--route-up" "/usr/local/bin/killswitch.sh ${ALLOWED_SUBNETS:-}")
fi

# Docker secret that contains the credentials for accessing the VPN.
if [[ ${AUTH_SECRET:-} ]]; then
    
    if [[ "${TOTP_KEY:-}" != "" ]]; then

        # Original user and password
        USER=$( cat /run/secrets/$AUTH_SECRET | head -n 1 | tr -d '\r' | tr -d '\n' )
        PASS=$( cat /run/secrets/$AUTH_SECRET | tail -n 1 | tr -d '\r' | tr -d '\n' )
        
        # New TOTP
        TOTP=$( /usr/local/bin/totp.py $TOTP_KEY )
        echo "using totp code: $TOTP"
        PASSWORD=$PASS$TOTP

        echo $USER > /run/secrets/totp.txt
        echo $PASSWORD >> /run/secrets/totp.txt

        openvpn_args+=("--auth-user-pass" "/run/secrets/totp.txt")

    else
        openvpn_args+=("--auth-user-pass" "/run/secrets/$AUTH_SECRET")
    fi

fi

openvpn "${openvpn_args[@]}" &
openvpn_pid=$!

trap cleanup TERM

wait $openvpn_pid
