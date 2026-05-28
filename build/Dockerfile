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
