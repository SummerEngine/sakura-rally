extends RefCounted
## Reads a drive out of a replay (ReplayData) against its route (Track): the timeline of what
## happened and where - splits, crashes, resets, off-road excursions, jumps, wrong way, pauses -
## and the hesitations that hint at a driver who did not know what came next (sudden lifts,
## heavy or unexpected braking, crawling, zig-zag steering), placed by route distance and the
## nearest corner; plus the sectors where the most time went against a grip-limited reference
## speed profile of the road. Used by tools/replay/review.gd (summary, render --events) and
## tools/replay/record_lap.gd.

const F := preload("res://scripts/game/replay_format.gd")

## Corner detection: heading change measured over +-CURV_WINDOW samples; a corner is a run
## tighter than CORNER_RADIUS metres that turns at least CORNER_MIN_DEG in total.
const CURV_WINDOW := 5
const CORNER_RADIUS := 140.0
const CORNER_MIN_DEG := 25.0
## Reference speed profile: lateral grip (g), top speed (km/h), acceleration and braking (m/s^2).
const REF_GRIP := 0.95
const REF_TOP_KMH := 165.0
const REF_ACCEL := 4.5
const REF_BRAKE := 8.0
const SECTOR_M := 250.0
## Impacts at or above HARD_IMPACT are crashes; KNOCK_IMPACT and up are knocks.
const HARD_IMPACT := 0.25
const KNOCK_IMPACT := 0.1
const CAR_HALF_WIDTH := 0.9


## Corners of the route: [{num, dir, angle, radius, s0, s1, apex}] with s in metres from the
## start line (a corner over the line of a loop has s0 > s1).
static func corners(track: Track) -> Array[Dictionary]:
	var n := track.count
	var curv := PackedFloat32Array()
	curv.resize(n)
	for i in n:
		var a := track.forward(i - CURV_WINDOW)
		var b := track.forward(i + CURV_WINDOW)
		var turn := atan2(b.dot(Vector3(-a.z, 0.0, a.x)), b.dot(a))
		curv[i] = turn / (2.0 * CURV_WINDOW * track.spacing)
	# Start a loop's scan on a straight so no corner is split by index 0.
	var first := 0
	if track.closed:
		for i in n:
			if absf(curv[i]) < 1.0 / CORNER_RADIUS:
				first = i
				break
	var runs: Array[Dictionary] = []
	var cur := {}
	for k in n:
		var i := (first + k) % n if track.closed else k
		var c := curv[i]
		var sgn := 0 if absf(c) < 1.0 / CORNER_RADIUS else (1 if c > 0.0 else -1)
		if sgn != 0 and not cur.is_empty() and int(cur["sign"]) == sgn and k - int(cur["k1"]) <= 5:
			cur["k1"] = k
			cur["max"] = maxf(cur["max"], absf(c))
			if absf(c) >= cur["max"]:
				cur["apex"] = i
		elif sgn != 0:
			if not cur.is_empty():
				runs.append(cur)
			cur = {"sign": sgn, "k0": k, "k1": k, "max": absf(c), "apex": i}
	if not cur.is_empty():
		runs.append(cur)
	var out: Array[Dictionary] = []
	for r in runs:
		var i0 := (first + int(r["k0"])) % n if track.closed else int(r["k0"])
		var i1 := (first + int(r["k1"])) % n if track.closed else int(r["k1"])
		var angle := 0.0
		# Total turn: sum over the run (a hairpin passes 180 degrees).
		for k in range(int(r["k0"]), int(r["k1"]) + 1):
			var i := (first + k) % n if track.closed else k
			var fa := track.forward(i)
			var fb := track.forward(i + 1)
			angle += atan2(fb.dot(Vector3(-fa.z, 0.0, fa.x)), fb.dot(fa))
		if rad_to_deg(absf(angle)) < CORNER_MIN_DEG:
			continue
		out.append({
			"dir": "right" if angle > 0.0 else "left",
			"angle": rad_to_deg(absf(angle)),
			"radius": 1.0 / float(r["max"]),
			"s0": _progress(track, track.dist(i0)),
			"s1": _progress(track, track.dist(i1)),
			"apex": _progress(track, track.dist(int(r["apex"]))),
		})
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x["apex"] < y["apex"])
	for k in out.size():
		out[k]["num"] = k + 1
	return out


