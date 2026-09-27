extends RefCounted
## Live frames against replay renders of the same moment (tools/replay/record_lap.gd,
## `review.gd compare`): pixel difference, side-by-side pairs and a stack of pairs.

## Pixel difference of two frames at 320 x 180: (mean absolute difference 0..255, share of
## pixels off by more than 32).
static func diff(a: Image, b: Image) -> Vector2:
	var x := a.duplicate() as Image
	var y := b.duplicate() as Image
	x.convert(Image.FORMAT_RGB8)
	y.convert(Image.FORMAT_RGB8)
	x.resize(320, 180, Image.INTERPOLATE_BILINEAR)
	y.resize(320, 180, Image.INTERPOLATE_BILINEAR)
	var da := x.get_data()
	var db := y.get_data()
	var total := 0
	var off := 0
	for i in range(0, da.size(), 3):
		var d := maxi(maxi(absi(da[i] - db[i]), absi(da[i + 1] - db[i + 1])), absi(da[i + 2] - db[i + 2]))
		total += absi(da[i] - db[i]) + absi(da[i + 1] - db[i + 1]) + absi(da[i + 2] - db[i + 2])
		if d > 32:
			off += 1
	return Vector2(total / float(da.size()), off / float(da.size() / 3))


## Live (left) and replay (right) at half size, side by side.
static func pair(a: Image, b: Image) -> Image:
	var w := a.get_width() / 2
	var h := a.get_height() / 2
	var out := Image.create(w * 2 + 8, h, false, Image.FORMAT_RGB8)
	out.fill(Color.WHITE)
	for k in 2:
		var src := (a if k == 0 else b).duplicate() as Image
		src.convert(Image.FORMAT_RGB8)
		src.resize(w, h, Image.INTERPOLATE_BILINEAR)
		out.blit_rect(src, Rect2i(0, 0, w, h), Vector2i(k * (w + 8), 0))
	return out


static func stack(rows: Array[Image]) -> Image:
	var w := rows[0].get_width()
	var h := rows[0].get_height()
	var out := Image.create(w, (h + 8) * rows.size(), false, Image.FORMAT_RGB8)
	out.fill(Color.WHITE)
	for k in rows.size():
		out.blit_rect(rows[k], Rect2i(0, 0, w, h), Vector2i(0, k * (h + 8)))
	return out
