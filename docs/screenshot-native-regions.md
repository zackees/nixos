# Native-resolution screenshot regions

Spectacle 6.7.4 combines mixed-DPR screen images at an integer DPR, then
rescales a selected region on export. At this machine's 150%/175% scales,
that round trip adds blur even when the final pixel dimensions look right.
Upstream context: https://bugs.kde.org/show_bug.cgi?id=490353.

`system/patches/spectacle-native-region.patch` retains the original per-screen
captures and restores the appropriate image before cropping a plain region
contained within one screen. It subtracts that screen's logical origin:
`AnnotationDocument::cropCanvas` takes canvas-relative, not desktop-global,
coordinates. Omitting this subtraction selects the wrong pixels on HDMI-A-1.

Cross-screen selections and selections with existing annotation undo/redo
history retain upstream behavior. Annotations added after selection work on
the native crop. JPEG quality remains 95; JPEG itself is lossy, so pixel-exact
verification must use PNG before the clipboard helper converts it.

## Verification

Display a stationary sharp-edge pattern. Save a native current-monitor PNG,
then a region PNG of the same unchanged screen. Keep Spectacle's PNG
`logicalX`/`logicalY` metadata. On the main monitor:

```sh
python3 scripts/check-screenshot-native.py --self-test
python3 scripts/check-screenshot-native.py monitor.png region.png 1.5
```

The comparison must report `pixel_identical: true` and zero changed pixels.
It compares actual RGB bytes without resizing either image. A deliberately
resampled fixture must fail. Use `1.75` for either secondary monitor.

The temporary running-driver environment workaround lives only under
`/run/user/1000/systemd/user/app-org.kde.spectacle.service.d/`; it is not this
patch. Reboot clears it and loads the installed matching NVIDIA driver.
