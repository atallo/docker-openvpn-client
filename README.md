# OpenVPN Client for Docker

Forked from https://github.com/wfg/docker-openvpn-client to meet custom needs.

## What is this and what does it do?
[`ghcr.io/atallo/docker-openvpn-client`](https://github.com/users/atallo/packages/container/package/docker-openvpn-client) is a containerized OpenVPN client.
It has a kill switch built with `nftables` that kills Internet connectivity to the container if the VPN tunnel goes down for any reason. The kill switch needs a host that exposes netfilter to the container; set `KILL_SWITCH=off` on environments that don't (for example, an unprivileged LXC).

This image requires you to supply the necessary OpenVPN configuration file(s).
Because of this, any VPN provider should work.

If you find something that doesn't work or have an idea for a new feature, issues and **pull requests are welcome** (however, I'm not promising they will be merged).

## Why?
Having a containerized VPN client lets you use container networking to easily choose which applications you want using the VPN instead of having to set up split tunnelling.
It also keeps you from having to install an OpenVPN client on the underlying host.

## How do I use it?
### Getting the image
You can either pull it from GitHub Container Registry or build it yourself.

To pull it from GitHub Container Registry, run
```
docker pull ghcr.io/atallo/docker-openvpn-client
```

To build it yourself, run
```
docker build -t ghcr.io/atallo/docker-openvpn-client https://github.com/atallo/docker-openvpn-client.git#:build
```

