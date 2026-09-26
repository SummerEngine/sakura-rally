"""Stylized low-poly spectators (~1.7 m adults, one child). Front = +Y (facing the road)."""
from __future__ import annotations

from dataclasses import dataclass, field

from mathutils import Vector

from .common import Kit, bm_ico, lerp_col, trs
from .registry import cyl, prop

SKIN_SHADE = lambda co, n: lerp_col((0.86, 0.82, 0.9), (1, 1, 1), n.z * 0.5 + 0.6)
CLOTH_SHADE = lambda co, n: lerp_col((0.8, 0.78, 0.9), (1, 1, 1), n.z * 0.5 + 0.6)


@dataclass
class Outfit:
    top: str
    pants: str
    shoes: str = "Cloth_White"
    skin: str = "Skin"
    hair: str = "Hair_Black"
    hat: str | None = None          # material of a cap / sun hat
    hat_kind: str = "cap"           # cap | sunhat | none
    hair_kind: str = "short"        # short | bob | ponytail
    sleeves: str | None = None      # arm material (defaults to top)
    scarf: str | None = None


@dataclass
class Pose:
    # points in metres at scale 1 (adult 1.7 m)
    arm_l: list[tuple[float, float, float]] = field(default_factory=lambda: [(0.3, 0.02, 1.08), (0.33, 0.04, 0.84)])
    arm_r: list[tuple[float, float, float]] = field(default_factory=lambda: [(-0.3, 0.02, 1.08), (-0.33, 0.04, 0.84)])
    leg_l: list[tuple[float, float, float]] = field(default_factory=lambda: [(0.11, 0.0, 0.45), (0.12, 0.0, 0.07)])
    leg_r: list[tuple[float, float, float]] = field(default_factory=lambda: [(-0.11, 0.0, 0.45), (-0.12, 0.0, 0.07)])
    hip_z: float = 0.86
    torso_lean: float = 0.0          # forward offset (y) of the shoulders
    head_turn: float = 0.0


