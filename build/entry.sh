#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

cleanup() {
    kill -TERM "$openvpn_pid" 2> /dev/null || true
    exit 0
}

is_enabled() {
    [[ ${1,,} =~ ^(true|t|yes|y|1|on|enable|enabled)$ ]]
}

# --- Locate the OpenVPN config (CONFIG_FILE is mandatory) ------------------
if [[ -z ${CONFIG_FILE:-} ]]; then
    echo "error: CONFIG_FILE is required but is not set; cannot start" >&2
    exit 1
fi

config_file=$(find /config -name "$CONFIG_FILE" 2> /dev/null | sort | head -n 1)
if [[ -z $config_file ]]; then
    echo "error: no OpenVPN configuration file matching '$CONFIG_FILE' found in /config" >&2
    exit 1
fi
echo "using openvpn configuration file: $config_file"

if [[ ${TZ:-} ]]; then
    cp "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
fi

# --- VPN credentials -------------------------------------------------------
# From environment (AUTH_USERNAME / AUTH_PASSWORD) or a Docker secret
# (AUTH_SECRET: first line username, second line password). When AUTH_TOTP_KEY
# is set, the current TOTP code is appended to the password (computed with
# oathtool: base32 key, SHA1, 6 digits, 30s).
auth_user=""
auth_pass=""
if [[ ${AUTH_USERNAME:-} ]]; then
    auth_user=$AUTH_USERNAME
    auth_pass=${AUTH_PASSWORD:-}
elif [[ ${AUTH_SECRET:-} ]]; then
    auth_user=$(head -n 1 "/run/secrets/$AUTH_SECRET" | tr -d '\r\n')
    auth_pass=$(tail -n 1 "/run/secrets/$AUTH_SECRET" | tr -d '\r\n')
fi

credentials_file=""
if [[ $auth_user ]]; then
    if [[ ${AUTH_TOTP_KEY:-} ]]; then
        totp_key="${AUTH_TOTP_KEY//[[:space:]]/}"
        totp=$(oathtool --totp -b "${totp_key^^}")
        echo "using totp code: $totp"
        auth_pass="${auth_pass}${totp}"
    fi
    credentials_file=/tmp/openvpn-credentials
    ( umask 077; printf '%s\n%s\n' "$auth_user" "$auth_pass" > "$credentials_file" )
fi

# --- Sanitized config copy -------------------------------------------------
# The container's behaviour must be determined by these settings, not by
# whatever the .ovpn happens to contain. OpenVPN runs on a copy of the config
# with the directives we manage stripped out: the script hooks (we add our own
# on the command line) and, when we supply credentials, auth-user-pass.
strip='up|down|route-up|script-security'
if [[ $credentials_file ]]; then
    strip="$strip|auth-user-pass"
fi
sanitized_config=/tmp/openvpn.conf
{ grep -viE "^[[:space:]]*(${strip})([[:space:]]|\$)" "$config_file" || true; } > "$sanitized_config"

# Override the address in every "remote" line when REMOTE_IP is set.
if [[ ${REMOTE_IP:-} ]]; then
    sed -i -E "s/^([[:space:]]*remote[[:space:]]+)[^[:space:]]+/\1${REMOTE_IP}/" "$sanitized_config"
    echo "overriding remote address with: $REMOTE_IP"
fi

openvpn_args=(
    "--config" "$sanitized_config"
    "--cd" "/config"
)

if [[ $credentials_file ]]; then
    openvpn_args+=("--auth-user-pass" "$credentials_file")
fi

# The kill switch is a user script invoked via --route-up, which needs
# script-security 2; we add it here so it works regardless of the config. It
# uses nftables and therefore needs a host that exposes netfilter to the
# container; KILL_SWITCH defaults to off.
if is_enabled "${KILL_SWITCH:-off}"; then
    openvpn_args+=(
        "--script-security" "2"
        "--route-up" "/usr/local/bin/killswitch.sh ${ALLOWED_SUBNETS:-}"
    )
fi

openvpn "${openvpn_args[@]}" &
openvpn_pid=$!

trap cleanup TERM

# --- Once the tunnel is up -------------------------------------------------
# Wait for the VPN interface, then start port forwarding (so hostnames can be
# resolved through the VPN) and run the post-up command.
if [[ ${PORT_FORWARDS:-} || ${POST_UP_COMMAND:-} ]]; then
    {
        tunnel_up=false
        for _ in $(seq 1 120); do
            if ip -4 -oneline addr show 2> /dev/null | grep -qE '[[:space:]]tun[0-9]'; then
                tunnel_up=true
                break
            fi
            sleep 1
        done

        if ! $tunnel_up; then
            echo "warning: VPN tunnel did not come up within timeout; skipping port forwarding and post-up command" >&2
        else
            if [[ ${PORT_FORWARDS:-} ]]; then
                /usr/local/bin/portforward.sh || echo "warning: port forwarding setup failed" >&2
            fi
            if [[ ${POST_UP_COMMAND:-} ]]; then
                echo "running post-up command"
                sh -c "$POST_UP_COMMAND" || echo "warning: post-up command exited with an error" >&2
            fi
        fi
    } &
fi

wait $openvpn_pid
