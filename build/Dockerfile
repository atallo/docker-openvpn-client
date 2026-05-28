FROM alpine:3.23

RUN apk add --no-cache \
              bash \
              bind-tools \
              nftables \
              openvpn \
              python3 \
              socat \
              tzdata \
              curl \
    && rm -f  /usr/sbin/sendmail \
              /usr/bin/nc

COPY . /usr/local/bin

RUN chmod +x /usr/local/bin/*.sh /usr/local/bin/*.py

ENV KILL_SWITCH=on

ENTRYPOINT [ "entry.sh" ]