static func _progress(track: Track, abs_s: float) -> float:
	if track.closed:
		return fposmod(abs_s - track.start_s, track.length)
	return abs_s - track.start_s


static func corner_name(c: Dictionary) -> String:
	var kind: String = "hairpin" if c["angle"] > 130.0 and c["radius"] < 30.0 else c["dir"]
	if kind == "hairpin":
		kind = "%s hairpin" % c["dir"]
	return "C%d %s %d° r%d" % [c["num"], kind, roundi(c["angle"]), roundi(c["radius"])]


## Where route distance s sits relative to the corners: "in C5 right 90° r32",
## "60 m before C5 ...", "40 m after C4 ..." or "straight".
static func where(corner_list: Array[Dictionary], s: float, length: float, closed: bool) -> String:
	if s < 0.0:
		return "off the route"
	var best_ahead := {}
	var ahead_d := INF
	var best_behind := {}
	var behind_d := INF
	for c in corner_list:
		var s0: float = c["s0"]
		var s1: float = c["s1"]
		var inside := (s >= s0 and s <= s1) if s0 <= s1 else (s >= s0 or s <= s1)
		if inside:
			return "in " + corner_name(c)
		var da := s0 - s
		var db := s - s1
		if closed:
			da = fposmod(da, length)
			db = fposmod(db, length)
		if da >= 0.0 and da < ahead_d:
			ahead_d = da
			best_ahead = c
		if db >= 0.0 and db < behind_d:
			behind_d = db
			best_behind = c
	if not best_ahead.is_empty() and ahead_d <= 150.0:
		return "%d m before %s" % [roundi(ahead_d), corner_name(best_ahead)]
	if not best_behind.is_empty() and behind_d <= 80.0:
		return "%d m after %s" % [roundi(behind_d), corner_name(best_behind)]
	return "straight"


## Grip-limited reference speed (m/s) per road sample: corner speed from the radius, then
## acceleration and braking limits forward and backward along the route.
static func reference_speed(track: Track) -> PackedFloat32Array:
	var n := track.count
	var v := PackedFloat32Array()
	v.resize(n)
	var top := REF_TOP_KMH / 3.6
	for i in n:
		var a := track.forward(i - 3)
		var b := track.forward(i + 3)
		var k := absf(atan2(b.dot(Vector3(-a.z, 0.0, a.x)), b.dot(a))) / (6.0 * track.spacing)
		var grip := REF_GRIP * (0.8 if track.surface(i) == &"gravel" else 1.0)
		v[i] = minf(top, sqrt(grip * 9.8 / maxf(k, 1e-5)))
	for _pass in 2:
		for k in range(1, n):
			v[k] = minf(v[k], sqrt(v[k - 1] * v[k - 1] + 2.0 * REF_ACCEL * track.spacing))
		for k in range(n - 2, -1, -1):
			v[k] = minf(v[k], sqrt(v[k + 1] * v[k + 1] + 2.0 * REF_BRAKE * track.spacing))
	return v


