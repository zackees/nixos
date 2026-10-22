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

The initial search covered local checkouts and GitHub-indexed code across the
account's organizations, returning 31 repositories with matches. The expanded
search enumerated **all 380 accessible repositories** belonging to **zackees
(301), TechWatchProject (76), and ZackeesInc (3)** using authenticated repository
listing: **146 private, 83 forks, and 12 archived repositories**. Those categories
overlap. Archived repositories and forks were included in the source scan.

Default-branch snapshots were scanned directly, avoiding GitHub code indexing
limits. Large or timed-out archives used the complete Git tree to fetch
candidate Docker, Compose, Nix, shell, installation, deployment and configuration
files. **363 repositories completed archive scans, 13 used the deployment-file
fallback, and four were empty. Forty repositories contained name matches.**
Brave's truncated GitHub tree was completed using a filtered Git clone; all
501 additional deployment candidates were fetched. No tree truncations or
candidate fetch failures remain. NGINX, OpenResty, Tengine and Angie names were searched. The accompanying
[repository inventory](nginx-repository-inventory-2026-10.json) records each
scanned branch, commit where captured, matched paths and coverage limits. A source match is evidence to
investigate, not proof of a vulnerable deployed service.

The source scan does not cover every historical branch, Git LFS object, large
file, embedded binary, submodule checkout or external image layer. Selected
inherited container images were inspected separately; this is not a complete
SBOM audit of every third-party image. Git-tree fallbacks scan deployment
candidates rather than every source file. These limitations remain explicit in
the inventory.

## Organization and contribution expansion

The next pass enumerated every accessible repository in **all nine current
GitHub membership organizations**, including the specifically requested
obs-rust and Omnix-Linux. Memberships and repositories were fully paginated.

| Current organization | Accessible repositories |
|---|---:|
| FastLED | 21 |
| ZackeesInc | 3 |
| TechWatchProject | 76 |
| CWC-data-science | 39 |
| Open-Range-Consulting | 35 |
| Omnix-Linux | 6 |
| omnix-apps | 1 |
| obs-rust | 28 |
| SmallRig-AI | 0 |
| **Total** | **209** |

Commit and pull-request contribution history from 2014 through October 2026
identified **22 additional external organizations**: Aider-AI,
Android-Tutorials-Hub, PlummersSoftwareLLC, SEDenmarkLab, SiliconLabsSoftware,
adafruit, bmcreations, brave, espressif, fjall-rs, iv-org, microsoft,
obsproject, openai, platformio, pypa, python, rclone, tauri-apps, webtorrent,
wezterm and wild-linker. Their **27 contributed repositories** were scanned;
other repositories in those external organizations were outside the audit.
Eight additional collaborator repositories belong to individual accounts.

This adds **165 source scans** to the earlier 380, bringing the cumulative
inventory to **545 repositories**: 301 personal, 209 in membership
organizations, eight external collaborator repositories and 27 external
contributed repositories. There are **234 private repositories, 89 forks,
14 archived repositories and 64 repositories with source name matches**;
these categories overlap. The new scans completed 157 archives and five
complete-Git-tree deployment fallbacks; three repositories were empty. No
candidate fetch failures or unresolved tree truncations remain.

The [organization inventory](nginx-organization-inventory-2026-10.json)
records all affiliations, repository lists and discovery limits. Contribution
windows did not reach the API's 100-repository cap, but GitHub reported
restricted contributions in 18 windows. Deleted, unattributed, restricted or
issue/comment-only activity can conceal additional relationships. The scope
is **31 visible organization identities**, not proof of every organization
this account has ever interacted with. Public archives in this extension
are identified by branch/date; exact commit IDs were captured for Git-tree
fallbacks. The scan is not an atomic snapshot of all branches.

### Remaining gaps found in this pass

| Repository or component | Finding | Action and current state |
|---|---|---|
| CWC-data-science/CWC-Writer-Webseed | Floating Python/Debian base installs NGINX without enforcing Debian's fixed package revision. | [PR #68](https://github.com/CWC-data-science/CWC-Writer-Webseed/pull/68) explicitly selects Trixie and requires 1.26.3-3+deb13u10. **Open for approval**, as required by that repository's CLAUDE.md; automatic merge is disabled. Actual package-install layer builds, nginx -t passes, and isolated dummy backends verify /health and / route to the correct upstream while forwarding the session cookie. The complete application/dataset build was not run. |
| CWC-data-science/Brighteon-AI-FE | Dockerfile and prod.Dockerfile select floating nginx:alpine. | Account has **read-only** access. [Prepared patch](nginx-patches/Brighteon-AI-FE.patch) pins the verified stable image digest; git apply --check and the repository nginx.conf pass with that image. Source remains unchanged upstream. |
| CWC-data-science/Enoch-Internal-FE | Dockerfile selects floating nginx:alpine. | Account has **read-only** access. [Prepared patch](nginx-patches/Enoch-Internal-FE.patch) passes patch application and nginx configuration checks. Source remains unchanged upstream. |
| CWC-data-science/Enoch-comsumerwellness-fe | frontend.dockerfile selects floating nginx:alpine. | Account has **read-only** access. [Prepared patch](nginx-patches/Enoch-comsumerwellness-fe.patch) passes patch application and nginx configuration checks. Source remains unchanged upstream. |
| CWC-data-science Kubernetes ingress | Eight repositories reference an external NGINX ingress class/controller without inventorying its deployed image/package. | Controller versions and running cluster state remain **unverified**. These references do not establish that the application image bundles NGINX. |
| obs-rust/obs-bot | Setup guidance and nginx.example.conf expect a host reverse proxy for webhooks. | Host package version and deployment remain **unverified**. No pinned vulnerable NGINX installation was found in the repository. |