def person(kit: Kit, o: Outfit, p: Pose, s: float = 1.0, head_scale: float = 1.0) -> dict[str, Vector]:
    """Build one figure; returns key points (hands, head) for accessories."""
    S = lambda x, y, z: Vector((x * s, y * s, z * s))
    sleeve = o.sleeves or o.top
    hip = p.hip_z
    sh_z = hip + 0.56
    lean = p.torso_lean
    # legs (pants) + shoes
    for side, pts in ((1, p.leg_l), (-1, p.leg_r)):
        chain = [S(side * 0.1, 0.0, hip)] + [S(*q) for q in pts]
        kit.tube(o.pants, chain, [0.1 * s, 0.085 * s, 0.065 * s], 5, cap_start=False, cap_end=True, color=CLOTH_SHADE)
        ank = chain[-1]
        kit.cbox(o.shoes, (0.13 * s, 0.24 * s, 0.09 * s), ank + S(0, 0.05, -0.03), color=CLOTH_SHADE)
    # torso: hull from hips to shoulders
    tpts = []
    for (w, d, z, y) in ((0.17, 0.11, hip - 0.04, 0.0), (0.16, 0.12, hip + 0.22, lean * 0.4),
                         (0.21, 0.12, sh_z - 0.06, lean), (0.15, 0.1, sh_z + 0.02, lean)):
        for sx in (-1, 1):
            for sy in (-1, 1):
                tpts.append(S(sx * w, y + sy * d, z))
    kit.hull(o.top, tpts, None, CLOTH_SHADE)
    if o.scarf:
        kit.cyl(o.scarf, 0.1 * s, 0.07 * s, S(0, lean, sh_z - 0.01), seg=6, r_top=0.08 * s, color=CLOTH_SHADE)
    # neck + head
    kit.cyl(o.skin, 0.05 * s, 0.1 * s, S(0, lean, sh_z), seg=5)
    hz = sh_z + 0.19 * head_scale
    hc = S(0, lean + 0.01, hz)
    hs = s * head_scale
    kit.add(bm_ico(2, 0.125 * hs), o.skin, trs(hc, (0, 0, p.head_turn), (1.0, 0.96, 1.08)), SKIN_SHADE)
    fwd = Vector((0, 1, 0))
    for sx in (-1, 1):  # eyes
        kit.cbox("Ink", (0.022 * hs, 0.012 * hs, 0.034 * hs), hc + Vector((sx * 0.045 * hs, 0.118 * hs, 0.005 * hs)))
    # hair
    hair_c = hc + Vector((0, -0.032 * hs, 0.04 * hs))  # pushed back/up so the face stays clear
    if o.hair_kind == "bob":
        kit.add(bm_ico(1, 0.14 * hs), o.hair, trs(hair_c + Vector((0, -0.02 * hs, -0.02 * hs)), (0, 0, 0), (1.0, 0.95, 1.02)))
        kit.cbox(o.hair, (0.26 * hs, 0.1 * hs, 0.14 * hs), hc + Vector((0, -0.06 * hs, -0.06 * hs)))
    else:
        kit.add(bm_ico(1, 0.132 * hs), o.hair, trs(hair_c, (0, 0, 0), (1.0, 0.96, 0.95)))
    if o.hair_kind == "ponytail":
        kit.tube(o.hair, [hc + Vector((0, -0.12 * hs, 0.06 * hs)), hc + Vector((0, -0.19 * hs, -0.02 * hs)),
                          hc + Vector((0, -0.2 * hs, -0.15 * hs))], [0.045 * hs, 0.04 * hs, 0.0], 4)
    top_z = hc.z + 0.135 * hs
    if o.hat and o.hat_kind == "cap":
        kit.cyl(o.hat, 0.135 * hs, 0.07 * hs, Vector((hc.x, hc.y - 0.005 * hs, top_z - 0.06 * hs)), seg=7,
                r_top=0.1 * hs, color=CLOTH_SHADE)
        kit.cbox(o.hat, (0.18 * hs, 0.13 * hs, 0.02 * hs), Vector((hc.x, hc.y + 0.15 * hs, top_z - 0.06 * hs)),
                 (-8, 0, 0))
    elif o.hat and o.hat_kind == "sunhat":
        kit.cyl(o.hat, 0.27 * hs, 0.025 * hs, Vector((hc.x, hc.y, top_z - 0.07 * hs)), seg=9, r_top=0.23 * hs)
        kit.cyl(o.hat, 0.13 * hs, 0.1 * hs, Vector((hc.x, hc.y, top_z - 0.05 * hs)), seg=7, r_top=0.11 * hs)
        kit.cyl("Red", 0.132 * hs, 0.03 * hs, Vector((hc.x, hc.y, top_z - 0.045 * hs)), seg=7, cap_bot=False, cap_top=False)
    # arms + hands
    hands = {}
    for side, pts, key in ((1, p.arm_l, "hand_l"), (-1, p.arm_r, "hand_r")):
        sh = S(side * 0.21, lean, sh_z - 0.05)
        chain = [sh] + [S(*q) for q in pts]
        kit.tube(sleeve, chain, [0.065 * s, 0.055 * s, 0.047 * s], 5, cap_start=True, cap_end=True, color=CLOTH_SHADE)
        hand = chain[-1] + (chain[-1] - chain[-2]).normalized() * 0.045 * s
        kit.add(bm_ico(1, 0.052 * s), o.skin, trs(hand), SKIN_SHADE)
        hands[key] = hand
    hands["head"] = hc
    return hands


def small_flag(kit: Kit, hand: Vector, mat: str, up: Vector = Vector((0, 0.1, 1)), s: float = 1.0) -> None:
    top = hand + up.normalized() * 0.6 * s
    kit.cyl_between("Wood_Pale", hand - up.normalized() * 0.05, top, 0.01 * s, seg=4)
    q = [top, top - up.normalized() * 0.28 * s, top - up.normalized() * 0.26 * s + Vector((0.4 * s, 0.02, 0)),
         top + Vector((0.42 * s, 0.03, 0))]
    kit.poly(mat, q, [(0, 1, 2, 3)])
    kit.poly(mat, q, [(3, 2, 1, 0)])
    kit.flower("White", trs((top + q[2]) / 2 + Vector((0.02, 0.035, 0.0)), (90, 0, 180)), 0.06 * s)


@prop("spectator_a", "spectator", ["spectator_zone", "roadside"], ["spring", "autumn"], cyl(0.25))
def spectator_a(kit: Kit) -> None:
    """Standing, relaxed, cap + windbreaker."""
    person(kit, Outfit("Cloth_Blue", "Cloth_Denim", hat="Cloth_Red", hair="Hair_Brown", sleeves="Cloth_Blue",
                       scarf="Cloth_White"),
           Pose(arm_l=[(0.26, 0.05, 1.1), (0.2, 0.18, 0.95)], arm_r=[(-0.3, 0.0, 1.08), (-0.32, 0.03, 0.83)]))


