# syntax=docker/dockerfile:1
# Thin layer over a prebuilt image that mirrors GitHub's hosted Ubuntu 26.04
# runner (catthehacker/ubuntu:full-26.04, pinned by digest). Do not add apt
# packages here; move the base digest instead.
FROM catthehacker/ubuntu:full-26.04@sha256:7e90645608881b2c263b04a32cd2b56c74384a61b9b56cc93e79cac5aabce0e3

ADD --checksum=sha256:baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40 \
    https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-linux-x64-2.338.2.tar.gz /tmp/runner.tar.gz
ADD --checksum=sha256:c5221ff41b7892bfc223543883600125f6a47fe845093e0f5bdff4f359196d83 \
    https://github.com/astral-sh/uv/releases/download/0.13.7/uv-x86_64-unknown-linux-gnu.tar.gz /tmp/uv.tar.gz
COPY entrypoint.sh /usr/local/bin/obs-runner-entrypoint
COPY job-started.sh /usr/local/bin/obs-runner-job-started.sh
USER root
# Qt GUI/platform-plugin runtime libraries that the hosted image lacks; prebuilt
# host Qt deps (.deps/host-qt6-*) link them. Keep this list short.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libopengl0 libegl1 libwayland-server0 libxcb-cursor0 libxcb-icccm4 libxcb-image0 \
      libxcb-keysyms1 libxcb-render-util0 libxcb-shape0 libxcb-util1 libxcb-xkb1 libxkbcommon-x11-0 \
    && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGTERM
RUN set -eux; \
    if ! id -u runner >/dev/null 2>&1; then \
      getent group 1001 >/dev/null || groupadd --gid 1001 runner; \
      useradd --uid 1001 --gid 1001 --create-home --shell /bin/bash runner; \
    fi; \
    test "$(id -u runner)" = 1001; \
    printf 'runner ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/runner; chmod 0440 /etc/sudoers.d/runner; \
    mkdir -p /opt/actions-runner /opt/runner-tools; \
    tar -xzf /tmp/runner.tar.gz -C /opt/actions-runner; chown -R 1001:1001 /opt/actions-runner; \
    tar -xzf /tmp/uv.tar.gz -C /opt/runner-tools --strip-components=1; \
    rm /tmp/runner.tar.gz /tmp/uv.tar.gz; \
    chmod 0755 /usr/local/bin/obs-runner-entrypoint /usr/local/bin/obs-runner-job-started.sh
ENV LANG=C.UTF-8
ENTRYPOINT ["/usr/local/bin/obs-runner-entrypoint"]
