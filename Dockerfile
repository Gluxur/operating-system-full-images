# HAOS Full Image Builder
# Container with all required tools for building pre-loaded HAOS images

FROM debian:trixie-slim

# Install base packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    coreutils \
    curl \
    e2fsprogs \
    fdisk \
    git \
    gnupg \
    jq \
    make \
    openssl \
    p7zip-full \
    pigz \
    procps \
    qemu-utils \
    rsync \
    skopeo \
    util-linux \
    xz-utils \
    yq \
    zip \
    && rm -rf /var/lib/apt/lists/*

# Build genimage from source
ARG GENIMAGE_VERSION=19
RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf automake libtool pkg-config libconfuse-dev \
    && curl -fsSL https://github.com/pengutronix/genimage/releases/download/v${GENIMAGE_VERSION}/genimage-${GENIMAGE_VERSION}.tar.xz \
       | tar -xJ -C /tmp \
    && cd /tmp/genimage-${GENIMAGE_VERSION} \
    && ./configure --prefix=/usr \
    && make -j"$(nproc)" \
    && make install \
    && cd / && rm -rf /tmp/genimage-${GENIMAGE_VERSION} \
    && apt-get purge -y autoconf automake libtool pkg-config \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Install Docker from official repository
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io \
    && rm -rf /var/lib/apt/lists/*

# Pre-fetch Docker-in-Docker image as OCI archive
ARG DIND_IMAGE=docker:dind
RUN mkdir -p /opt/haos-builder && \
    skopeo copy "docker://${DIND_IMAGE}" "oci-archive:/opt/haos-builder/dind.oci.tar" && \
    echo "${DIND_IMAGE}" > /opt/haos-builder/dind.image

# Create work directories
RUN mkdir -p /work /input /output /cache /config

# Copy scripts and config
COPY scripts/ /opt/haos-builder/scripts/
COPY genimage/ /opt/haos-builder/genimage/
COPY build.mk /opt/haos-builder/Makefile

WORKDIR /opt/haos-builder

ENTRYPOINT ["/opt/haos-builder/scripts/entry.sh"]
CMD ["help"]
