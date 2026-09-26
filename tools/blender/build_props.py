"""Build the Sakura Rally low-poly prop kit (deterministic).

Usage (from the repo root):
  /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
      --python tools/blender/build_props.py -- [--only name1,name2] [--out assets/models/props]

Writes one GLB per prop plus `manifest.json` into --out. With --only, the manifest keeps the
existing entries of props that were not rebuilt. Builders live in tools/blender/props/.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import bpy  # noqa: E402

from props import common, registry  # noqa: E402
from props import vegetation, rocks, village, rally, people  # noqa: E402,F401  (register props)

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))


def parse_args() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--out", default=os.path.join(REPO, "assets", "models", "props"))
    return ap.parse_args(argv)


def r3(v: float) -> float:
    return round(v + 0.0, 3)


def export(obj: bpy.types.Object, empties: list[bpy.types.Object], path: str) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    for e in empties:
        e.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_normals=True,
        export_texcoords=False,
        export_materials="EXPORT",
        export_vertex_color="ACTIVE",
        export_cameras=False,
        export_lights=False,
        export_extras=False,
        export_animations=False,
    )


def manifest_entry(spec: registry.PropSpec, obj: bpy.types.Object, out_rel: str) -> dict:
    vs = [v.co for v in obj.data.vertices]
    xs = [v.x for v in vs]
    ys = [v.y for v in vs]
    zs = [v.z for v in vs]
    mn = (min(xs), min(ys), min(zs))
    mx = (max(xs), max(ys), max(zs))
    size_g = [r3(mx[0] - mn[0]), r3(mx[2] - mn[2]), r3(mx[1] - mn[1])]  # Godot x, y(up), z
    center_g = [r3((mx[0] + mn[0]) / 2), r3((mx[2] + mn[2]) / 2), r3(-(mx[1] + mn[1]) / 2)]
    foot = max(math.hypot(v.x, v.y) for v in vs)
    col = dict(spec.collision)
    if col["type"] == "cylinder":
        col.setdefault("height", r3(mx[2]))
        col["radius"] = r3(col["radius"])
    elif col["type"] == "box":
        col.setdefault("size", size_g)
        col.setdefault("center", center_g)
    return {
        "name": spec.name,
        "file": out_rel,
        "category": spec.category,
        "size": size_g,
        "aabb_center": center_g,
        "collision": col,
        "placement": spec.placement,
        "footprint_radius": r3(foot),
        "seasons": spec.seasons,
        "tris": common.tri_count(obj),
        "materials": [m.name for m in obj.data.materials],
        "nodes": [obj.name],
    }


def main() -> None:
    args = parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    only = [n for n in args.only.split(",") if n]
    for n in only:
        if n not in registry.PROPS:
            raise SystemExit(f"unknown prop {n!r}")
    man_path = os.path.join(out, "manifest.json")
    existing: dict[str, dict] = {}
    if only and os.path.exists(man_path):
        with open(man_path) as f:
            existing = {p["name"]: p for p in json.load(f)["props"]}
    over_budget = []
    for name, spec in registry.PROPS.items():
        if only and name not in only:
            continue
        common.reset_scene()
        kit = common.Kit(name)
        spec.build(kit)
        obj, empties = kit.build_object()
        path = os.path.join(out, f"{name}.glb")
        export(obj, empties, path)
        rel = "res://" + os.path.relpath(path, REPO).replace(os.sep, "/")
        entry = manifest_entry(spec, obj, rel)
        if empties:
            entry["nodes"] += [e.name for e in empties]
            entry["markers"] = {e.name: [r3(e.location.x), r3(e.location.z), r3(-e.location.y)]
                                for e in empties}
        existing[name] = entry
        flag = "" if entry["tris"] <= spec.max_tris else f"  OVER BUDGET ({spec.max_tris})"
        if flag:
            over_budget.append(name)
        print(f"PROP {name:20s} tris={entry['tris']:5d} size={entry['size']}{flag}")
    ordered = [existing[n] for n in registry.PROPS if n in existing]
    manifest = {
        "version": 1,
        "units": "metres; size/aabb_center/markers in Godot axes (x right, y up, z back); "
                 "origin = base centre on ground; front faces -Z (Blender +Y)",
        "collision_notes": "none: no collider (foliage/ground cover/overhead dressing). cylinder: "
                           "radius, from y=0 to height, centred on origin or, when 'offsets' is "
                           "present, one cylinder per offset (e.g. gate posts; the gap stays "
                           "open). box: size + center in prop-local Godot coordinates. Tree "
                           "cylinders cover the trunk only.",
        "props": ordered,
    }
    with open(man_path, "w") as f:
        json.dump(manifest, f, indent=1)
    print(f"MANIFEST {man_path} ({len(ordered)} props)")
    if over_budget:
        print("OVER_BUDGET " + ",".join(over_budget))


main()
