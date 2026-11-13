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
ENV DEBIAN_FRONTEND=noninteractive
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
COPY entrypoint.sh /usr/local/bin/obs-runner-entrypoint
COPY job-started.sh /usr/local/bin/obs-runner-job-started.sh
RUN chmod 0755 /usr/local/bin/obs-runner-entrypoint /usr/local/bin/obs-runner-job-started.sh
ENTRYPOINT ["/usr/local/bin/obs-runner-entrypoint"]
