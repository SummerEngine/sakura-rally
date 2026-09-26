extends RefCounted
## Brush stroke centrelines for the Yuji Syuku glyphs that get a true stroke-order reveal.
## Coordinates are on a 0..10 grid over the glyph box used by UIBrushKanji (box side S,
## glyph drawn at font size 0.84 * S, centred). Traced from renders of the actual font.
## Order follows standard stroke order; each stroke is one PackedVector2Array.

const STROKES := {
	"桜": [
		# 木
		[Vector2(1.5, 3.75), Vector2(2.4, 4.1), Vector2(3.5, 3.85), Vector2(4.5, 4.0)],
		[Vector2(3.0, 1.5), Vector2(3.6, 2.4), Vector2(3.55, 4.5), Vector2(3.6, 7.0), Vector2(3.7, 9.0)],
		[Vector2(2.1, 7.85), Vector2(3.0, 8.3), Vector2(3.6, 8.9)],
		[Vector2(3.45, 4.2), Vector2(2.8, 5.4), Vector2(2.0, 6.6), Vector2(1.4, 7.4)],
		[Vector2(3.8, 4.55), Vector2(4.3, 5.1), Vector2(4.4, 5.45)],
		# ⺍
		[Vector2(4.5, 2.8), Vector2(5.0, 3.55), Vector2(5.6, 4.25)],
		[Vector2(5.9, 2.3), Vector2(6.45, 3.2), Vector2(7.0, 3.7)],
		[Vector2(8.8, 2.55), Vector2(8.2, 3.7), Vector2(7.6, 4.3)],
		# 女
		[Vector2(5.4, 4.3), Vector2(5.8, 4.9), Vector2(5.35, 6.1), Vector2(4.9, 7.1), Vector2(6.0, 7.6), Vector2(7.3, 8.3), Vector2(8.9, 9.1)],
		[Vector2(7.1, 5.2), Vector2(7.0, 6.4), Vector2(6.4, 7.7), Vector2(5.4, 8.55), Vector2(4.4, 8.75)],
		[Vector2(3.8, 5.85), Vector2(5.2, 5.55), Vector2(7.0, 5.4), Vector2(8.5, 5.5), Vector2(9.7, 5.7)],
	],
	"一": [
		[Vector2(1.4, 5.1), Vector2(4.0, 4.95), Vector2(7.0, 4.8), Vector2(9.5, 5.5)],
	],
	"二": [
		[Vector2(2.9, 3.3), Vector2(5.0, 3.6), Vector2(7.9, 3.8)],
		[Vector2(1.7, 7.0), Vector2(5.0, 6.9), Vector2(7.8, 6.95), Vector2(9.5, 7.6)],
	],
	"三": [
		[Vector2(2.3, 2.9), Vector2(5.0, 3.0), Vector2(8.1, 3.1)],
		[Vector2(2.8, 5.25), Vector2(5.0, 5.3), Vector2(7.7, 5.35)],
		[Vector2(1.4, 7.5), Vector2(5.0, 7.5), Vector2(8.0, 7.5), Vector2(9.6, 8.0)],
	],
}


static func has(ch: String) -> bool:
	return STROKES.has(ch)


static func get_strokes(ch: String) -> Array:
	return STROKES.get(ch, [])
