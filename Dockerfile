FROM ubuntu:22.04

# Install tools only; configure accounts and the app through setup.sh.
# Prevent services from starting during the build and generate SSH keys at runtime.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash coreutils findutils grep mawk util-linux procps iproute2 \
        libc6 zlib1g file gzip \
        openssh-server openssh-client ufw acl cron sudo passwd netcat-openbsd \
    && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_*
