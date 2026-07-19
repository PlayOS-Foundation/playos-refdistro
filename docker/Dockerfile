FROM alpine:3.24.1

ARG ALPINE_BRANCH=v3.24
ENV PLAYOS_ALPINE_BRANCH=${ALPINE_BRANCH}
ENV PLAYOS_APORTS_BRANCH=3.24-stable
ENV TMPDIR=/var/tmp

COPY scripts/install-alpine-build-deps.sh /usr/local/libexec/playos/install-alpine-build-deps.sh
RUN /bin/sh /usr/local/libexec/playos/install-alpine-build-deps.sh

WORKDIR /workspace
CMD ["/bin/bash"]