## The whole review of one replay. `track` may be null (no corners, no sectors, no wrong way).
static func analyze(data: ReplayData, track: Track) -> Dictionary:
	var h := data.header
	var corner_list: Array[Dictionary] = corners(track) if track != null else []
	var length: float = track.length if track != null else float((h.get("track", {}) as Dictionary).get("length", 1.0))
	var closed: bool = track.closed if track != null else bool((h.get("track", {}) as Dictionary).get("closed", true))
	var moments: Array[Dictionary] = []
	var at := func(t: float) -> Dictionary:
		var i := data.index_at(t)
		var s := data.route_s(i)
		return {"t": t, "s": s, "kmh": absf(data.kmh(i)), "where": where(corner_list, s, length, closed)}
	var add := func(t: float, kind: String, text: String, weight: float, extra: Dictionary = {}) -> void:
		var m: Dictionary = at.call(t)
		m["kind"] = kind
		m["text"] = text
		m["weight"] = weight
		m.merge(extra)
		moments.append(m)

	# ---- events
	var splits: Array[Dictionary] = []
	var result := {}
	var last_notice := {}
	var hazard_t := -INF
	var impacts: Array[Dictionary] = []
	var smashes := 0
	var pauses := 0
	var start_t := NAN
	var end_reason := ""
	for e in data.events:
		var t: float = e["t"]
		match str(e.get("type", "")):
			"start":
				start_t = t
				add.call(t, "start", "GO", 0.0)
			"checkpoint":
				splits.append(e)
				var d: Variant = e.get("delta")
				add.call(t, "split", "split %d/%d  %s%s" % [int(e["index"]) + 1, int(e["total"]),
						_clock(float(e["split"])), "" if d == null else "  (%+.2f vs record)" % float(d)], 0.0)
			"finish":
				result = e
				add.call(t, "finish", "FINISH %s%s%s" % [_clock(float(e.get("time", 0.0))),
						"  medal " + str(e.get("medal")) if str(e.get("medal", "")) != "" else "",
						"  RECORD" if e.get("is_record", false) else ""], 0.0)
			"arrived":
				add.call(t, "arrived", "arrived", 0.0)
			"impact":
				impacts.append(e)
			"landed":
				if float(e.get("strength", 0.0)) >= 0.6:
					add.call(t, "landing", "hard landing %.2f" % float(e["strength"]), 0.5)
			"reset":
				var cause := "R key" if e.get("key", false) else "scripted"
				if t - hazard_t < 1.0:
					cause = "hazard (%s)" % last_notice.get("hazard", "")
				add.call(t, "reset", "RESET (%s)" % cause, 3.0, {"cause": cause})
			"hazard":
				hazard_t = t
				last_notice["hazard"] = str(e.get("reason", ""))
			"notice":
				var text := str(e.get("text", ""))
				if text == "Car reset":
					# The car's own reset (stuck / upside down) posts this right after the jump.
					for k in range(moments.size() - 1, -1, -1):
						if moments[k]["kind"] == "reset" and t - float(moments[k]["t"]) < 1.0:
							moments[k]["text"] = "RESET (automatic: stuck or on its roof)"
							moments[k]["cause"] = "auto"
							break
				elif text == "Wrong way":
					add.call(t, "wrong_way", "WRONG WAY notice", 2.0)
				elif text.begins_with("Off the route"):
					add.call(t, "off_route", "OFF ROUTE notice (stopped away from the road)", 2.0)
				elif not text.begins_with("Lap"):
					add.call(t, "notice", "notice: " + text, 0.0)
			"smash":
				smashes += 1
			"pause":
				if e.get("paused", false):
					pauses += 1
					add.call(t, "pause", "paused", 1.0)
			"camera":
				add.call(t, "camera", "camera %s %s" % [e.get("name", ""), e.get("mode", "")], 0.0)
			"settings":
				add.call(t, "settings", "settings changed %s" % JSON.stringify(e.get("changed", {})), 0.0)
			"end":
				end_reason = str(e.get("reason", ""))
	# impacts within a second of each other are one crash
	var group_t := -INF
	var group_max := 0.0
	var group_n := 0
	for k in impacts.size() + 1:
		var e: Dictionary = impacts[k] if k < impacts.size() else {"t": INF, "strength": 0.0}
		if float(e["t"]) - group_t > 1.0:
			if group_n > 0 and group_max >= KNOCK_IMPACT:
				var hard := group_max >= HARD_IMPACT
				add.call(group_t, "crash" if hard else "knock", "%s %.2f%s" % ["CRASH" if hard else "knock", group_max,
						"" if group_n == 1 else " (%d hits)" % group_n], 3.0 * group_max if hard else 0.5)
			group_t = float(e["t"])
			group_max = 0.0
			group_n = 0
		group_max = maxf(group_max, float(e["strength"]))
		group_n += 1

	# ---- frames
	var fs := F.FRAME_SIZE
	var b := data.frames
	var verge: float = track.verge if track != null else 1.4
	var top_kmh := 0.0
	var auto_s := 0.0 ## seconds in a driving state with the car not under the player's control
	var off := {}
	var air_t := NAN
	var lift_ready := 0.0
	var lift := {}
	var brake := {}
	var crawl := {}
	var wrong := {}
	var steer_flips: Array[float] = []
	var steer_side := 0
	var last_zig := -INF
	var hint := -1
	var prev_t := 0.0
	var driven := 0.0
	var d_max := -INF
	var prev_s := NAN
	var crossings: Dictionary = {} ## sector index -> first time reached
	var state_names: Array = h.get("states", [])
	for i in data.count:
		var o := i * fs
		var t := b.decode_float(o + F.O_T)
		var dt := t - prev_t
		prev_t = t
		var flags := b.decode_u16(o + F.O_FLAGS)
		var st := b[o + F.O_STATE]
		var state := str(state_names[st]) if st < state_names.size() else ""
		var kmh := absf(b.decode_half(o + F.O_KMH))
		var s := b.decode_float(o + F.O_S)
		var lat := b.decode_half(o + F.O_LAT)
		var half := b[o + F.O_HALF] / 10.0
		var thr := b[o + F.O_IN_THROTTLE] / 255.0
		var brk := b[o + F.O_IN_BRAKE] / 255.0
		var steer := b.decode_s8(o + F.O_IN_STEER) / 127.0
		var grounded := b[o + F.O_GROUNDED]
		var player := flags & F.F_PLAYER != 0 and flags & F.F_LAUNCH_HOLD == 0
		var driving := player and state in ["RACING", "LIAISON", "FREE_ROAM"]
		if driving:
			top_kmh = maxf(top_kmh, kmh)
		elif flags & F.F_PLAYER == 0 and state in ["RACING", "LIAISON", "FREE_ROAM"]:
			auto_s += dt
		# route distance driven (resets and wrap-arounds do not count as distance)
		if s >= 0.0 and driving:
			if is_finite(prev_s):
				var step := s - prev_s
				if closed:
					step = wrapf(step, -length * 0.5, length * 0.5)
				if absf(step) < 30.0:
					driven += step
			prev_s = s
			if driven > d_max:
				d_max = driven
				var sector := int(floor(d_max / SECTOR_M))
				if not crossings.has(sector):
					crossings[sector] = t
		# off the road: the whole car beyond the tarmac edge
		var beyond := absf(lat) - half
		if driving and s >= 0.0 and beyond > CAR_HALF_WIDTH:
			if off.is_empty():
				off = {"t": t, "max": beyond, "kmh": kmh, "side": "right" if lat > 0.0 else "left"}
			off["max"] = maxf(off["max"], beyond)
			off["t1"] = t
		elif not off.is_empty():
			var dur := float(off.get("t1", off["t"])) - float(off["t"])
			if dur >= 0.3 or float(off["max"]) > verge + 1.0:
				var big := float(off["max"]) > verge + 2.0
				add.call(off["t"], "off_road", "OFF ROAD %s side, %.1f s, %.1f m beyond the edge, entered at %d km/h" % [
						off["side"], dur, float(off["max"]), roundi(float(off["kmh"]))], (2.5 if big else 1.0) + dur * 0.3,
						{"duration": dur, "beyond": off["max"]})
			off = {}
		# airborne
		if grounded == 0 and driving:
			if is_nan(air_t):
				air_t = t
		elif not is_nan(air_t):
			if t - air_t >= 0.35:
				add.call(air_t, "jump", "airborne %.1f s" % (t - air_t), 0.3 + (t - air_t))
			air_t = NAN
		if not driving:
			lift_ready = 0.0
			lift = {}
			brake = {}
			crawl = {}
			wrong = {}
			continue
		# sudden lift: flat out for a second, then off both pedals at speed
		if thr > 0.8:
			lift_ready += dt
			if not lift.is_empty():
				lift = {}
		elif thr < 0.1 and brk < 0.1 and kmh > 50.0 and lift_ready >= 1.0:
			if lift.is_empty():
				lift = {"t": t, "kmh": kmh}
			elif t - float(lift["t"]) >= 0.4 and not lift.get("done", false):
				lift["done"] = true
				lift_ready = 0.0
				# Lifting in a corner is driving; on a straight or on the way in it is doubt.
				var w := where(corner_list, s, length, closed)
				if not w.begins_with("in "):
					var unsure := w == "straight"
					add.call(lift["t"], "lift", "sudden lift at %d km/h%s" % [roundi(float(lift["kmh"])),
							" on a straight (unsure what comes?)" if unsure else ""], 1.2 if unsure else 0.6)
		elif brk > 0.1:
			lift_ready = 0.0
		# heavy braking
		if brk > 0.7:
			if brake.is_empty():
				brake = {"t": t, "kmh": kmh, "s": s}
			brake["t1"] = t
			brake["kmh1"] = kmh
		elif not brake.is_empty():
			var dur := float(brake["t1"]) - float(brake["t"])
			if dur >= 0.25 and float(brake["kmh"]) > 40.0 and float(brake["kmh"]) - float(brake["kmh1"]) > 15.0:
				var w := where(corner_list, float(brake["s"]), length, closed)
				var late := w.begins_with("in ")
				var odd := w == "straight"
				var note := " (late: already in the corner)" if late else (" (nothing to brake for?)" if odd else "")
				add.call(brake["t"], "brake", "heavy braking %d -> %d km/h in %.1f s%s" % [roundi(float(brake["kmh"])),
						roundi(float(brake["kmh1"])), dur, note], 1.5 if late or odd else 0.4)
			brake = {}
		# crawling
		if kmh < 15.0:
			if crawl.is_empty():
				crawl = {"t": t}
			crawl["t1"] = t
		elif not crawl.is_empty():
			var dur := float(crawl["t1"]) - float(crawl["t"])
			if dur >= 2.0:
				add.call(crawl["t"], "crawl", "crawling under 15 km/h for %.1f s" % dur, 1.0 + dur * 0.3)
			crawl = {}
		# zig-zag steering: the input swung hard across centre three times within 2.5 s
		var side := 1 if steer > 0.35 else (-1 if steer < -0.35 else 0)
		if side != 0 and side != steer_side and kmh > 25.0:
			if steer_side != 0:
				steer_flips.append(t)
			steer_side = side
		while not steer_flips.is_empty() and t - steer_flips[0] > 2.5:
			steer_flips.pop_front()
		if steer_flips.size() >= 3 and t - last_zig > 3.0:
			last_zig = t
			add.call(steer_flips[0], "zigzag", "zig-zag steering (%d swings in 2.5 s)" % steer_flips.size(), 1.0)
		# wrong way, judged on the road
		if track != null and s >= 0.0 and kmh > 10.0:
			var pos := F.vec3_f32(b, o + F.O_POS)
			hint = track.nearest(pos, hint, 12) if hint >= 0 else track.nearest(pos)
			var v := F.vec3_f16(b, o + F.O_LIN)
			var backwards := v.normalized().dot(track.forward(hint)) < -0.3
			if backwards:
				if wrong.is_empty():
					wrong = {"t": t}
				wrong["t1"] = t
			elif not wrong.is_empty():
				var dur := float(wrong["t1"]) - float(wrong["t"])
				if dur >= 1.0:
					add.call(wrong["t"], "wrong_way", "driving the wrong way for %.1f s" % dur, 2.0 + dur * 0.2)
				wrong = {}

	moments.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x["t"] < y["t"])

	# ---- sectors: time per SECTOR_M of route driven against the reference profile
	var sectors: Array[Dictionary] = []
	if track != null and crossings.size() > 1:
		var vref := reference_speed(track)
		var s0 := data.route_s(data.index_at(float(crossings.values()[0])))
		var keys := crossings.keys()
		keys.sort()
		for k in range(keys.size() - 1):
			var a: int = keys[k]
			var c: int = a + 1
			if not crossings.has(c):
				continue
			var took: float = crossings[c] - crossings[a]
			var entry := absf(data.kmh(data.index_at(float(crossings[a]))))
			var ref := 0.0
			var d := a * SECTOR_M
			while d < c * SECTOR_M:
				var ss := s0 + d
				var idx := track.index_at_abs(ss + track.start_s)
				ref += track.spacing / maxf(vref[idx], 1.0)
				d += track.spacing
			var from_s := fposmod(s0 + a * SECTOR_M, length) if closed else s0 + a * SECTOR_M
			var inside: Array[String] = []
			for m in moments:
				if float(m["t"]) >= crossings[a] and float(m["t"]) < crossings[c] and float(m["weight"]) >= 1.0:
					inside.append(str(m["kind"]))
			sectors.append({"from": from_s, "to": from_s + SECTOR_M, "t": crossings[a], "took": took,
					"ref": ref, "lost": took - ref, "moments": inside, "standing": k == 0 and entry < 10.0,
					"where": where(corner_list, from_s + SECTOR_M * 0.5, length, closed)})
	# A sector entered from rest (the start) has no fair flying reference.
	var worst := sectors.filter(func(x: Dictionary) -> bool: return not x["standing"])
	worst.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x["lost"] > y["lost"])

	var counts := {}
	for m in moments:
		counts[m["kind"]] = int(counts.get(m["kind"], 0)) + 1
	return {
		"header": h,
		"duration": data.duration(),
		"complete": data.complete,
		"end_reason": end_reason,
		"start_t": start_t,
		"result": result,
		"splits": splits,
		"top_kmh": top_kmh,
		"autopilot_s": auto_s,
		"smashes": smashes,
		"pauses": pauses,
		"corners": corner_list,
		"moments": moments,
		"counts": counts,
		"sectors": sectors,
		"worst": worst.slice(0, 5),
	}


