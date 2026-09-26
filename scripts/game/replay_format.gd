class_name ReplayFormat
extends RefCounted
## The replay file format (docs/REPLAYS.md): a JSON header, then zstd-compressed blocks of
## fixed-size frames (60 Hz) and JSON events. Written by the Replays autoload
## (scripts/autoload/replays.gd), read by ReplayData.load_file() for tools/replay/review.gd.
##
## File: "SRRP", u16 version, u16 0, u32 header length, header JSON (UTF-8), then blocks of
## u32 raw length, u32 compressed length, zstd bytes. A block's raw bytes: u32 frame count n,
## the n frames as FRAME_SIZE byte planes (byte k of every frame, then byte k + 1, ...; each
## byte stored as its difference to the same byte of the previous frame, mod 256 - it packs
## about twice as small as the plain records), then event records to the end: f32 time, u16
## length, event JSON. All little-endian. A file cut short (crash, power loss) reads up to its
## last whole block.

const MAGIC := "SRRP"
const VERSION := 1
const EXTENSION := "srr"
## Physics ticks per stored frame (120 Hz physics -> 60 Hz frames).
const TICKS_PER_FRAME := 2

## Frame layout: byte offsets. f32 = float, f16 = half, q16 = quaternion as 4 x s16 / 32767
## (w >= 0), u8n / s8n = 0..1 / -1..1 as 0..255 / -127..127.
const O_T := 0 ## f32 seconds since the recording started (game time)
const O_BUTTONS := 4 ## u16 BUTTONS bits: held keys, and presses (edges) since the last frame
const O_FLAGS := 6 ## u16 FLAGS bits
const O_STATE := 8 ## u8 Game.State value (names in the header "states")
const O_GEAR := 9 ## s8 gear (-1 reverse, 0 neutral)
const O_IN_STEER := 10 ## s8n Car.input_steer (after the keyboard / stick shaping)
const O_IN_THROTTLE := 11 ## u8n Car.input_throttle
const O_IN_BRAKE := 12 ## u8n Car.input_brake
const O_STEER := 13 ## s8n Car.steer (steering output, fraction of the lock)
const O_HANDBRAKE := 14 ## u8n Car.handbrake (applied)
const O_GROUNDED := 15 ## u8 Car.grounded_wheels
const O_POS := 16 ## 3 x f32 car origin
const O_ROT := 28 ## q16 car rotation
const O_LIN := 36 ## 3 x f16 linear velocity (m/s, world)
const O_ANG := 42 ## 3 x f16 angular velocity (rad/s, world)
const O_RPM := 48 ## u16 engine rpm
const O_KMH := 50 ## f16 Car.speed_kmh (signed, along the car)
const O_SLIP := 52 ## f16 Car.body_slip (rad)
const O_WHEELS := 54 ## 4 x WHEEL_SIZE, FL FR RL RR
const WHEEL_SIZE := 10
const W_SURFACE := 0 ## u8 0 = no contact, else 1 + index into the header "surfaces" (+ "surface" events)
const W_COMPRESSION := 1 ## u8n suspension compression
const W_SPIN_ANGLE := 2 ## u16 spin angle, 0..TAU as 0..65536
const W_SPIN_SPEED := 4 ## f16 rad/s
const W_STEER := 6 ## f16 steer angle (rad)
const W_OFFSET := 8 ## f16 wheel centre offset from rest (m, up)
const O_S := 94 ## f32 distance from the start line along the route (m) at the nearest road sample
const O_LAT := 98 ## f16 lateral offset from the centreline (m, + right)
const O_HALF := 100 ## u8 road half width at that sample, decimetres
const O_CHECKPOINT := 101 ## u8 RaceSession.checkpoint_index (next checkpoint)
const O_CAMERA := 102 ## u8 active camera: index into "camera" events (255 = none)
const O_PAD := 103 ## u8 0
const O_ELAPSED := 104 ## f32 RaceSession.elapsed
const O_CAM_POS := 108 ## 3 x f16 camera origin (the last rendered frame) minus the car origin
const O_CAM_ROT := 114 ## q16 camera rotation
const O_CAM_FOV := 122 ## f16 camera vertical FOV (degrees)
const O_CAM_DT := 124 ## f16 time of that camera sample minus O_T (s)
const FRAME_SIZE := 126

## Button bits (InputMap actions). The first five are held-state; the others are set when the
## action was pressed during either physics tick of the frame.
const BUTTONS: Array[StringName] = [&"throttle", &"brake", &"steer_left", &"steer_right", &"handbrake",
		&"shift_up", &"shift_down", &"reset_car", &"camera_next", &"pause", &"horn"]
const HELD_BUTTONS := 5

