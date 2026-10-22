# NGINX security audit — October 2026

## Advisory and scope

The reported heading was “NGINX — 5 CVEs,” seen on October 21. No original
report or CVE list was supplied. The matching upstream October 14 release
fixes the following five CVEs; this audit covers that batch.

| CVE | Issue and relevant configuration |
|---|---|
| CVE-2026-15176 | Heap overflow with alias/rewrite path construction and request-filename use. |
| CVE-2026-93479 | Heap overflow while evaluating variable expressions, including regex map captures. |
| CVE-2026-95101 | HTTP/3 proxy request-body injection. |
| CVE-2026-97629 | Forged TLS sessions during automatic session-ticket key rotation; can undermine client-certificate checks. |
| CVE-2026-97205 | Use-after-free with AIO and SSI virtual includes. |

These issues are configuration dependent; finding an affected package version
does not establish that every CVE is exploitable in that deployment.

Upstream fixes are **1.30.6 stable / 1.31.7 mainline**. Debian Trixie carries
the fixes in **1.26.3-3+deb13u10**, so upstream version comparison alone would
incorrectly reject that patched package. Debian Bookworm's tracker still
lists the October batch as open.

Sources: [NGINX release notes](https://nginx.org/en/CHANGES-1.30),
[upstream advisories](https://nginx.org/en/security_advisories.html),
[Debian security tracker](https://security-tracker.debian.org/tracker/source-package/nginx).

Searches covered tracked local checkouts and GitHub-indexed default-branch
code for zackees and all nine organizations returned by the authenticated
account: FastLED, ZackeesInc, TechWatchProject, CWC-data-science,
Open-Range-Consulting, Omnix-Linux, omnix-apps, obs-rust, SmallRig-AI.
Both normal and fork searches were used. GitHub returned **31 matching
repositories**. Unindexed files, inaccessible repositories and deployed
artifacts outside these repositories are not covered by that count.

## Repository fixes

The workstation previously ran 1.30.4. Its narrow source override is built,
activated and committed as [aa57f07](https://github.com/zackees/nixos/commit/aa57f07).
The active systemd command now uses the 1.30.6 binary; local redirects work.
No unrelated nixpkgs packages were updated.

| Repository | Change | Pull request | State at audit |
|---|---|---|---|
| zackees/nginx-proxy | Pin the verified NGINX stable image and install the complete configuration at its proper root path. | [fix](https://github.com/zackees/nginx-proxy/pull/1) | merged |
| zackees/docker-mysql-proxy | Pin the official Alpine NGINX 1.30.6 image by digest so rebuilding cannot retain an unknown floating NGINX release. | [fix](https://github.com/zackees/docker-mysql-proxy/pull/1) | merged |
| zackees/torrent-worker | Generate Compose files using the verified NGINX 1.30.6 Alpine image digest. | [fix](https://github.com/zackees/torrent-worker/pull/1) | merged |
| zackees/minio | Replace all nine NGINX 1.19.2 Alpine references in Compose examples and integration infrastructure with the verified 1.30.6 Alpine digest. | [fix](https://github.com/zackees/minio/pull/1) | merged |
| zackees/SmoothMQ | Use Debian Trixie with the DSA-6575-1 security backport instead of vulnerable Bookworm. Enforce the minimum fixed package revision and explicitly install adduser, required by the entrypoint. | [fix](https://github.com/zackees/SmoothMQ/pull/1) | merged |
| TechWatchProject/QA | Make the Debian Trixie base explicit and fail the build if nginx predates the DSA-6575-1 backport. Debian fixes these CVEs at 1.26.3-3+deb13u10; a raw upstream semver comparison would be incorrect. | [fix](https://github.com/TechWatchProject/QA/pull/77) | merged |
| TechWatchProject/ads_dashboard | Use signed upstream stable RPMs with a 1.30.6 minimum rather than the AlmaLinux 8 default module. Keep GPG verification enabled and disable the conflicting distribution module. | [fix](https://github.com/TechWatchProject/ads_dashboard/pull/31) | merged |
| zackees/mike-sync | The token-generator base uses an old Alpine repository without the security fixes. Compile checksum-verified NGINX 1.30.6 on the identical base and copy only the resulting binary into the runtime. | [fix](https://github.com/zackees/mike-sync/pull/1) | merged |
| zackees/act2 | Pin executable NGINX integration-service fixtures to the verified 1.30.6 Debian image digest. Leave parser-only sample strings as parser fixtures. | [fix](https://github.com/zackees/act2/pull/80) | merged |
| zackees/aquatic | Remove the unnecessary NGINX installation from benchmark setup. Write flamegraphs to a local SVG that can be opened directly instead of requiring a web-server directory. | [fix](https://github.com/zackees/aquatic/pull/1) | merged |

### Verification

- **zackees/nginx-proxy**: Full image build and nginx -t passed; the original conf.d placement failed because it contains events/http blocks.
- **zackees/docker-mysql-proxy**: Full image build and nginx -t passed.
- **zackees/torrent-worker**: Both Docker Compose template tests passed; the pinned official image reports nginx/1.30.6.
- **zackees/minio**: All nine changed Compose files passed docker compose config validation; the pinned image reports nginx/1.30.6.
- **zackees/SmoothMQ**: Debian security package 1.26.3-3+deb13u10 installed and passed the version floor. NGINX config passed in the runtime layer with the entrypoint user created. The full application image was not built.
- **TechWatchProject/QA**: Seven Render packaging tests passed. The actual patched runtime package-install layer built successfully and gateway/nginx.conf passed nginx -t.
- **TechWatchProject/ads_dashboard**: A minimal AlmaLinux 8 build installed nginx-1:1.30.6-1.el8.ngx from the new repository and passed nginx -t with this repository's configuration. The full PHP/application image was not built.
- **zackees/mike-sync**: Full Dockerfile.potoken image built; its binary reports nginx/1.30.6 and nginx -t passed.
- **zackees/act2**: go test ./pkg/model passed; the pinned official NGINX image reports version 1.30.6.
- **zackees/aquatic**: Both shell scripts passed bash -n. A stubbed profiling-tool pipeline produced the local SVG without a web server or privileged output directory.

All eleven repository fixes are on their default branches. Act2's six CI checks
(including Linux, macOS, Windows and snapshot) ultimately all passed.

All implementation diffs passed credential scanning. The official Debian and
Alpine images were pulled and their binaries verified as 1.30.6 before pinning
their multi-platform digests. Existing Compose/Actions fixture files were
updated; no new GitHub Actions workflows were added.

Torrent-worker's unrelated full CI failures were verified against the
pre-change commit: its old test cannot import InfoHash from the current
coordinator dependency, and its install script is mode 100644 while lint
executes it directly. The focused template tests pass. No required checks
are configured there; the security fix was merged with those existing
failures documented in its PR.

## References that do not establish a vulnerable repository dependency

These repositories contain NGINX text but do not pin/install its runtime in
an active application build found by the search:

- **Code, test strings, vendor code or documentation:** FastLED/FastLED,
  TechWatchProject/ChildTWDB, TechWatchProject/blueprint,
  TechWatchProject/kumquat, TechWatchProject/twp, zackees/docker-phpFox4,
  zackees/honeycolony, zackees/kumquat, zackees/memex, zackees/pip,
  zackees/rclone, zackees/soldr, zackees/zccache.
- **Optional proxy example:** zackees/transcribe-anything supplies an NGINX
  config example; its supplied Compose deployment uses Caddy.
- **Host configuration or deployment references needing a separate installed
  package/controller inventory:** zackees/hermes, zackees/instant.io,
  zackees/webtorrent.io and CWC-data-science/Enoch-comsumerwellness-be. The
  latter selects an external ingress class; it does not pin the controller.
- **Legacy host installation scripts:** zackees/peertube_ezinstall_ubuntu20LTS
  and zackees/vids-db-server's archive. They reference distro packages without
  an installed version or an active deployment manifest. Their deployed host
  state was not established, so they are not marked remediated.

Local T3Clud matches were in `.repos/`, an explicitly read-only collection of
third-party reference sources, rather than its application runtime.

## Deployment boundary

A merged Dockerfile/template fix does not replace existing containers or
publish a new image by itself. Existing deployments outside the services
verified below still need rebuilding/recreating from the fixed default branch.
Only NGINX was audited, not every component in these images.

- **Workstation:** 1.30.6 is active; the system build and redirect probe pass.
- **QA/Nexus:** Render deploy of merged commit
  `1a417dc062a73778c3a31f1b761b5c5de6744083` is live. Its build enforces the
  patched Debian package floor; `https://kumquat.link/` responds with the
  expected authentication redirect (HTTP 302).
- **Ads dashboard:** the first security deploy exposed a routing regression:
  the upstream RPM's bundled `conf.d/default.conf` shadowed the authenticated
  application server and served the welcome page. This was detected by a
  post-deploy HTTP probe. [Follow-up #32](https://github.com/TechWatchProject/ads_dashboard/pull/32)
  moves that default site outside the include glob and adds
  `docker/check-nginx-route.sh`. The check fails with HTTP 200 on the initial
  RPM image and passes with HTTP 401 on the corrected image, without starting
  application jobs or using credentials. Corrected merged commit
  `9471817cb7175e5d83a376bb7bb9cc0822406207` was explicitly submitted for
  deployment after the automatic trigger did not start it. That exact commit
  is now **live**, and the public URL
  `https://ads-dashboard-1ntd.onrender.com/` returns **HTTP 401** as expected,
  rather than the default welcome page. This validates the restored
  authentication boundary as well as the fixed NGINX package build.
