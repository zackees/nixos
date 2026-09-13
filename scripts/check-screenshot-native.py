#!/usr/bin/env python3
"""Compare a Spectacle region PNG with its native monitor PNG, without resizing.

Usage: check-screenshot-native.py MONITOR.png REGION.png SCALE
Both captures must show the same unchanged screen. Use PNG, not JPEG.
Spectacle's logicalX/logicalY metadata identifies the crop's screen position.
"""

import json
import math
import subprocess
import sys


def identify(path):
    value = subprocess.check_output(
        [
            "magick",
            "identify",
            "-format",
            "%w %h %[logicalX] %[logicalY]",
            path,
        ],
        text=True,
    ).split()
    if len(value) != 4:
        raise ValueError("Both PNGs must retain Spectacle logicalX/logicalY metadata")
    return int(value[0]), int(value[1]), float(value[2]), float(value[3])


def pixel_offset(origin, selection, scale):
    return math.floor((selection - origin) * scale + 0.5)


def compare(monitor, region, scale):
    mw, mh, mx, my = identify(monitor)
    rw, rh, rx, ry = identify(region)
    x, y = pixel_offset(mx, rx, scale), pixel_offset(my, ry, scale)
    if not (0 <= x <= mw - rw and 0 <= y <= mh - rh):
        raise ValueError("Region lies outside the reference monitor")
    reference = subprocess.check_output(
        [
            "magick",
            monitor,
            "-crop",
            f"{rw}x{rh}+{x}+{y}",
            "+repage",
            "-alpha",
            "off",
            "-depth",
            "8",
            "rgb:-",
        ]
    )
    actual = subprocess.check_output(
        [
            "magick",
            region,
            "-alpha",
            "off",
            "-depth",
            "8",
            "rgb:-",
        ]
    )
    if len(reference) != rw * rh * 3 or len(actual) != len(reference):
        raise ValueError("Unexpected pixel buffer size")
    changed = sum(
        reference[i : i + 3] != actual[i : i + 3] for i in range(0, len(actual), 3)
    )
    return {
        "width": rw,
        "height": rh,
        "x": x,
        "y": y,
        "changed_pixels": changed,
        "total_pixels": rw * rh,
        "pixel_identical": changed == 0,
    }


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        # Regression: global logical coordinates are not local image coordinates.
        assert pixel_offset(1463, 1502.333333, 1.5) == 59
        assert pixel_offset(0, 224, 1.5) == 336
        assert pixel_offset(-1463, -1400, 1.75) == 110
        print("Coordinate regression tests passed")
    elif len(sys.argv) == 4:
        result = compare(sys.argv[1], sys.argv[2], float(sys.argv[3]))
        print(json.dumps(result, indent=2))
        sys.exit(0 if result["pixel_identical"] else 1)
    else:
        raise SystemExit(__doc__)