## Flag bits.
const F_PLAYER := 1 ## Car.controlled_by_player
const F_LAUNCH_HOLD := 2 ## start-line hold (countdown)
const F_RUNNING := 4 ## RaceSession.running (the clock is live)
const F_ON_ROAD := 8 ## car centre within the road half width
const F_SHIFTING := 16 ## gear change in progress
const F_ANALOG := 32 ## steering from a stick (CarInput.analog_steer)
const F_PAUSED := 64 ## Game.paused (never set in stored frames: nothing ticks while paused)


static func quat_encode(buf: PackedByteArray, off: int, q: Quaternion) -> void:
	if q.w < 0.0:
		q = -q
	buf.encode_s16(off, int(roundf(clampf(q.x, -1.0, 1.0) * 32767.0)))
	buf.encode_s16(off + 2, int(roundf(clampf(q.y, -1.0, 1.0) * 32767.0)))
	buf.encode_s16(off + 4, int(roundf(clampf(q.z, -1.0, 1.0) * 32767.0)))
	buf.encode_s16(off + 6, int(roundf(clampf(q.w, -1.0, 1.0) * 32767.0)))


static func quat_decode(buf: PackedByteArray, off: int) -> Quaternion:
	return Quaternion(buf.decode_s16(off) / 32767.0, buf.decode_s16(off + 2) / 32767.0,
			buf.decode_s16(off + 4) / 32767.0, buf.decode_s16(off + 6) / 32767.0).normalized()


static func vec3_f32(buf: PackedByteArray, off: int) -> Vector3:
	return Vector3(buf.decode_float(off), buf.decode_float(off + 4), buf.decode_float(off + 8))


static func vec3_f16(buf: PackedByteArray, off: int) -> Vector3:
	return Vector3(buf.decode_half(off), buf.decode_half(off + 2), buf.decode_half(off + 4))


## The file's first bytes: magic, version and the header JSON.
static func header_bytes(header: Dictionary) -> PackedByteArray:
	var json := JSON.stringify(json_safe(header)).to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(12)
	out.encode_u8(0, MAGIC.unicode_at(0))
	out.encode_u8(1, MAGIC.unicode_at(1))
	out.encode_u8(2, MAGIC.unicode_at(2))
	out.encode_u8(3, MAGIC.unicode_at(3))
	out.encode_u16(4, VERSION)
	out.encode_u16(6, 0)
	out.encode_u32(8, json.size())
	out.append_array(json)
	return out


## One block: `count` frames (FRAME_SIZE bytes each, back to back) as delta-coded byte planes,
## then the event records, compressed (zstd) behind the two lengths. Runs on the writer thread.
static func block_bytes(frames: PackedByteArray, count: int, events: PackedByteArray) -> PackedByteArray:
	var raw := PackedByteArray()
	raw.resize(4 + count * FRAME_SIZE)
	raw.encode_u32(0, count)
	var at := 4
	for k in FRAME_SIZE:
		var prev := 0
		for i in count:
			var v := frames[i * FRAME_SIZE + k]
			raw[at] = (v - prev) & 0xff
			prev = v
			at += 1
	raw.append_array(events)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	var out := PackedByteArray()
	out.resize(8)
	out.encode_u32(0, raw.size())
	out.encode_u32(4, packed.size())
	out.append_array(packed)
	return out


## The frames of a block's raw bytes, back to back (undoes the planes and deltas).
static func block_frames(raw: PackedByteArray) -> PackedByteArray:
	var count := raw.decode_u32(0)
	var frames := PackedByteArray()
	frames.resize(count * FRAME_SIZE)
	var at := 4
	for k in FRAME_SIZE:
		var v := 0
		for i in count:
			v = (v + raw[at]) & 0xff
			frames[i * FRAME_SIZE + k] = v
			at += 1
	return frames


## Where a block's event records start in its raw bytes.
static func block_events_at(raw: PackedByteArray) -> int:
	return 4 + raw.decode_u32(0) * FRAME_SIZE


## Appends an event record to `buf` at byte `at` (growing it) and returns the new end.
static func append_event(buf: PackedByteArray, at: int, t: float, event: Dictionary) -> int:
	var json := JSON.stringify(json_safe(event)).to_utf8_buffer()
	var end := at + 6 + json.size()
	if buf.size() < end:
		buf.resize(maxi(end, buf.size() * 2))
	buf.encode_float(at, t)
	buf.encode_u16(at + 4, json.size())
	for i in json.size():
		buf[at + 6 + i] = json[i]
	return end


## Values JSON can hold: vectors as arrays, colours as hex, non-finite floats as null.
static func json_safe(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			return v if is_finite(v) else null
		TYPE_VECTOR3:
			return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]
		TYPE_VECTOR2:
			return [v.x, v.y]
		TYPE_COLOR:
			return "#" + (v as Color).to_html(false)
		TYPE_STRING_NAME:
			return String(v)
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				d[str(k)] = json_safe(v[k])
			return d
		TYPE_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_INT32_ARRAY, \
				TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR3_ARRAY:
			var a := []
			for x in v:
				a.append(json_safe(x))
			return a
	return v
