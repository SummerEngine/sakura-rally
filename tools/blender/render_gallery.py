"""Render a labelled contact sheet of exported prop GLBs with a cel-shaded preview look.

Usage (from the repo root):
  /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
      --python tools/blender/render_gallery.py -- --names sakura_a,sakura_b \
      --out docs/renders/props_trees.png [--cols 5] [--tile 480] [--scale-ref]

--category <cat> picks every manifest entry of that category instead of --names.
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


def main() -> None:
    args = parse()
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
