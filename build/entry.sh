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
