FROM ubuntu:22.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        acl \
        cron \
        gzip \
        iproute2 \
        mawk \
        openssh-server \
        procps \
        sudo \
        ufw \
        zlib1g
