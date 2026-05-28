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

# --- VPN credentials -------------------------------------------------------
# Credentials for --auth-user-pass come from environment variables
# (VPN_USERNAME / VPN_PASSWORD, set straight from docker-compose) or from a
# Docker secret (AUTH_SECRET: first line username, second line password). When
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

credentials_file=""
if [[ $auth_user ]]; then
    if [[ ${TOTP_KEY:-} ]]; then
        totp=$(/usr/local/bin/totp.py "$TOTP_KEY")
        echo "using totp code: $totp"
        auth_pass="${auth_pass}${totp}"
    fi
    credentials_file=/tmp/openvpn-credentials
    ( umask 077; printf '%s\n%s\n' "$auth_user" "$auth_pass" > "$credentials_file" )
fi

# --- Sanitized config copy -------------------------------------------------
# The container's behaviour must be determined by these settings, not by
# whatever the .ovpn happens to contain. So OpenVPN runs on a copy of the config
# with the directives we manage stripped out: the script hooks (we add our own
# on the command line) and, when we supply credentials, auth-user-pass. This way
# it always works regardless of what the config file says.
strip='up|down|route-up|script-security'
if [[ $credentials_file ]]; then
    strip="$strip|auth-user-pass"
fi
sanitized_config=/tmp/openvpn.conf
{ grep -viE "^[[:space:]]*(${strip})([[:space:]]|\$)" "$config_file" || true; } > "$sanitized_config"

openvpn_args=(
    "--config" "$sanitized_config"
    "--cd" "/config"
)

if [[ $credentials_file ]]; then
    openvpn_args+=("--auth-user-pass" "$credentials_file")
fi

# The kill switch is a user script invoked via --route-up, which requires
# script-security 2; we set it here so it works regardless of the config. The
# kill switch uses nftables and therefore needs a host that exposes netfilter to
# the container; set KILL_SWITCH=off where that is not available.
if is_enabled "${KILL_SWITCH:-off}"; then
    openvpn_args+=(
        "--script-security" "2"
        "--route-up" "/usr/local/bin/killswitch.sh ${ALLOWED_SUBNETS:-}"
    )
fi

# --- Port forwarding (userspace socat, no netfilter / ip_forward needed) ----
if [[ ${PORT_FORWARDS:-} ]]; then
    /usr/local/bin/portforward.sh || echo "warning: port forwarding setup failed" >&2
fi

openvpn "${openvpn_args[@]}" &
openvpn_pid=$!

trap cleanup TERM

wait $openvpn_pid
