FROM ubuntu:26.04@sha256:157dc3d6e4a3e4f2c68d12df9df9ed6e808b59af6d4c3757b432b4f519916725 AS distribution

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl tar gzip
RUN curl --fail --location --retry 3 \
      https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-linux-x64-2.338.2.tar.gz \
      --output /tmp/runner.tar.gz \
    && printf '%s  %s\n' baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40 /tmp/runner.tar.gz | sha256sum --check \
    && mkdir /runner \
    && tar -xzf /tmp/runner.tar.gz -C /runner
RUN curl --fail --location --retry 3 \
      https://github.com/astral-sh/uv/releases/download/0.13.7/uv-x86_64-unknown-linux-gnu.tar.gz \
      --output /tmp/uv.tar.gz \
    && printf '%s  %s\n' c5221ff41b7892bfc223543883600125f6a47fe845093e0f5bdff4f359196d83 /tmp/uv.tar.gz | sha256sum --check \
    && mkdir /uv \
    && tar -xzf /tmp/uv.tar.gz -C /uv --strip-components=1

FROM ubuntu:26.04@sha256:157dc3d6e4a3e4f2c68d12df9df9ed6e808b59af6d4c3757b432b4f519916725
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl wget git gh jq sudo unzip zip tar gzip xz-utils zstd \
      docker.io docker-buildx util-linux iproute2 procps file \
      python3 python3-venv build-essential cmake ninja-build pkg-config libxml2-utils \
    && groupadd --gid 1001 runner \
    && useradd --uid 1001 --gid 1001 --create-home runner \
    && printf 'runner ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/runner \
    && chmod 0440 /etc/sudoers.d/runner
COPY --from=distribution --chown=1001:1001 /runner /opt/actions-runner
COPY --from=distribution /uv/uv /opt/runner-tools/uv
COPY --from=distribution /uv/uvx /opt/runner-tools/uvx
RUN /opt/actions-runner/bin/installdependencies.sh
# Parity with actions/runner-images ubuntu toolset-2604.json (vital, common
# and cmd apt packages; 7zip-rar and emoji fonts skipped) plus the shared
# libraries hosted runners carry that prebuilt deps (host Qt uic/moc) load.
RUN apt-get update && apt-get install -y --no-install-recommends \
      bzip2 curl g++ gcc make jq tar unzip \
      wget autoconf automake dbus bind9-dnsutils dpkg dpkg-dev fakeroot \
      gnupg2 iproute2 iputils-ping libyaml-dev libtool libssl-dev libjitterentropy3-dev libcrypt-dev \
      libicu-dev libsqlite3-dev locales openssh-client pkg-config python-is-python3 rpm texinfo \
      tk tree tzdata upx xvfb xz-utils zsync acl \
      aria2 binutils bison brotli libnss3-tools coreutils file findutils \
      flex ftp lz4 m4 netcat-openbsd net-tools 7zip parallel \
      patchelf pigz rsync shellcheck sqlite3 ssh sshpass sudo \
      systemd-coredump swig telnet time zip libglib2.0-0t64 libgl1 libegl1 \
      libopengl0 libxkbcommon0 libxkbcommon-x11-0 libfontconfig1 libfreetype6 libdbus-1-3 libx11-6 libx11-xcb1 \
      libxcb1 libxcb-cursor0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-randr0 libxcb-render-util0 libxcb-shape0 \
      libxcb-xinerama0 libxcb-xkb1 libxrender1 libxi6 libsm6 libice6 libgssapi-krb5-2 zstd \
      libwayland-client0 libwayland-cursor0 libwayland-egl1 libwayland-server0 \
    && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/obs-runner-entrypoint
COPY job-started.sh /usr/local/bin/obs-runner-job-started.sh
RUN chmod 0755 /usr/local/bin/obs-runner-entrypoint /usr/local/bin/obs-runner-job-started.sh
ENTRYPOINT ["/usr/local/bin/obs-runner-entrypoint"]