@prop("spectator_b", "spectator", ["spectator_zone", "roadside"], ["spring", "autumn"], cyl(0.3))
def spectator_b(kit: Kit) -> None:
    """Cheering, both arms up."""
    person(kit, Outfit("Cloth_Yellow", "Cloth_Navy", shoes="Cloth_Red", hair="Hair_Black", hair_kind="short"),
           Pose(arm_l=[(0.38, 0.05, 1.58), (0.46, 0.08, 1.86)], arm_r=[(-0.38, 0.05, 1.58), (-0.46, 0.08, 1.86)]))


@prop("spectator_c", "spectator", ["spectator_zone", "roadside"], ["spring", "autumn"], cyl(0.3))
def spectator_c(kit: Kit) -> None:
    """Waving a sakura flag."""
    pts = person(kit, Outfit("Cloth_Pink", "Cloth_White", shoes="Cloth_Navy", hair="Hair_Black", hair_kind="ponytail"),
                 Pose(arm_l=[(0.34, 0.08, 1.38), (0.36, 0.12, 1.66)], arm_r=[(-0.28, 0.06, 1.06), (-0.22, 0.2, 0.92)]))
    small_flag(kit, pts["hand_l"], "Vermilion", Vector((0.25, 0.05, 1)))


@prop("spectator_d", "spectator", ["spectator_zone", "roadside"], ["spring", "autumn"], cyl(0.25))
def spectator_d(kit: Kit) -> None:
    """Photographer: camera raised to the face."""
    pts = person(kit, Outfit("Cloth_Green", "Cloth_Khaki", shoes="Cloth_Black", hair="Hair_Grey", hat="Cloth_Khaki",
                             hat_kind="sunhat"),
                 Pose(arm_l=[(0.2, 0.2, 1.22), (0.08, 0.3, 1.46)], arm_r=[(-0.2, 0.2, 1.22), (-0.08, 0.3, 1.46)],
                      torso_lean=0.02))
    c = (pts["hand_l"] + pts["hand_r"]) / 2 + Vector((0, 0.02, 0.02))
    kit.cbox("Metal_Dark", (0.2, 0.1, 0.12), c)
    kit.cyl("Ink", 0.045, 0.1, c + Vector((0, 0.04, 0)), (-90, 0, 0), seg=6)
    kit.cyl("Glass", 0.03, 0.01, c + Vector((0, 0.14, 0)), (-90, 0, 0), seg=6)


@prop("spectator_e", "spectator", ["spectator_zone", "roadside"], ["spring", "autumn"], cyl(0.3))
def spectator_e(kit: Kit) -> None:
    """Crouching fan, elbows on knees."""
    person(kit, Outfit("Cloth_Orange", "Cloth_Black", shoes="Cloth_White", hair="Hair_Black", hat="Cloth_Navy",
                       hair_kind="short"),
           Pose(hip_z=0.46, torso_lean=0.12,
                leg_l=[(0.16, 0.36, 0.5), (0.15, 0.1, 0.07)], leg_r=[(-0.16, 0.36, 0.5), (-0.15, 0.1, 0.07)],
                arm_l=[(0.2, 0.32, 0.72), (0.08, 0.44, 0.78)], arm_r=[(-0.2, 0.32, 0.72), (-0.08, 0.44, 0.78)]))


@prop("spectator_f", "spectator", ["spectator_zone", "roadside"], ["spring", "autumn"], cyl(0.2))
def spectator_f(kit: Kit) -> None:
    """Child (1.15 m) waving, yellow school hat, red backpack."""
    s = 0.68
    pts = person(kit, Outfit("Cloth_Teal", "Cloth_Navy", shoes="Cloth_Pink", hair="Hair_Black", hair_kind="bob",
                             hat="Cloth_Yellow", hat_kind="sunhat"),
                 Pose(arm_l=[(0.36, 0.06, 1.4), (0.42, 0.1, 1.68)], arm_r=[(-0.3, 0.02, 1.06), (-0.33, 0.06, 0.82)]),
                 s=s, head_scale=1.28)
    kit.cbox("Red", (0.28 * s, 0.14 * s, 0.34 * s), Vector((0, -0.2 * s, 1.18 * s)))
    kit.cbox("Red_Dark", (0.26 * s, 0.02 * s, 0.14 * s), Vector((0, -0.28 * s, 1.1 * s)))
