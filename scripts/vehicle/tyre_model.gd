class_name TyreModel
extends RefCounted
## Surface table and a combined-slip, load-sensitive "magic formula" tyre.
##
## Slip is normalised per surface (1.0 = grip peak) and combined with the similarity method
## (friction ellipse): s = |(kappa / kappa_peak, tan(alpha) / tan(alpha_peak))|.
## Each direction uses its own curve shape f(s) = sin(C * atan(B * s)) with B chosen so that the
## peak sits at s = 1, so C alone controls how much grip is left past the peak.


class Surface:
	var id: StringName
	var mu: float ## peak friction coefficient at the reference load
	var lat_peak: float ## slip angle at the lateral peak (rad)
	var lat_c: float ## lateral shape: 1.2 very forgiving .. 1.6 sharp drop past the peak
	var long_peak: float ## slip ratio at the longitudinal peak
	var long_c: float
	var rolling: float ## rolling resistance coefficient (fraction of load)
	var drag: float ## extra speed-proportional drag per wheel on soft ground (N per N load per m/s)
	var roughness: float ## 0..1, drives surface noise on the suspension and camera shake
	var lat_b: float
	var long_b: float

	func _init(p_id: StringName, p_mu: float, p_lat_peak: float, p_lat_c: float, p_long_peak: float,
			p_long_c: float, p_rolling: float, p_drag: float, p_rough: float) -> void:
		id = p_id
		mu = p_mu
		lat_peak = p_lat_peak
		lat_c = p_lat_c
		long_peak = p_long_peak
		long_c = p_long_c
		rolling = p_rolling
		drag = p_drag
		roughness = p_rough
		lat_b = tan(PI / (2.0 * lat_c))
		long_b = tan(PI / (2.0 * long_c))


## Reference load for mu (N); above it grip per newton falls off (load sensitivity).
const REFERENCE_LOAD := 3100.0
const LOAD_SENSITIVITY := 0.11

static var _table: Dictionary = {}


static func get_surface(id: StringName) -> Surface:
	if _table.is_empty():
		_build()
	var s: Surface = _table.get(id)
	if s == null:
		s = _table[&"tarmac"]
	return s


static func _build() -> void:
	#                     id        mu    latPk lat_c longPk long_c roll  drag   rough
	_add(Surface.new(&"tarmac", 1.15, 0.125, 1.45, 0.10, 1.50, 0.012, 0.0, 0.03))
	_add(Surface.new(&"gravel", 0.85, 0.20, 1.20, 0.17, 1.25, 0.020, 0.0020, 0.55))
	_add(Surface.new(&"dirt", 0.80, 0.19, 1.25, 0.16, 1.30, 0.024, 0.0025, 0.40))
	_add(Surface.new(&"grass", 0.60, 0.17, 1.30, 0.15, 1.35, 0.040, 0.0060, 0.50))
	_add(Surface.new(&"sand", 0.55, 0.22, 1.20, 0.20, 1.25, 0.070, 0.0110, 0.30))


static func _add(s: Surface) -> void:
	_table[s.id] = s


## Load-sensitive peak friction force for a given normal load.
static func peak_force(load: float, surf: Surface) -> float:
	var k := 1.0 - LOAD_SENSITIVITY * (load / REFERENCE_LOAD - 1.0)
	return surf.mu * load * clampf(k, 0.7, 1.15)


## Combined-slip tyre force in the contact frame.
## kappa: slip ratio; tan_alpha: tangent of the slip angle (v_lat / |v_long|).
## Returns Vector3(Fx forward, Fy lateral (opposes tan_alpha), s combined normalised slip).
static func combined(kappa: float, tan_alpha: float, load: float, surf: Surface) -> Vector3:
	var sx := kappa / surf.long_peak
	var sy := tan_alpha / tan(surf.lat_peak)
	var s := sqrt(sx * sx + sy * sy)
	if s < 1e-7 or load <= 0.0:
		return Vector3(0.0, 0.0, s)
	var d := peak_force(load, surf)
	var fx := d * sin(surf.long_c * atan(surf.long_b * s)) * sx / s
	var fy := -d * sin(surf.lat_c * atan(surf.lat_b * s)) * sy / s
	return Vector3(fx, fy, s)
