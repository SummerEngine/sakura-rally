"""Binary mesh pack written by the map compiler and read by scripts/world/map_loader.gd.

Layout: one little-endian blob per map (`<name>.bin`). Every mesh is a block of
arrays in a fixed order - positions (f32 x3), normals (f32 x3), colours (f32 x4),
uv (f32 x2), indices (u32) - each present only when listed in `attrs`. A JSON
descriptor per mesh records the byte offset, counts, material key, collision
kind and surface. Raw data blocks (grids) use the same blob with `kind: "raw"`.
"""
from __future__ import annotations

import numpy as np


def vertex_normals(pos: np.ndarray, idx: np.ndarray) -> np.ndarray:
    tri = idx.reshape(-1, 3)
    a, b, c = pos[tri[:, 0]], pos[tri[:, 1]], pos[tri[:, 2]]
    # Godot front faces are clockwise when seen from the front, so the outward
    # normal of (a, b, c) is (c - a) x (b - a).
    fn = np.cross(c - a, b - a)
    n = np.zeros_like(pos)
    for k in range(3):
        np.add.at(n, tri[:, k], fn)
    ln = np.linalg.norm(n, axis=1, keepdims=True)
    n /= np.maximum(ln, 1e-12)
    n[ln[:, 0] < 1e-12] = (0.0, 1.0, 0.0)
    return n


class MeshPack:
    def __init__(self) -> None:
        self.buf = bytearray()
        self.meshes: list[dict] = []
        self.raw: list[dict] = []

    def _append(self, arr: np.ndarray, dtype) -> None:
        self.buf += np.ascontiguousarray(arr, dtype=dtype).tobytes()

    def add(self, name: str, pos: np.ndarray, idx: np.ndarray, *, material: str,
            nrm: np.ndarray | None = None, col: np.ndarray | None = None,
            uv: np.ndarray | None = None, collide: str = "none", surface: str | None = None,
            boxes: list | None = None, smooth_normals: bool = True, **extra) -> dict:
        pos = np.asarray(pos, dtype=np.float64).reshape(-1, 3)
        idx = np.asarray(idx, dtype=np.int64).ravel()
        if len(idx) == 0 or len(pos) == 0:
            return {}
        assert idx.max() < len(pos), name
        if nrm is None and smooth_normals:
            nrm = vertex_normals(pos, idx)
        attrs = ["pos"]
        offset = len(self.buf)
        self._append(pos, "<f4")
        if nrm is not None:
            attrs.append("nrm")
            self._append(np.asarray(nrm).reshape(-1, 3), "<f4")
        if col is not None:
            attrs.append("col")
            c = np.asarray(col, dtype=np.float64).reshape(len(pos), -1)
            if c.shape[1] == 3:
                c = np.hstack([c, np.ones((len(pos), 1))])
            self._append(c, "<f4")
        if uv is not None:
            attrs.append("uv")
            self._append(np.asarray(uv).reshape(-1, 2), "<f4")
        attrs.append("idx")
        self._append(idx, "<u4")
        mn = pos.min(axis=0)
        mx = pos.max(axis=0)
        d = {
            "name": name, "material": material, "offset": offset, "vcount": int(len(pos)),
            "icount": int(len(idx)), "attrs": attrs, "collide": collide,
            "aabb": [round(float(v), 3) for v in (*mn, *(mx - mn))],
        }
        if surface:
            d["surface"] = surface
        if boxes:
            d["boxes"] = boxes
        d.update(extra)
        self.meshes.append(d)
        return d

    def add_raw(self, name: str, data: np.ndarray, dtype: str, **meta) -> dict:
        offset = len(self.buf)
        self._append(data, dtype)
        d = {"name": name, "kind": "raw", "offset": offset, "bytes": len(self.buf) - offset,
             "dtype": dtype, "shape": list(np.shape(data))}
        d.update(meta)
        self.raw.append(d)
        return d

    def save(self, path: str) -> None:
        with open(path, "wb") as f:
            f.write(bytes(self.buf))


