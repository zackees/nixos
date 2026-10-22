# CWC frontend NGINX package guards

These three repositories are read-only for the authenticated account. Their
Dockerfiles use `nginx:alpine` without a version floor or immutable digest.
The freshly pulled tag reported **1.31.8** during the audit; the package in
cached images and existing deployments was not established.

The patches select the verified stable 1.30.6 Alpine image by multi-platform
digest. They address version reproducibility for the five October 14 CVEs;
they do not establish that the currently running application is vulnerable.

| Patch | Repository and files |
|---|---|
| [Brighteon-AI-FE.patch](Brighteon-AI-FE.patch) | CWC-data-science/Brighteon-AI-FE: Dockerfile and prod.Dockerfile |
| [Enoch-Internal-FE.patch](Enoch-Internal-FE.patch) | CWC-data-science/Enoch-Internal-FE: Dockerfile |
| [Enoch-comsumerwellness-fe.patch](Enoch-comsumerwellness-fe.patch) | CWC-data-science/Enoch-comsumerwellness-fe: frontend.dockerfile |

Each patch passes `git apply --check` against the fetched source. Each
repository's complete nginx.conf passes `nginx -t` with the pinned image.
Full frontend application builds and deployments were not run.

A maintainer can apply the corresponding patch from the target checkout:

```bash
git apply --check /path/to/the-corresponding.patch
git apply /path/to/the-corresponding.patch
```

Commit through the target project's review process and rebuild/redeploy its
application images. Existing containers do not change when a patch is saved.
