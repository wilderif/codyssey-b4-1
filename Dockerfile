# Keep this package-only image reusable for the next assignment.
FROM ubuntu:22.04
# Prevent package installation from starting services during the build.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       bash coreutils findutils grep sed mawk util-linux procps iproute2 \
       file binutils libc6 zlib1g openssh-server openssh-client ufw acl cron \
       sudo passwd gzip netcat-openbsd ca-certificates \
    && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_*
