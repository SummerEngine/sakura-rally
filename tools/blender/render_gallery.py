"""Render a labelled contact sheet of exported prop GLBs with a cel-shaded preview look.

Usage (from the repo root):
  /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
      --python tools/blender/render_gallery.py -- --names sakura_a,sakura_b \
      --out docs/renders/props_trees.png [--cols 5] [--tile 480] [--scale-ref]

--category <cat>[,<cat>] picks every manifest entry of those categories instead of --names.
--scene spring|autumn renders a 1600x900 roadside diorama from chase-camera height instead
(gameplay-distance readability check), e.g. --scene spring --out docs/renders/props_scene_spring.png
Each tile: orthographic 3/4 front view (front = Blender +Y), sun + cel ramp with violet shadow
tint (approximates the in-game toon shader), Freestyle ink outlines, label with name / tris /
height. Tiles are composed with ffmpeg into one PNG.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
from props.common import MATERIALS, hex_rgb  # noqa: E402  (palette = source of truth)

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
PROPS_DIR = os.path.join(REPO, "assets", "models", "props")
FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"

INK = (0.165, 0.133, 0.208)
SHADOW_TINT = (0.604, 0.573, 0.784)  # #9a92c8
EMISSIVE_KEYS = ("light", "emit", "lamp", "lantern")


def s2l(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def parse() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--names", default="")
    ap.add_argument("--category", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--cols", type=int, default=5)
    ap.add_argument("--tile", type=int, default=480)
    ap.add_argument("--elev", type=float, default=16.0)
    ap.add_argument("--azim", type=float, default=32.0)
    ap.add_argument("--scene", default="", help="spring|autumn: render a diorama instead of tiles")
    return ap.parse_args(argv)


def clear() -> None:
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for coll in (bpy.data.meshes, bpy.data.materials, bpy.data.curves, bpy.data.cameras, bpy.data.lights):
        for d in list(coll):
            coll.remove(d)


def cel_material(src: bpy.types.Material, color_attr: str | None) -> bpy.types.Material:
    name = src.name.split(".")[0]
    if name not in MATERIALS:
        raise KeyError(f"material {name!r} missing from the palette table")
    hx, emit = MATERIALS[name]
    base = (*[s2l(c) for c in hex_rgb(hx)], 1.0)
    mat = bpy.data.materials.new(name + "_cel")
    mat.use_backface_culling = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    albedo = nt.nodes.new("ShaderNodeRGB")
    albedo.outputs[0].default_value = base
    col_socket = albedo.outputs[0]
    if color_attr:
        attr = nt.nodes.new("ShaderNodeVertexColor")
        attr.layer_name = color_attr
        mul = nt.nodes.new("ShaderNodeMix")
        mul.data_type = "RGBA"
        mul.blend_type = "MULTIPLY"
        mul.inputs[0].default_value = 1.0
        nt.links.new(albedo.outputs[0], mul.inputs[6])
        nt.links.new(attr.outputs["Color"], mul.inputs[7])
        col_socket = mul.outputs[2]
    lname = name.lower()
    emission = nt.nodes.new("ShaderNodeEmission")
    if emit > 0 or any(k in lname for k in EMISSIVE_KEYS):
        nt.links.new(col_socket, emission.inputs["Color"])
        emission.inputs["Strength"].default_value = 1.15
        nt.links.new(emission.outputs[0], out.inputs["Surface"])
        return mat
    diff = nt.nodes.new("ShaderNodeBsdfDiffuse")
    s2rgb = nt.nodes.new("ShaderNodeShaderToRGB")
    bw = nt.nodes.new("ShaderNodeRGBToBW")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.interpolation = "CONSTANT"
    high_key = "blossom" in lname
    els = ramp.color_ramp.elements
    els[0].position = 0.0
    els[0].color = (0.0, 0.0, 0.0, 1.0) if not high_key else (0.35, 0.35, 0.35, 1.0)
    els[1].position = 0.3
    els[1].color = (1.0, 1.0, 1.0, 1.0)
    mid = els.new(0.12)
    mid.color = (0.55, 0.55, 0.55, 1.0) if not high_key else (0.75, 0.75, 0.75, 1.0)
    nt.links.new(diff.outputs[0], s2rgb.inputs[0])
    nt.links.new(s2rgb.outputs[0], bw.inputs[0])
    nt.links.new(bw.outputs[0], ramp.inputs[0])
    shadow = nt.nodes.new("ShaderNodeMix")
    shadow.data_type = "RGBA"
    shadow.blend_type = "MULTIPLY"
    shadow.inputs[0].default_value = 1.0
    nt.links.new(col_socket, shadow.inputs[6])
    shadow.inputs[7].default_value = (*[s2l(c) for c in SHADOW_TINT], 1.0)
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    nt.links.new(ramp.outputs[0], mix.inputs[0])
    nt.links.new(shadow.outputs[2], mix.inputs[6])
    nt.links.new(col_socket, mix.inputs[7])
    nt.links.new(mix.outputs[2], emission.inputs["Color"])
    emission.inputs["Strength"].default_value = 1.0
    nt.links.new(emission.outputs[0], out.inputs["Surface"])
    return mat


def setup_render(tile: int) -> None:
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE"
    sc.render.resolution_x = tile
    sc.render.resolution_y = tile
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = False
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    try:
        sc.eevee.taa_render_samples = 16
    except AttributeError:
        pass
    world = bpy.data.worlds.new("W") if not bpy.data.worlds else bpy.data.worlds[0]
    sc.world = world
    wnt = world.node_tree
    bg = wnt.nodes.get("Background")
    bg.inputs[0].default_value = (s2l(0.91), s2l(0.93), s2l(0.95), 1.0)
    bg.inputs[1].default_value = 1.0
    # camera sees the pale backdrop; surfaces get only a dim ambient so the sun drives the bands
    amb = wnt.nodes.new("ShaderNodeBackground")
    amb.inputs[0].default_value = (1.0, 1.0, 1.0, 1.0)
    amb.inputs[1].default_value = 0.12
    lp = wnt.nodes.new("ShaderNodeLightPath")
    mix = wnt.nodes.new("ShaderNodeMixShader")
    wnt.links.new(lp.outputs["Is Camera Ray"], mix.inputs[0])
    wnt.links.new(amb.outputs[0], mix.inputs[1])
    wnt.links.new(bg.outputs[0], mix.inputs[2])
    wnt.links.new(mix.outputs[0], wnt.nodes["World Output"].inputs["Surface"])
    sc.render.use_freestyle = True
    sc.render.line_thickness_mode = "ABSOLUTE"
    sc.render.line_thickness = 1.3
    vl = sc.view_layers[0]
    vl.use_freestyle = True
    fs = vl.freestyle_settings
    fs.crease_angle = math.radians(120)
    ls = fs.linesets[0] if fs.linesets else fs.linesets.new("Lines")
    ls.select_by_visibility = True
    ls.select_silhouette = True
    ls.select_border = True
    ls.select_crease = False
    ls.linestyle.color = (s2l(INK[0] * 1.2), s2l(INK[1] * 1.2), s2l(INK[2] * 1.2))
    ls.linestyle.thickness = 1.3


def import_glb(path: str) -> list[bpy.types.Object]:
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    return [o for o in bpy.data.objects if o not in before]


def render_tile(name: str, entry: dict | None, out_png: str, args: argparse.Namespace) -> None:
    clear()
    objs = import_glb(os.path.join(PROPS_DIR, f"{name}.glb"))
    meshes = [o for o in objs if o.type == "MESH"]
    mats: dict[str, bpy.types.Material] = {}
    for o in meshes:
        ca = o.data.color_attributes[0].name if o.data.color_attributes else None
        for slot in o.material_slots:
            if slot.material is None:
                continue
            key = slot.material.name
            if key not in mats:
                mats[key] = cel_material(slot.material, ca)
            slot.material = mats[key]
    pts = [o.matrix_world @ Vector(c) for o in meshes for c in o.bound_box]
    mn = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    mx = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    center = (mn + mx) / 2
    # ground disc
    rad = max(mx.x - mn.x, mx.y - mn.y) * 0.62 + 0.2
    bpy.ops.mesh.primitive_cylinder_add(vertices=40, radius=rad, depth=0.02, location=(center.x, center.y, -0.011))
    disc = bpy.context.active_object
    gm = bpy.data.materials.new("ground_preview")
    nt = gm.node_tree
    nt.nodes.clear()
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (s2l(0.80), s2l(0.87), s2l(0.70), 1.0)
    o_ = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(em.outputs[0], o_.inputs["Surface"])
    disc.data.materials.append(gm)
    disc.hide_render = False
    # camera
    az, el = math.radians(args.azim), math.radians(args.elev)
    d = Vector((math.sin(az) * math.cos(el), math.cos(az) * math.cos(el), math.sin(el)))
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam = bpy.data.objects.new("cam", cam_data)
    bpy.context.scene.collection.objects.link(cam)
    dist = (mx - mn).length * 2 + 10
    cam.location = center + d * dist
    cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
    bpy.context.view_layer.update()
    inv = cam.matrix_world.inverted()
    cs = [inv @ p for p in pts]
    w = max(c.x for c in cs) - min(c.x for c in cs)
    h = max(c.y for c in cs) - min(c.y for c in cs)
    scale = max(w, h) * 1.18 + 0.1
    cam_data.ortho_scale = scale
    cx = (max(c.x for c in cs) + min(c.x for c in cs)) / 2
    cy = (max(c.y for c in cs) + min(c.y for c in cs)) / 2 + scale * 0.04
    cam.location = cam.matrix_world @ Vector((cx, cy, 0))
    cam_data.clip_end = dist * 3
    bpy.context.scene.camera = cam
    # sun
    sun_d = bpy.data.lights.new("sun", "SUN")
    sun_d.energy = 2.2
    sun_d.angle = math.radians(2)
    sun = bpy.data.objects.new("sun", sun_d)
    sun.rotation_euler = Vector((-0.55, 0.45, 0.7)).normalized().to_track_quat("Z", "Y").to_euler()
    bpy.context.scene.collection.objects.link(sun)
    # label
    tris = entry["tris"] if entry else 0
    size = entry["size"] if entry else [0, 0, 0]
    label = f"{name}  {tris}t  {size[1]:.1f}m"
    curve = bpy.data.curves.new("label", "FONT")
    curve.body = label
    curve.size = scale * 0.045
    try:
        curve.font = bpy.data.fonts.load("/System/Library/Fonts/Supplemental/Arial Bold.ttf", check_existing=True)
    except RuntimeError:
        pass
    txt = bpy.data.objects.new("label", curve)
    bpy.context.scene.collection.objects.link(txt)
    txt.parent = cam
    txt.location = (-scale * 0.47, -scale * 0.47, -1.0)
    lm = bpy.data.materials.new("label_ink")
    lnt = lm.node_tree
    lnt.nodes.clear()
    le = lnt.nodes.new("ShaderNodeEmission")
    le.inputs["Color"].default_value = (*[s2l(c) for c in INK], 1.0)
    lo = lnt.nodes.new("ShaderNodeOutputMaterial")
    lnt.links.new(le.outputs[0], lo.inputs["Surface"])
    curve.materials.append(lm)
    bpy.context.scene.render.filepath = out_png
    bpy.ops.render.render(write_still=True)


def _verge(i: int, length: float, road_half: float = 4.8) -> tuple[float, float, float]:
    """Deterministic scatter on both road verges (golden-ratio sequence), never on the road."""
    u = (i * 0.618034) % 1.0
    w = (i * 0.754878) % 1.0
    side = -1 if i % 2 else 1
    return (side * (road_half + w * 9.0), u * length, 0.0)


SCENES: dict[str, list[tuple[str, tuple[float, float, float], float]]] = {
    # (prop, (x, y, rot_z_deg)...) road runs along Blender Y through x=0
    "spring": [
        ("sakura_a", (-7, 6, 0), 0), ("sakura_b", (-12, 18, 0), 40), ("sakura_c", (8, 12, 0), 200),
        ("sakura_a", (11, 30, 0), 90), ("sakura_b", (-9, 34, 0), 10), ("sakura_c", (-16, 4, 0), 120),
        ("cedar_a", (-22, 30, 0), 0), ("cedar_b", (-26, 20, 0), 60), ("cedar_a", (20, 44, 0), 30),
        ("cedar_b", (26, 34, 0), 0), ("cedar_a", (-18, 48, 0), 0), ("pine_a", (15, 4, 0), 250),
        ("bamboo_clump", (18, 20, 0), 0), ("azalea", (-5, 1, 0), 0), ("azalea", (6, 22, 0), 90),
        ("bush_a", (5, 3, 0), 0), ("bush_b", (-6, 16, 0), 30), ("torii_small", (-6.5, 26, 0), 90),
        ("stone_lantern", (-5.5, 23.5, 0), 0), ("stone_lantern", (-5.5, 28.5, 0), 0),
        ("sign_curve_left", (5, 8, 0), 180), ("guardrail", (5.2, 16, 0), 90), ("guardrail", (5.2, 20, 0), 90),
        ("telephone_pole", (-5, 12, 0), 0), ("rock_e", (9, 1, 0), 30), ("rock_a", (-4.5, 8, 0), 0),
        ("jizo", (-4.8, 4, 0), -90), ("koinobori", (14, 14, 0), 0), ("farmhouse_a", (-15, 40, 0), 90),
        ("spectator_b", (4.5, 30, 0), 90), ("spectator_c", (4.8, 31.5, 0), 100), ("spectator_a", (5.2, 33, 0), 80),
        ("banner_fence", (4, 31.5, 0), 90), ("start_arch", (0, 40, 0), 0),
    ] + [("grass_tuft", _verge(i, 60), i * 40) for i in range(90)]
      + [("flowers_patch", _verge(i * 7 + 3, 40), i * 50) for i in range(40)],
    "autumn": [
        ("maple_red", (-7, 6, 0), 0), ("maple_orange", (-12, 18, 0), 40), ("maple_yellow", (8, 12, 0), 200),
        ("maple_red", (11, 30, 0), 90), ("maple_orange", (-9, 34, 0), 10), ("persimmon_tree", (-15, 4, 0), 120),
        ("cedar_a", (-22, 30, 0), 0), ("cedar_b", (-26, 20, 0), 60), ("cedar_a", (20, 44, 0), 30),
        ("cedar_b", (26, 34, 0), 0), ("pine_b", (15, 4, 0), 250), ("maple_yellow", (-19, 46, 0), 0),
        ("bamboo_clump", (18, 20, 0), 0), ("bush_a", (5, 3, 0), 0), ("bush_b", (-6, 16, 0), 30),
        ("hazagi", (13, 14, 0), 90), ("scarecrow", (10, 20, 0), 200), ("kura", (-15, 40, 0), 90),
        ("farmhouse_b", (18, 52, 0), 180), ("kei_truck", (-6, 22, 0), 10), ("vending_machine", (-5.2, 27, 0), -90),
        ("sign_curve_right", (5, 8, 0), 180), ("road_mirror", (-5, 12, 0), -90), ("rock_c", (9, 1, 0), 30),
        ("stump", (-4.5, 8, 0), 0), ("log", (7, 25, 0), 60), ("tire_stack", (4.5, 30, 0), 0),
        ("tire_stack", (4.5, 31, 0), 0), ("chevron_left", (6, 36, 0), 180), ("hay_bale_round", (-5, 32, 0), 30),
        ("spectator_d", (-4.8, 35, 0), -90), ("spectator_e", (-5, 36.5, 0), -80), ("spectator_f", (-4.8, 38, 0), -100),
        ("tent", (-8, 37, 0), 0), ("finish_arch", (0, 44, 0), 0),
    ] + [("grass_tuft", _verge(i, 60), i * 40) for i in range(90)]
      + [("fern", _verge(i * 5 + 1, 40, 5.5), i * 50) for i in range(12)],
}


def render_scene(which: str, out: str, args: argparse.Namespace) -> None:
    """Chase-cam-height diorama: judges readability at gameplay distance."""
    clear()
    cache: dict[str, list[bpy.types.Object]] = {}
    mats: dict[str, bpy.types.Material] = {}
    for name, (x, y, _), rz in SCENES[which]:
        if name not in cache:
            objs = import_glb(os.path.join(PROPS_DIR, f"{name}.glb"))
            for o in objs:
                if o.type == "MESH":
                    ca = o.data.color_attributes[0].name if o.data.color_attributes else None
                    for slot in o.material_slots:
                        if slot.material is not None:
                            key = slot.material.name
                            if key not in mats:
                                mats[key] = cel_material(slot.material, ca)
                            slot.material = mats[key]
            meshes = [o for o in objs if o.type == "MESH"]
            for o in objs:
                if o.type != "MESH":
                    bpy.data.objects.remove(o, do_unlink=True)
            cache[name] = meshes
            src = meshes[0]
            src.rotation_mode = "XYZ"
            src.location = (x, y, 0)
            src.rotation_euler = (0, 0, math.radians(rz))
            continue
        dup = bpy.data.objects.new(name, cache[name][0].data)
        bpy.context.scene.collection.objects.link(dup)
        dup.location = (x, y, 0)
        dup.rotation_euler = (0, 0, math.radians(rz))
    ground_col = {"spring": (0.64, 0.81, 0.45), "autumn": (0.78, 0.72, 0.42)}[which]
    for nm, size, loc, col in (("ground", (200, 200), (0, 40, -0.01), ground_col),
                               ("road", (9, 200), (0, 40, 0.0), (0.31, 0.34, 0.41))):
        bpy.ops.mesh.primitive_plane_add(size=1, location=loc)
        g = bpy.context.active_object
        g.scale = (size[0], size[1], 1)
        m = bpy.data.materials.new(nm)
        m.node_tree.nodes.clear()
        e = m.node_tree.nodes.new("ShaderNodeEmission")
        e.inputs["Color"].default_value = (*[s2l(c) for c in col], 1.0)
        o_ = m.node_tree.nodes.new("ShaderNodeOutputMaterial")
        m.node_tree.links.new(e.outputs[0], o_.inputs["Surface"])
        g.data.materials.append(m)
    sc = bpy.context.scene
    sc.render.resolution_x = 1600
    sc.render.resolution_y = 900
    sky = {"spring": (0.72, 0.84, 0.96), "autumn": (0.98, 0.86, 0.72)}[which]
    sc.world.node_tree.nodes["Background"].inputs[0].default_value = (*[s2l(c) for c in sky], 1.0)
    cam_data = bpy.data.cameras.new("cam")
    cam_data.lens = 28
    cam_data.clip_end = 400
    cam = bpy.data.objects.new("cam", cam_data)
    sc.collection.objects.link(cam)
    cam.location = (0.0, -9.0, 2.6)
    cam.rotation_euler = (math.radians(84), 0, 0)
    sc.camera = cam
    sun_d = bpy.data.lights.new("sun", "SUN")
    sun_d.energy = 2.2
    sun = bpy.data.objects.new("sun", sun_d)
    sun.rotation_euler = Vector((-0.5, -0.6, 0.62)).normalized().to_track_quat("Z", "Y").to_euler()
    sc.collection.objects.link(sun)
    sc.render.filepath = os.path.abspath(out)
    bpy.ops.render.render(write_still=True)
    print(f"SCENE {out}")


def main() -> None:
    args = parse()
    if args.scene:
        setup_render(args.tile)
        render_scene(args.scene, args.out, args)
        return
    with open(os.path.join(PROPS_DIR, "manifest.json")) as f:
        manifest = {p["name"]: p for p in json.load(f)["props"]}
    if args.category:
        names = [n for n, p in manifest.items() if p["category"] in args.category.split(",")]
    else:
        names = [n for n in args.names.split(",") if n]
    setup_render(args.tile)
    tmp = tempfile.mkdtemp(prefix="props_gallery_")
    for i, n in enumerate(names):
        render_tile(n, manifest.get(n), os.path.join(tmp, f"tile_{i:03d}.png"), args)
    cols = min(args.cols, len(names))
    rows = math.ceil(len(names) / cols)
    out = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-framerate", "1", "-i",
                    os.path.join(tmp, "tile_%03d.png"), "-vf",
                    f"tile={cols}x{rows}:padding=4:margin=4:color=0xd8d4e4", "-frames:v", "1",
                    "-update", "1", out], check=True)
    shutil.rmtree(tmp)
    print(f"GALLERY {out} ({len(names)} props)")


main()