### Creating and running a container
The image requires the container be created with the `NET_ADMIN` capability and `/dev/net/tun` accessible.
Below are bare-bones examples for `docker run` and Compose; however, you'll probably want to do more than just run the VPN client.
See the below to learn how to have [other containers use `openvpn-client`'s network stack](#using-with-other-containers).

#### `docker run`
```
docker run --detach \
  --name=openvpn-client \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  --volume <path/to/config/dir>:/config \
  ghcr.io/atallo/docker-openvpn-client
```

#### `docker-compose`
```yaml
services:
  openvpn-client:
    image: ghcr.io/atallo/docker-openvpn-client
    container_name: openvpn-client
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    environment:
      - TZ=Europe/Madrid
      - ALLOWED_SUBNETS=192.168.10.0/24
    volumes:
      - <path/to/config/dir>:/config
    restart: unless-stopped
```

#### Environment variables
| Variable | Default (blank is unset) | Description |
| --- | --- | --- |
| `TZ` | | Timezone information. |
| `CONFIG_FILE` | | **Required.** The OpenVPN configuration file (name or glob) to use, searched within `/config`. The container will not start if this is unset or matches no file. |
| `REMOTE_IP` | | If set, overrides the address in every `remote` line of the config (port and protocol are kept). Lets you pin the connection endpoint without editing the `.ovpn`. |
| `ALLOWED_SUBNETS` | | A list of one or more comma-separated subnets (e.g. `192.168.0.0/24,192.168.1.0/24`) to allow outside of the VPN tunnel. |
| `AUTH_USERNAME` | | VPN username for `--auth-user-pass`. Set directly from `docker-compose` as an alternative to `AUTH_SECRET`. |
| `AUTH_PASSWORD` | | VPN password that goes with `AUTH_USERNAME`. If `AUTH_TOTP_KEY` is also set, the current TOTP code is appended automatically. |
| `AUTH_SECRET` | | Docker secret that contains the credentials for accessing the VPN (first line username, second line password). |
| `AUTH_TOTP_KEY` | | TOTP key (base32) used as 2FA. The current code is appended to the password. Computed with `oathtool` (SHA1, 6 digits, 30s). |
| `KILL_SWITCH` | `off` | Whether to enable the kill switch. Set to any "truthy" value[1] to enable. Needs a host that exposes netfilter (nftables) to the container. |
| `PORT_FORWARDS` | | Forward one or more ports into the VPN. Space/comma-separated entries of the form `<proto>:<listen_port>:<dest>[:<dest_port>]` where `proto` is `tcp`, `udp`, or `both`, and `<dest>` is an IP or hostname. See [Port forwarding into the VPN](#port-forwarding-into-the-vpn). |
| `PORT_FORWARDS_DNS` | | DNS server used to resolve hostnames in `PORT_FORWARDS` (e.g. the VPN's own DNS). If unset, the default resolver is used. |
| `POST_UP_COMMAND` | | A command run (via `sh -c`) once the VPN tunnel is up. Can be anything from a simple `curl` to a more complex script. |

[1] "Truthy" values in this context are the following: `true`, `t`, `yes`, `y`, `1`, `on`, `enable`, or `enabled`.

##### Environment variable considerations
###### `ALLOWED_SUBNETS`
If you intend on connecting to containers that use the OpenVPN container's network stack (which you probably do), **you will probably want to use this variable**.
Regardless of whether or not you're using the kill switch, the entrypoint script also adds routes to each of the `ALLOWED_SUBNETS` to allow network connectivity from outside of Docker.

##### `AUTH_SECRET`
Compose has support for [Docker secrets](https://docs.docker.com/engine/swarm/secrets/#use-secrets-in-compose).
See the [Compose file](docker-compose.yml) in this repository for example usage of passing proxy credentials as Docker secrets.

##### Configuration file handling
So that the container behaves the same regardless of what your `.ovpn` contains, the entrypoint runs OpenVPN on a sanitized copy of your configuration file. It always strips the directives it manages itself — `up`, `down`, `route-up`, and `script-security` — and adds its own on the command line where needed (for example for the kill switch). When credentials are provided via `AUTH_USERNAME`/`AUTH_PASSWORD` or `AUTH_SECRET`, any `auth-user-pass` line in the config is stripped too, so the supplied credentials always win. Your original file under `/config` is never modified.

### Port forwarding into the VPN
You can forward one or more ports from the container to a host that lives *behind* the VPN tunnel (for example, reaching an RDP machine on the remote network). This is handled by `portforward.sh` using **userspace `socat` relays**, driven entirely from `docker-compose` through the `PORT_FORWARDS` variable. Because it is plain userspace forwarding, it needs no netfilter, no DNAT/masquerade and no `ip_forward`, so it works in any environment (including unprivileged LXC and other runtimes where the kernel does not expose nf_tables to the container).

Each forward is written as `<proto>:<listen_port>:<dest>[:<dest_port>]`:

- `proto` is `tcp`, `udp`, or `both` (both = tcp and udp).
- `<dest>` is the target behind the VPN: an IP address **or a hostname**.
- `dest_port` is optional and defaults to `listen_port`.
- Multiple forwards are separated by spaces or commas.

For example, to forward TCP+UDP 3389 to a machine at `192.168.0.10` behind the VPN:

```yaml
    environment:
      - PORT_FORWARDS=both:3389:192.168.0.10
    ports:
      - 3389:3389/tcp
      - 3389:3389/udp
```

When `<dest>` is a hostname it is resolved with `dig` after the tunnel is up. If the name is only known to the VPN's own DNS, point `PORT_FORWARDS_DNS` at that server and it will be used for the lookup:

```yaml
    environment:
      - PORT_FORWARDS=both:3389:rdp.internal
      - PORT_FORWARDS_DNS=10.174.123.50
```

Setting `PORT_FORWARDS` is all that is required; the entrypoint starts the relays itself once the tunnel is up, so the `.ovpn` file does not need editing. The only other requirement is that the listen port reaches the container, so publish it with `ports:` (as shown) or connect from a container that shares this network stack.

### Running a command when the VPN is up
Set `POST_UP_COMMAND` to run a command (via `sh -c`) once the tunnel is up — anything from a heartbeat ping to a more involved script. It runs inside the container, so its traffic goes through the VPN:

```yaml
    environment:
      - POST_UP_COMMAND=curl -fsS https://example.com/notify
```

### Using with other containers
Once you have your `openvpn-client` container up and running, you can tell other containers to use `openvpn-client`'s network stack which gives them the ability to utilize the VPN tunnel.
There are a few ways to accomplish this depending how how your container is created.

If your container is being created with
1. the same Compose YAML file as `openvpn-client`, add `network_mode: service:openvpn-client` to the container's service definition.
2. a different Compose YAML file than `openvpn-client`, add `network_mode: container:openvpn-client` to the container's service definition.
3. `docker run`, add `--network=container:openvpn-client` as an option to `docker run`.

Once running and provided your container has `wget` or `curl`, you can run `docker exec <container_name> wget -qO - ifconfig.me` or `docker exec <container_name> curl -s ifconfig.me` to get the public IP of the container and make sure everything is working as expected.
This IP should match the one of `openvpn-client`.

#### Handling ports intended for connected containers
If you have a connected container and you need to access a port that container, you'll want to publish that port on the `openvpn-client` container instead of the connected container.
To do that, add `-p <host_port>:<container_port>` if you're using `docker run`, or add the below snippet to the `openvpn-client` service definition in your Compose file if using `docker-compose`.
```yaml
ports:
  - <host_port>:<container_port>
```
In both cases, replace `<host_port>` and `<container_port>` with the port used by your connected container.

### Verifying functionality
Once you have container running `ghcr.io/atallo/docker-openvpn-client`, run the following command to spin up a temporary container using `openvpn-client` for networking.
The `wget -qO - ifconfig.me` bit will return the public IP of the container (and anything else using `openvpn-client` for networking).
You should see an IP address owned by your VPN provider.
```
docker run --rm -it --network=container:openvpn-client alpine wget -qO - ifconfig.me
```

### Using a healthcheck to verify a website is up

Because the image already ships with `curl`, you can use Docker's healthcheck mechanism to periodically check that a website is reachable *through the VPN tunnel*. Docker runs the healthcheck command on a fixed interval and uses its exit code to mark the container as `healthy` or `unhealthy`, so the container's health doubles as an up/down monitor for the target site.

Add a `healthcheck` block to the `openvpn-client` service in your Compose file:

```yaml
    healthcheck:
      # curl fails (non-zero exit) if the site is unreachable or returns an HTTP error,
      # which marks the container unhealthy.
      test: ["CMD", "curl", "-fsS", "https://example.com"]
      interval: 5m       # how often to check
      timeout: 30s       # fail the check if curl takes longer than this
      retries: 3         # consecutive failures before the container is marked unhealthy
      start_period: 30s  # grace period on startup before failures count
```

Replace `https://example.com` with the URL you want to monitor. The `-f` flag makes `curl` return a non-zero exit code on HTTP errors (4xx/5xx), `-sS` keeps it quiet but still prints errors. Because the check runs inside the `openvpn-client` container, the request goes out through the VPN tunnel.

You can see the current status in the `STATUS` column of `docker ps` (it shows `(healthy)` / `(unhealthy)`), or inspect the detailed results, including the last check's output, with:

```
docker inspect --format '{{json .State.Health}}' openvpn-client
```

### Troubleshooting
#### VPN authentication
Your OpenVPN configuration file may not come with authentication baked in. The recommended way to provide credentials is through the environment variables `AUTH_USERNAME` and `AUTH_PASSWORD` (or a Docker secret via `AUTH_SECRET`), set from `docker-compose`. When these are set, the entrypoint supplies them to OpenVPN and ignores any `auth-user-pass` line in your config, so you do not need to edit the configuration file. If your provider requires 2FA, set `AUTH_TOTP_KEY` (base32) as well and the current code is appended to the password.

If you would rather keep credentials in the config the traditional way instead of using the variables above, create a file (for example `credentials.txt`) next to the configuration file with your username on the first line and your password on the second, and reference it from the config with `auth-user-pass credentials.txt`. This is used only when no credential variables are set.
