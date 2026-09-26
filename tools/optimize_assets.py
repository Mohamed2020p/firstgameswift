# -*- coding: utf-8 -*-
"""Rebuilds every optimised model + JSON in Supercars/Resources from assets_src/*.glb.
   python tools/optimize_assets.py [car|buildings|tree|rider ...]     (no argument = all four)
The car and tree builders decimate meshes through the Blender 2.79 MCP bridge (tools/asset_decimate.py -> C:/blender-claude/scripts/mcp_cli.py),
so Blender must be running with the bridge. The optimised results are committed in Supercars/Resources, so the app build does not need this."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

STEPS = {
    "car": ("asset_car", "build_player"),
    "buildings": ("asset_buildings", "build"),
    "tree": ("asset_tree", "build"),
    "rider": ("asset_rider", "build"),
}

if __name__ == "__main__":
    names = sys.argv[1:] or list(STEPS)
    for n in names:
        mod, fn = STEPS[n]
        print("== %s ==" % n)
        getattr(__import__(mod), fn)()
