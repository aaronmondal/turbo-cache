FROM ubuntu:22.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates=20240203~22.04.1 \
    git=1:2.34.1-1ubuntu1.12 \
    curl=7.81.0-1ubuntu1.20 \
    gnupg=2.2.27-3ubuntu2.1 \
    gcc=4:11.2.0-1ubuntu1 \
    g++=4:11.2.0-1ubuntu1 \
    pkg-config=0.29.2-1ubuntu3 \
    zip=3.0-12build2 \
    unzip=6.0-26ubuntu3.2 \
    python3=3.10.6-1~22.04.1 \
    apt-transport-https=2.4.13 \
    coreutils=8.32-4.1ubuntu1.2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN curl -fsSL https://bazel.build/bazel-release.pub.gpg | gpg --dearmor > bazel-archive-keyring.gpg \
    && mv bazel-archive-keyring.gpg /usr/share/keyrings \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/bazel-archive-keyring.gpg] https://storage.googleapis.com/bazel-apt stable jdk1.8" | tee /etc/apt/sources.list.d/bazel.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends bazel-7.4.1=7.4.1 \
    && ln -s /usr/bin/bazel-7.4.1 /usr/bin/bazel \
    && rm -rf /var/lib/apt/lists/*

RUN bazel --version

WORKDIR /build
RUN git clone https://github.com/TraceMachina/nativelink.git

WORKDIR /build/nativelink
RUN bazel build -c opt nativelink \
    && mkdir -p /build/bin \
    && cp -L bazel-bin/nativelink /build/bin/

FROM ubuntu:22.04

LABEL org.opencontainers.image.title="NativeLink worker init" \
      org.opencontainers.image.description="Init container to prepare NativeLink workers." \
      org.opencontainers.image.documentation="https://github.com/TraceMachina/nativelink" \
      org.opencontainers.image.source="https://github.com/TraceMachina/nativelink" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="Trace Machina, Inc."

RUN groupadd -r nativelink && useradd -r -g nativelink nativelink

RUN apt-get update && apt-get install -y --no-install-recommends \
    coreutils=8.32-4.1ubuntu1.2 \
    ca-certificates=20240203~22.04.1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/bin/nativelink /usr/local/bin/nativelink

RUN printf '#!/bin/sh\ncp -Lv /usr/local/bin/nativelink "$@"\n' > /usr/local/bin/copyToDestination \
    && chmod +x /usr/local/bin/copyToDestination

RUN chown nativelink:nativelink /usr/local/bin/nativelink /usr/local/bin/copyToDestination

USER nativelink

ENTRYPOINT ["/usr/local/bin/copyToDestination"]

HEALTHCHECK NONE
