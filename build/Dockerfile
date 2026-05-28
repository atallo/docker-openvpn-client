FROM alpine:3.23

RUN apk add --no-cache \
              bash \
              bind-tools \
              iproute2 \
              nftables \
              oath-toolkit-oathtool \
              openvpn \
              socat \
              tzdata \
              curl \
    && rm -f  /usr/sbin/sendmail \
              /usr/bin/nc

COPY . /usr/local/bin

RUN chmod +x /usr/local/bin/*.sh

ENV KILL_SWITCH=off

ENTRYPOINT [ "entry.sh" ]

LABEL org.opencontainers.image.description="OpenVPN client container that routes Docker traffic through a VPN tunnel, enabling secure networking for other containers with leak protection (kill switch)."
LABEL org.opencontainers.image.source=https://github.com/atallo/docker-openvpn-client
LABEL org.opencontainers.image.licenses=MIT