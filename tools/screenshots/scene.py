# Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
#
# Writes the layout file for the README screenshots: three scenes stacked
# vertically, each captured as one image by make-screenshots.sh.
#
#   1. glass  six medium panels in Liquid Glass (3 x 2)
#   2. solid  the same six with solid backgrounds and the btop theme
#   3. sizes  CPU in medium, small and extra small, plus other small panels
#
# Panels float above windows and ignore clicks while the screenshots are taken.
#
#   python3 scene.py OUTPUT.json

import json
import sys

SIZES = {"medium": (320, 180), "small": (154, 110), "extraSmall": (140, 64)}
GAP, LEFT = 16, 200
panels = []


def add(scene, kind, size, x, y, **appearance):
    width, height = SIZES[size]
    panel = {
        "id": f"{scene}-{kind}-{size}", "kind": kind, "sizeClass": size, "isVisible": True,
        "clickThrough": True, "level": "floating",
        "placement": {
            "anchor": "topLeading", "desktop": {"all": {}}, "display": {"main": {}},
            "offset": {"x": x, "y": y}, "size": {"width": width, "height": height},
        },
    }
    if appearance:
        panel["appearance"] = appearance
    panels.append(panel)


for scene, top, look in [("glass", 40, {}), ("solid", 500, {"material": "solid", "theme": "btop"})]:
    for index, kind in enumerate(["cpu", "memory", "topProcesses", "network", "disk", "gpu"]):
        add(scene, kind, "medium", LEFT + (index % 3) * (320 + GAP), top + (index // 3) * (180 + GAP), **look)

top = 960
add("sizes", "cpu", "medium", LEFT, top)
x = LEFT + 320 + GAP
for kind in ["cpu", "thermals", "systemInfo"]:
    add("sizes", kind, "small", x, top)
    x += 154 + GAP
for index, kind in enumerate(["cpu", "memory", "network", "disk"]):
    add("sizes", kind, "extraSmall", x + (index % 2) * (140 + GAP), top + (index // 2) * (64 + GAP))

layout = {"id": "screenshots", "name": "Screenshots", "panels": panels}
json.dump({"version": 2, "library": {"activeID": "screenshots", "profiles": [layout]}}, open(sys.argv[1], "w"))