The four application-build findings above are **version-enforcement gaps**.
A fresh pull of `nginx:alpine` during this pass reports **1.31.8**, above the
upstream fixed floor. Cached images and running hosts were not inspected;
the floating tag alone is not evidence of an installed vulnerable version.
The Writer test installs the fixed Debian backport. No production containers
were redeployed as part of this organization scan.

No direct NGINX package/image dependency was found in the six Omnix-Linux
repositories or omnix-apps/obs-studio. Within obs-rust, the other matches are
vendor libraries, license authors and protocol/comment strings. Other new
reference-only matches include FastLED/FastLED, FastLED/cli,
CWC-data-science/Enoch-Internal (commented-out NGINX stage),
CWC-data-science/web-crawler, techwatch2/twdb, brave/brave-core, pypa/pip,
python/cpython and rclone/rclone. webtorrent/instant.io provides host proxy
configuration whose installed server version is outside the source inventory.
Inherited third-party images still require their own package/SBOM inventory;
absence of a source match does not certify their contents.

The eight ingress-reference repositories are CWC-data-science/
Brighteon-AI-FE, Brighteon-AI-BE, Brighteon-AI-HelmChart,
Enoch-Internal-FE, Enoch-Internal-BE, Enoch-comsumerwellness-fe,
Enoch-comsumerwellness-be and Internal-AI-API-Relay.

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

All eleven initial repository fixes are on their default branches. Act2's six CI checks
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

## Additional findings from the complete repository inventory

| Repository | Missed instance | Fix and verification |
|---|---|---|
| zackees/magic-wormhole-transit-relay-docker | The relay image installed NGINX from Debian Bullseye. | [PR #1](https://github.com/zackees/magic-wormhole-transit-relay-docker/pull/1), merged: retain Python 3.10 on Trixie and enforce Debian's fixed package floor. Full image build and normal entrypoint passed; health returned HTTP 200/OK and the relay accepted a connection on port 4001. Installed package: 1.26.3-3+deb13u10. |
| TechWatchProject/jobs.kumquat.live | Archived jobs gateway image installed NGINX from Bookworm. | [PR #1](https://github.com/TechWatchProject/jobs.kumquat.live/pull/1), merged: use Trixie, explicitly install adduser, enforce 1.26.3-3+deb13u10. Runtime layer builds; nginx -t passes; health HTTP 200/healthy, UI HTTP 401, root HTTP 301. No jobs or database started; the full Go application image was not built. Temporarily unarchived with user approval, merged commit 65771bafad37908ba1607dc3fdffb3120b8d40cf, and verified archived again. |
| zackees/nix | Four isolated NixOS test VM servers selected NGINX 1.30.4 through the pinned nixpkgs input. | [PR #1](https://github.com/zackees/nix/pull/1), merged: shared fixture default selects checksum-verified 1.30.6 without moving compatibility inputs. Evaluation against the fork's own pin reproduced 1.30.4 before and 1.30.6 after; the selected package builds. All enabled fixture servers also evaluate to 1.30.6 with the local NixOS 26.05 input. The full C++ build/VM suite was not run. |
| zackees/rclone | Seafile integration fixtures indirectly inherit NGINX from seafileltd/seafile-mc:latest. The inspected image actually contains 1.26.2-1~jammy. | [PR #1](https://github.com/zackees/rclone/pull/1), merged: build a thin fixture image upgrading the signed upstream package to at least 1.30.6-1~jammy; rebuild before both Seafile fixture starts. Built image reports the fixed version, nginx -t passes, and the custom nginx.conf hash is unchanged. Shell syntax and Compose validation pass; complete database-backed integration tests were not run. |

The Nix and rclone findings affect test infrastructure, not the application
binaries shipped by those projects. Rclone's original text-only classification
missed this inherited image dependency. Its ordinary and encrypted Seafile
fixtures are patched; its separate obsolete **TestSeafileV6** image
`seafileltd/seafile:latest` is no longer publicly pullable, so that image's
contents and patch status remain unverified. The inspected Seafile-MC source
image digest was
`sha256:f1e19cc1cdd52ed8ec883de114acaa1e932941515dd6571fce0c0ff02248c4cf`.

A further indirect reference needs external artifact inventory:
**zackees/windows** copies its entire amd64 root filesystem from
`qemux/qemu-docker:6.07` and inherits `dockurr/windows-arm:4.00` for arm64.
The upstream QEMU project installs NGINX, but the referenced qemux image cannot
be pulled anonymously. Its installed version is therefore **unverified**, not
marked fixed. Its upstream source is
[QEMU Dockerfile](https://github.com/qemus/qemu-docker/blob/master/Dockerfile).

All four implementation diffs pass staged gitleaks and whitespace checks.
Repository merges do not rebuild unknown external deployments. No active
Render service for either new application repository was found in the
inspected workspace; services in other workspaces/hosts were not ruled out.

## References that do not establish a vulnerable repository dependency

These repositories contain NGINX text but do not pin/install its runtime in
an active application build found by the search:

- **Code, test strings, vendor code or documentation:** FastLED/FastLED,
  TechWatchProject/ChildTWDB, TechWatchProject/blueprint,
  TechWatchProject/kumquat, TechWatchProject/twp, zackees/docker-phpFox4,
  zackees/honeycolony, zackees/kumquat, zackees/memex, zackees/pip,
  zackees/soldr, zackees/zccache, zackees/brave-core (vendored Rust README files),
  zackees/cpython, zackees/twdb,
  TechWatchProject/twdb, TechWatchProject/Digital-Ocean-Functions,
  TechWatchProject/kumquat-batch, TechWatchProject/dev-textract and
  TechWatchProject/textract.kumquat.link.
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
