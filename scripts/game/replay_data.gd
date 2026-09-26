class_name ReplayData
extends RefCounted
## A replay file read back (format: ReplayFormat, docs/REPLAYS.md): the header, the frames as
## one contiguous buffer, and the events. Answers frame fields by index and the car and camera
## pose at any time (interpolated between the 60 Hz frames).

const F := preload("res://scripts/game/replay_format.gd")

var path: String = ""
var header: Dictionary = {}
## Every frame's FRAME_SIZE bytes back to back (frame i at i * FRAME_SIZE).
var frames: PackedByteArray
var count: int = 0
## {t: float, type: String, ...} in recording order.
var events: Array[Dictionary] = []
## Wheel surface ids -> names (header "surfaces" plus "surface" events).
var surfaces: PackedStringArray = []
## Camera ids -> {name, mode} ("camera" events).
var cameras: Array[Dictionary] = []
## False when the file ends without its "end" event (the game quit hard or crashed).
var complete: bool = false
var error: String = ""
var _times: PackedFloat32Array


## Reads a replay file; check `error` (empty when it read).
static func load_file(file_path: String) -> ReplayData:
	var r := ReplayData.new()
	r.path = file_path
	var bytes := FileAccess.get_file_as_bytes(file_path)
	if bytes.size() < 12 or bytes.slice(0, 4).get_string_from_ascii() != F.MAGIC:
		r.error = "not a replay file"
		return r
	var version := bytes.decode_u16(4)
	if version != F.VERSION:
		r.error = "replay format %d, this build reads %d" % [version, F.VERSION]
		return r
	var hlen := bytes.decode_u32(8)
	var parsed: Variant = JSON.parse_string(bytes.slice(12, 12 + hlen).get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		r.error = "bad header"
		return r
	r.header = parsed
	for s in r.header.get("surfaces", []):
		r.surfaces.append(str(s))
	var at := 12 + hlen
	while at + 8 <= bytes.size():
		var raw_len := bytes.decode_u32(at)
		var comp_len := bytes.decode_u32(at + 4)
		if at + 8 + comp_len > bytes.size():
			break
		r._add_block(bytes.slice(at + 8, at + 8 + comp_len).decompress(raw_len, FileAccess.COMPRESSION_ZSTD))
		at += 8 + comp_len
	r._index()
	return r


## The header and the events of the last block only (for listings: the "end" event and, for a
## finished stage, usually "finish"), without decompressing the whole file:
## {header, events, bytes, error}.
static func peek(file_path: String) -> Dictionary:
	var out := {"header": {}, "events": [], "bytes": 0, "error": ""}
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		out["error"] = "cannot open"
		return out
	out["bytes"] = f.get_length()
	if f.get_length() < 12 or f.get_buffer(4).get_string_from_ascii() != F.MAGIC or f.get_16() != F.VERSION:
		out["error"] = "not a replay file of this version"
		return out
	f.get_16()
	var parsed: Variant = JSON.parse_string(f.get_buffer(f.get_32()).get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		out["error"] = "bad header"
		return out
	out["header"] = parsed
	var last := -1
	while f.get_position() + 8 <= f.get_length():
		var at := f.get_position()
		f.get_32()
		var comp_len := f.get_32()
		if at + 8 + comp_len > f.get_length():
			break
		last = at
		f.seek(at + 8 + comp_len)
	if last >= 0:
		f.seek(last)
		var raw_len := f.get_32()
		var comp_len := f.get_32()
		var raw := f.get_buffer(comp_len).decompress(raw_len, FileAccess.COMPRESSION_ZSTD)
		var r := ReplayData.new()
		r._add_events(raw, F.block_events_at(raw))
		out["events"] = r.events
	return out


func _add_block(raw: PackedByteArray) -> void:
	if raw.size() < 4 or F.block_events_at(raw) > raw.size():
		return
	frames.append_array(F.block_frames(raw))
	_add_events(raw, F.block_events_at(raw))


func _add_events(raw: PackedByteArray, at: int) -> void:
	while at + 6 <= raw.size():
		var t := raw.decode_float(at)
		var elen := raw.decode_u16(at + 4)
		var e: Variant = JSON.parse_string(raw.slice(at + 6, at + 6 + elen).get_string_from_utf8())
		at += 6 + elen
		if typeof(e) != TYPE_DICTIONARY:
			continue
		e["t"] = t
		events.append(e)
		match str(e.get("type", "")):
			"surface":
				while surfaces.size() <= int(e["id"]):
					surfaces.append("")
				surfaces[int(e["id"])] = str(e["name"])
			"camera":
				while cameras.size() <= int(e["id"]):
					cameras.append({})
				cameras[int(e["id"])] = e
			"end":
				complete = true


func _index() -> void:
	count = frames.size() / F.FRAME_SIZE
	_times.resize(count)
	for i in count:
		_times[i] = frames.decode_float(i * F.FRAME_SIZE)


func duration() -> float:
	return _times[count - 1] if count > 0 else 0.0


func time(i: int) -> float:
	return _times[i]


## Index of the last frame at or before t (0 before the first).
func index_at(t: float) -> int:
	return clampi(_times.bsearch(t, false) - 1, 0, maxi(count - 1, 0))


func pos(i: int) -> Vector3:
	return F.vec3_f32(frames, i * F.FRAME_SIZE + F.O_POS)


func rot(i: int) -> Quaternion:
	return F.quat_decode(frames, i * F.FRAME_SIZE + F.O_ROT)


func velocity(i: int) -> Vector3:
	return F.vec3_f16(frames, i * F.FRAME_SIZE + F.O_LIN)


func kmh(i: int) -> float:
	return frames.decode_half(i * F.FRAME_SIZE + F.O_KMH)


func route_s(i: int) -> float:
	return frames.decode_float(i * F.FRAME_SIZE + F.O_S)


func lateral(i: int) -> float:
	return frames.decode_half(i * F.FRAME_SIZE + F.O_LAT)


func half_width(i: int) -> float:
	return frames[i * F.FRAME_SIZE + F.O_HALF] / 10.0


func buttons(i: int) -> int:
	return frames.decode_u16(i * F.FRAME_SIZE + F.O_BUTTONS)


func flags(i: int) -> int:
	return frames.decode_u16(i * F.FRAME_SIZE + F.O_FLAGS)


func state_name(i: int) -> String:
	var names: Array = header.get("states", [])
	var s := frames[i * F.FRAME_SIZE + F.O_STATE]
	return str(names[s]) if s < names.size() else str(s)


## Every field of frame i, decoded.
func frame(i: int) -> Dictionary:
	var o := i * F.FRAME_SIZE
	var b := frames
	var wheels: Array[Dictionary] = []
	for w in 4:
		var wo := o + F.O_WHEELS + w * F.WHEEL_SIZE
		var sid := b[wo + F.W_SURFACE]
		wheels.append({
			"contact": sid > 0,
			"surface": surfaces[sid - 1] if sid > 0 and sid - 1 < surfaces.size() else "none",
			"compression": b[wo + F.W_COMPRESSION] / 255.0,
			"spin_angle": b.decode_u16(wo + F.W_SPIN_ANGLE) / 65536.0 * TAU,
			"spin_speed": b.decode_half(wo + F.W_SPIN_SPEED),
			"steer_angle": b.decode_half(wo + F.W_STEER),
			"offset_y": b.decode_half(wo + F.W_OFFSET),
		})
	var cam := b[o + F.O_CAMERA]
	return {
		"t": b.decode_float(o + F.O_T),
		"buttons": b.decode_u16(o + F.O_BUTTONS),
		"flags": b.decode_u16(o + F.O_FLAGS),
		"state": state_name(i),
		"gear": b.decode_s8(o + F.O_GEAR),
		"input_steer": b.decode_s8(o + F.O_IN_STEER) / 127.0,
		"input_throttle": b[o + F.O_IN_THROTTLE] / 255.0,
		"input_brake": b[o + F.O_IN_BRAKE] / 255.0,
		"steer": b.decode_s8(o + F.O_STEER) / 127.0,
		"handbrake": b[o + F.O_HANDBRAKE] / 255.0,
		"grounded": b[o + F.O_GROUNDED],
		"pos": F.vec3_f32(b, o + F.O_POS),
		"rot": F.quat_decode(b, o + F.O_ROT),
		"lin": F.vec3_f16(b, o + F.O_LIN),
		"ang": F.vec3_f16(b, o + F.O_ANG),
		"rpm": b.decode_u16(o + F.O_RPM),
		"kmh": b.decode_half(o + F.O_KMH),
		"slip": b.decode_half(o + F.O_SLIP),
		"wheels": wheels,
		"s": b.decode_float(o + F.O_S),
		"lat": b.decode_half(o + F.O_LAT),
		"half_width": b[o + F.O_HALF] / 10.0,
		"checkpoint": b[o + F.O_CHECKPOINT],
		"camera": cameras[cam] if cam < cameras.size() else {},
		"elapsed": b.decode_float(o + F.O_ELAPSED),
		"cam_pos": F.vec3_f32(b, o + F.O_POS) + F.vec3_f16(b, o + F.O_CAM_POS),
		"cam_rot": F.quat_decode(b, o + F.O_CAM_ROT),
		"cam_fov": b.decode_half(o + F.O_CAM_FOV),
		"cam_t": b.decode_float(o + F.O_T) + b.decode_half(o + F.O_CAM_DT),
	}


## The car at time t: {xform, lin, kmh, steer_angles, spin_angles, offsets, grounded, contacts,
## roughness_hint}, interpolated between the frames around t (spin angles advanced by the
## wheel speed, so a wheel keeps turning between frames).
func car_at(t: float) -> Dictionary:
	var i := index_at(t)
	var j := mini(i + 1, count - 1)
	var t0 := _times[i]
	var t1 := _times[j]
	var k := clampf((t - t0) / (t1 - t0), 0.0, 1.0) if t1 > t0 else 0.0
	var p0 := pos(i)
	var p1 := pos(j)
	# A reset between the two frames: no sliding across the map.
	if p0.distance_to(p1) > 6.0:
		k = 0.0 if k < 0.5 else 1.0
	var q := rot(i).slerp(rot(j), k)
	var oi := i * F.FRAME_SIZE
	var oj := j * F.FRAME_SIZE
	var steer := PackedFloat32Array()
	var spin := PackedFloat32Array()
	var offset := PackedFloat32Array()
	var contact: Array[bool] = []
	for w in 4:
		var wi := oi + F.O_WHEELS + w * F.WHEEL_SIZE
		var wj := oj + F.O_WHEELS + w * F.WHEEL_SIZE
		steer.append(lerpf(frames.decode_half(wi + F.W_STEER), frames.decode_half(wj + F.W_STEER), k))
		offset.append(lerpf(frames.decode_half(wi + F.W_OFFSET), frames.decode_half(wj + F.W_OFFSET), k))
		var a0 := frames.decode_u16(wi + F.W_SPIN_ANGLE) / 65536.0 * TAU
		spin.append(wrapf(a0 + frames.decode_half(wi + F.W_SPIN_SPEED) * (t - t0), 0.0, TAU))
		contact.append(frames[wi + F.W_SURFACE] > 0)
	return {
		"xform": Transform3D(Basis(q), p0.lerp(p1, k)),
		"lin": velocity(i).lerp(velocity(j), k),
		"kmh": lerpf(kmh(i), kmh(j), k),
		"steer_angles": steer,
		"spin_angles": spin,
		"offsets": offset,
		"contacts": contact,
		"grounded": frames[oi + F.O_GROUNDED],
		"input_throttle": frames[oi + F.O_IN_THROTTLE] / 255.0,
		"input_brake": frames[oi + F.O_IN_BRAKE] / 255.0,
		"launch_hold": flags(i) & F.F_LAUNCH_HOLD != 0,
	}


## What the player saw at time t: {xform, fov}, interpolated between the camera samples
## (each frame carries the camera of the last frame rendered before it, stamped with its time).
func camera_at(t: float) -> Dictionary:
	var i := index_at(t)
	# Camera sample times lag their frame times a little; pick the pair around t.
	while i > 0 and _cam_t(i) > t:
		i -= 1
	while i + 1 < count and _cam_t(i + 1) <= t:
		i += 1
	var j := mini(i + 1, count - 1)
	var c0 := _cam_t(i)
	var c1 := _cam_t(j)
	var k := clampf((t - c0) / (c1 - c0), 0.0, 1.0) if c1 > c0 else 0.0
	var oi := i * F.FRAME_SIZE
	var oj := j * F.FRAME_SIZE
	var p0 := F.vec3_f32(frames, oi + F.O_POS) + F.vec3_f16(frames, oi + F.O_CAM_POS)
	var p1 := F.vec3_f32(frames, oj + F.O_POS) + F.vec3_f16(frames, oj + F.O_CAM_POS)
	if p0.distance_to(p1) > 15.0:
		k = 0.0 if k < 0.5 else 1.0
	var q := F.quat_decode(frames, oi + F.O_CAM_ROT).slerp(F.quat_decode(frames, oj + F.O_CAM_ROT), k)
	return {
		"xform": Transform3D(Basis(q), p0.lerp(p1, k)),
		"fov": lerpf(frames.decode_half(oi + F.O_CAM_FOV), frames.decode_half(oj + F.O_CAM_FOV), k),
		"camera": cameras[frames[oi + F.O_CAMERA]] if frames[oi + F.O_CAMERA] < cameras.size() else {},
	}


func _cam_t(i: int) -> float:
	var o := i * F.FRAME_SIZE
	return frames.decode_float(o + F.O_T) + frames.decode_half(o + F.O_CAM_DT)


## Events of one type (or all), in order.
func events_of(type: String = "") -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in events:
		if type == "" or str(e.get("type", "")) == type:
			out.append(e)
	return out