class MeshBuilder:
    """Accumulates small procedural meshes (posts, rails, bridge parts) into one batch."""

    def __init__(self) -> None:
        self.pos: list[np.ndarray] = []
        self.col: list[np.ndarray] = []
        self.idx: list[np.ndarray] = []
        self.n = 0

    def add(self, pos: np.ndarray, idx: np.ndarray, color) -> None:
        pos = np.asarray(pos, dtype=np.float64).reshape(-1, 3)
        c = np.asarray(color, dtype=np.float64)
        col = np.broadcast_to(c if c.ndim == 2 else c[None, :], (len(pos), len(c) if c.ndim == 1 else c.shape[1]))
        self.pos.append(pos)
        self.col.append(np.array(col))
        self.idx.append(np.asarray(idx, dtype=np.int64) + self.n)
        self.n += len(pos)

    def box(self, center, size, yaw: float, color, pitch: float = 0.0, roll: float = 0.0) -> None:
        """Axis box with flat-shaded faces (24 vertices) rotated by yaw (around +Y)."""
        hx, hy, hz = np.asarray(size, dtype=np.float64) / 2.0
        corners = np.array([[sx * hx, sy * hy, sz * hz] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)])
        rot = rotation(yaw, pitch, roll)
        pts = corners @ rot.T + np.asarray(center, dtype=np.float64)
        # corner index = (sx>0)*4 + (sy>0)*2 + (sz>0)
        faces = [
            (4, 6, 7, 5),  # +x
            (0, 1, 3, 2),  # -x
            (2, 3, 7, 6),  # +y
            (0, 4, 5, 1),  # -y
            (1, 5, 7, 3),  # +z
            (0, 2, 6, 4),  # -z
        ]
        pos = []
        idx = []
        for f in faces:
            base = len(pos)
            pos.extend(pts[list(f)[::-1]])  # listed CCW; Godot front faces are CW
            idx.extend([base, base + 1, base + 2, base, base + 2, base + 3])
        self.add(np.array(pos), np.array(idx), color)

    def prism(self, a, b, radius: float, sides: int, color, cap: bool = True) -> None:
        """Faceted cylinder from point a to point b."""
        a = np.asarray(a, dtype=np.float64)
        b = np.asarray(b, dtype=np.float64)
        axis = b - a
        L = np.linalg.norm(axis)
        if L < 1e-6:
            return
        w = axis / L
        up = np.array([0.0, 1.0, 0.0]) if abs(w[1]) < 0.9 else np.array([1.0, 0.0, 0.0])
        u = np.cross(w, up)
        u /= np.linalg.norm(u)
        v = np.cross(u, w)
        ang = np.linspace(0, 2 * np.pi, sides, endpoint=False)
        ring = np.cos(ang)[:, None] * u + np.sin(ang)[:, None] * v
        pos = []
        idx = []
        for i in range(sides):
            j = (i + 1) % sides
            base = len(pos)
            pos.extend([a + ring[i] * radius, a + ring[j] * radius, b + ring[j] * radius, b + ring[i] * radius])
            idx.extend([base, base + 1, base + 2, base, base + 2, base + 3])
        if cap:
            for end, sign in ((b, 1), (a, -1)):
                base = len(pos)
                pos.append(end)
                for i in range(sides):
                    pos.append(end + ring[i] * radius)
                for i in range(sides):
                    j = (i + 1) % sides
                    if sign > 0:
                        idx.extend([base, base + 1 + i, base + 1 + j])
                    else:
                        idx.extend([base, base + 1 + j, base + 1 + i])
        self.add(np.array(pos), np.array(idx), color)

    def arrays(self) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        if not self.pos:
            return np.zeros((0, 3)), np.zeros((0, 4)), np.zeros(0, dtype=np.int64)
        return np.vstack(self.pos), np.vstack(self.col), np.concatenate(self.idx)

    def flat(self) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
        """Unshared vertices with face normals (crisp low-poly shading)."""
        pos, col, idx = self.arrays()
        if len(idx) == 0:
            return pos, np.zeros((0, 3)), col, idx
        p = pos[idx]
        c = col[idx]
        tri = p.reshape(-1, 3, 3)
        fn = np.cross(tri[:, 2] - tri[:, 0], tri[:, 1] - tri[:, 0])
        fn /= np.maximum(np.linalg.norm(fn, axis=1, keepdims=True), 1e-12)
        n = np.repeat(fn, 3, axis=0)
        return p, n, c, np.arange(len(p))


def rotation(yaw: float, pitch: float = 0.0, roll: float = 0.0) -> np.ndarray:
    """Rotation matrix: roll around Z, then pitch around X, then yaw around Y (Godot YXZ)."""
    cy, sy = np.cos(yaw), np.sin(yaw)
    cp, sp = np.cos(pitch), np.sin(pitch)
    cr, sr = np.cos(roll), np.sin(roll)
    ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
    rz = np.array([[cr, -sr, 0], [sr, cr, 0], [0, 0, 1]])
    return ry @ rx @ rz
