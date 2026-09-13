# Private Desktop

`docker-vm` is the native Linux executable (not a Windows `.exe`). NixOS
installs the executable, its GTK/WebKit runtime, the Docker build resources,
and `docker-vm.desktop`. The quick-launch pin is in `dockLaunchers`.

This initial package imports a pinned locally compiled binary, not a
reproducible Cargo source build. Back up this release artifact:

```
~/.local/share/docker-vm/releases/docker-vm-2026-09-13.tar.gz
```

On a new machine, restore that file and run:

```
nix-store --add-fixed sha256 ~/.local/share/docker-vm/releases/docker-vm-2026-09-13.tar.gz
```

The package checks the archive hash. It does not depend on a temporary build
directory or the development checkout at runtime. Docker must be running and
the user must have access to it. The desktop image is built on launch; the
first build needs network access. Closing the viewer destroys that session.

The snapshot includes the 2 GiB shared-memory limit and crash diagnostics.
Audio forwarding is not implemented. The X11/software-rendering environment
matches the configuration tested on this workstation.
