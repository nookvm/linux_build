# Native linux/arm64 builder for the NookVM guest kernel and initramfs.
# Base image and apt archive are both pinned (see versions.env).
ARG BUILDER_BASE_IMAGE
FROM ${BUILDER_BASE_IMAGE}

ARG DEBIAN_SNAPSHOT
RUN set -eux; \
    test -n "${DEBIAN_SNAPSHOT}"; \
    rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*; \
    printf '%s\n' \
      'Types: deb' \
      "URIs: http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}" \
      'Suites: trixie trixie-updates' \
      'Components: main' \
      'Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp' \
      '' \
      'Types: deb' \
      "URIs: http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}" \
      'Suites: trixie-security' \
      'Components: main' \
      'Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp' \
      > /etc/apt/sources.list.d/debian.sources; \
    apt-get -o Acquire::Check-Valid-Until=false update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bc binutils bison ca-certificates cpio curl file flex gcc git gnupg \
      gzip libc6-dev libelf-dev libssl-dev make python3 xz-utils; \
    rm -rf /var/lib/apt/lists/*

ENV LC_ALL=C.UTF-8 TZ=UTC