## The moments worth a clip (render --events): everything weighing at least 1, strongest
## first up to `limit`, then back in time order.
static func notable(summary: Dictionary, limit: int = 12) -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	for m in summary["moments"]:
		if float(m["weight"]) >= 1.0:
			list.append(m)
	list.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x["weight"] > y["weight"])
	list = list.slice(0, limit)
	list.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x["t"] < y["t"])
	return list


static func report(summary: Dictionary) -> String:
	var h: Dictionary = summary["header"]
	var lines: PackedStringArray = []
	var ver: Dictionary = h.get("version", {})
	lines.append("%s  %s / %s  car %s  (%s %s)" % [h.get("date", "?"), h.get("route", "?"), h.get("mode", "?"),
			h.get("car", "?"), ver.get("branch", ""), ver.get("commit", "")])
	var cfg: Dictionary = h.get("settings", {})
	lines.append("settings: camera %s, transmission %s, quality %s%s" % [cfg.get("camera", "?"),
			cfg.get("transmission", "?"), cfg.get("quality", "?"), "  (tool run)" if h.get("tool_run", false) else ""])
	lines.append("length %s, ended: %s%s" % [_clock(summary["duration"]), summary["end_reason"],
			"" if summary["complete"] else " (file cut short)"])
	var res: Dictionary = summary["result"]
	if not res.is_empty():
		lines.append("RESULT %s  medal %s  best %s%s" % [_clock(float(res.get("time", 0.0))), res.get("medal", "-"),
				_clock(float(res["best_time"])) if res.get("best_time") != null else "-", "  NEW RECORD" if res.get("is_record", false) else ""])
	lines.append("top speed %d km/h, %d props smashed, %d pauses" % [roundi(summary["top_kmh"]), summary["smashes"], summary["pauses"]])
	if float(summary["autopilot_s"]) > 0.5:
		lines.append("autopilot drove %.1f s (not the player: left out of the speed, hesitations and sectors)" % summary["autopilot_s"])
	var counts: Dictionary = summary["counts"]
	var tally: PackedStringArray = []
	for k in ["crash", "knock", "reset", "off_road", "wrong_way", "off_route", "lift", "brake", "crawl", "zigzag", "jump"]:
		if counts.has(k):
			tally.append("%s %d" % [k, counts[k]])
	lines.append("counts: " + (", ".join(tally) if not tally.is_empty() else "nothing notable"))
	lines.append("")
	lines.append("TIMELINE (t = replay time, s = metres from the start line)")
	var start_t: float = summary["start_t"]
	for m in summary["moments"]:
		var clock := "" if is_nan(start_t) else "  race %s" % _clock(float(m["t"]) - start_t)
		lines.append("  %7.2fs%s  s=%5dm  %3d km/h  %-38s  %s" % [float(m["t"]), clock, roundi(float(m["s"])),
				roundi(float(m["kmh"])), str(m["where"]).left(38), m["text"]])
	if not summary["worst"].is_empty():
		lines.append("")
		lines.append("WORST SECTORS (%d m of road, time vs a grip-limited reference profile)" % roundi(SECTOR_M))
		for sec in summary["worst"]:
			lines.append("  s=%5d-%5dm  %5.1fs (ref %4.1fs, +%4.1fs)  %s%s" % [roundi(float(sec["from"])), roundi(float(sec["to"])),
					float(sec["took"]), float(sec["ref"]), float(sec["lost"]), sec["where"],
					"" if sec["moments"].is_empty() else "  [" + ", ".join(sec["moments"]) + "]"])
	return "\n".join(lines)


static func _clock(t: float) -> String:
	if not is_finite(t):
		return "-"
	var neg := "-" if t < 0.0 else ""
	t = absf(t)
	return "%s%d:%06.3f" % [neg, int(t / 60.0), fmod(t, 60.0)]
