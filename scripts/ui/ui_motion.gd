extends RefCounted
## Easing curves and tween helpers shared by every screen.
## All UI motion ignores Engine.time_scale (slow-mo must not slow the menus) and keeps
## running while the tree is paused (the UI root is PROCESS_MODE_ALWAYS).

const DUR_FAST := 0.16
const DUR := 0.32
const DUR_SLOW := 0.6


## Tween bound to `node`, unaffected by time scale.
static func tween(node: Node) -> Tween:
	var tw := node.create_tween()
	tw.set_ignore_time_scale(true)
	return tw


## Lays out every visible container under `node` now, parents first, instead of at the end of
## the frame, so an entrance can read final positions straight away. (Waiting for a drawn frame
## instead would stall the entrance for as long as the window does not draw: on a first launch
## the pipeline compiles hold drawing back for seconds while the game keeps processing.)
static func layout_now(node: Node) -> void:
	var c := node as Container
	if c != null and c.is_visible_in_tree():
		c.notification(Container.NOTIFICATION_SORT_CHILDREN)
	for child in node.get_children():
		layout_now(child)


static func kill(tw: Tween) -> void:
	if tw != null and tw.is_valid():
		tw.kill()


## Real (unscaled) frame delta for _process-driven animation.
static func real_delta(delta: float) -> float:
	var ts := Engine.time_scale
	return delta / ts if ts > 0.0001 else delta


static func out_expo(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	return 1.0 if t >= 1.0 else 1.0 - pow(2.0, -10.0 * t)


static func out_cubic(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	return 1.0 - pow(1.0 - t, 3.0)


static func in_cubic(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	return t * t * t


static func in_out_cubic(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	return 4.0 * t * t * t if t < 0.5 else 1.0 - pow(-2.0 * t + 2.0, 3.0) * 0.5


## Overshoot ease (CSS cubic-bezier(0.2, 0.9, 0.3, 1.3)-like). `s` controls overshoot.
static func out_back(t: float, s: float = 1.7) -> float:
	t = clampf(t, 0.0, 1.0) - 1.0
	return t * t * ((s + 1.0) * t + s) + 1.0


## Damped spring settle 0 -> 1 with a couple of soft wobbles.
static func out_spring(t: float, damping: float = 6.0, freq: float = 3.2) -> float:
	t = clampf(t, 0.0, 1.0)
	return 1.0 - exp(-damping * t) * cos(TAU * freq * t * 0.5)


## Quantise time to `fps` steps (anime "on twos" feel for kinetic typography).
static func stepped(t: float, fps: float = 12.0) -> float:
	return floorf(t * fps) / fps


## Local progress of an item inside a staggered group.
static func stagger(t: float, index: int, delay: float, duration: float) -> float:
	return clampf((t - float(index) * delay) / duration, 0.0, 1.0)


## Exponential smoothing factor for frame-rate independent lerp.
static func damp(sharpness: float, delta: float) -> float:
	return 1.0 - exp(-sharpness * delta)


## Rise-in: fade + slide up + slight scale, the default card entrance.
static func rise_in(c: CanvasItem, delay: float = 0.0, dist: float = 36.0, dur: float = 0.55) -> Tween:
	var ctrl := c as Control
	if ctrl != null:
		ctrl.pivot_offset = ctrl.size * 0.5
	c.modulate.a = 0.0
	var base_pos: Vector2 = c.get("position")
	c.set("position", base_pos + Vector2(0, dist))
	c.set("scale", Vector2(0.97, 0.97))
	var tw := tween(c)
	tw.set_parallel(true)
	tw.tween_property(c, "modulate:a", 1.0, dur * 0.6).set_delay(delay)
	tw.tween_property(c, "position", base_pos, dur).set_delay(delay).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(c, "scale", Vector2.ONE, dur).set_delay(delay).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return tw


## Quick exit: fade + slide.
static func slide_out(c: CanvasItem, offset: Vector2, delay: float = 0.0, dur: float = 0.28) -> Tween:
	var tw := tween(c)
	tw.set_parallel(true)
	var base_pos: Vector2 = c.get("position")
	tw.tween_property(c, "modulate:a", 0.0, dur).set_delay(delay).set_ease(Tween.EASE_IN)
	tw.tween_property(c, "position", base_pos + offset, dur).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	return tw
