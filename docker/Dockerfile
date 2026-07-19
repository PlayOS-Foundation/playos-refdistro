FROM alpine:3.24.1

ARG ALPINE_BRANCH=v3.24
ENV PLAYOS_ALPINE_BRANCH=${ALPINE_BRANCH}
ENV PLAYOS_APORTS_BRANCH=3.24-stable
ENV TMPDIR=/var/tmp

RUN printf '%s\n' \
      "https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/main" \
      "https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/community" \
      > /etc/apk/repositories \
    && apk add --no-cache \
      abuild \
      alpine-base \
      alpine-conf \
      alpine-sdk \
      bash \
      build-base \
      cmake \
      coreutils \
      dosfstools \
      e2fsprogs \
      git \
      grub \
      mtools \
      ninja \
      ovmf \
      qemu-system-x86_64 \
      squashfs-tools \
      sudo \
      syslinux \
      xorriso

WORKDIR /workspace
CMD ["/bin/bash"]
