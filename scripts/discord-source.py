#!/usr/bin/env -S uv run --python-preference only-managed --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Print the Nix `source` attrset for the newest Discord stable (Linux x64).

nixpkgs pins Discord to whatever upstream shipped when the pinned nixpkgs was
cut, and Discord refuses to start old clients, so the package is overridden
with the distro pinned here instead. The distro URLs and hashes come from the
same manifest nixpkgs' own update.py reads
(`updates.discord.com/distributions/app/manifests/latest`), which supplies
them as hex sha256 of the *compressed* payload; they are converted to SRI so
they can be pasted straight into `fetchurl { hash = ...; }`.

    uv run --python-preference only-managed --script scripts/discord-source.py

then replace the `discordSource` block in system/configuration.nix with the
output and rebuild. Nothing is fetched by this script except the manifest.
"""

from __future__ import annotations

import base64
import json
import urllib.request

MANIFEST_URL = (
    "https://updates.discord.com/distributions/app/manifests/latest"
    "?channel=stable&platform=linux&arch=x64"
)
# The distributions API rejects requests without this User-Agent.
USER_AGENT = "Discord-Updater/1"


def sri(hex_hash: str) -> str:
    return "sha256-" + base64.b64encode(bytes.fromhex(hex_hash)).decode()


def fetch_manifest() -> dict:
    request = urllib.request.Request(MANIFEST_URL, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read())


def main() -> None:
    manifest = fetch_manifest()
    full = manifest["full"]
    version = ".".join(str(part) for part in full["host_version"])

    lines = [
        "discordSource = {",
        f'  version = "{version}";',
        "  distro = {",
        f'    url = "{full["url"]}";',
        f'    hash = "{sri(full["package_sha256"])}";',
        "  };",
        "  modules = {",
    ]
    for name in sorted(manifest["modules"]):
        module = manifest["modules"][name]["full"]
        lines += [
            f"    {name} = {{",
            f"      version = {module['module_version']};",
            f'      url = "{module["url"]}";',
            f'      hash = "{sri(module["package_sha256"])}";',
            "    };",
        ]
    lines += ["  };", "};"]
    print("\n".join(lines))


if __name__ == "__main__":
    main()
