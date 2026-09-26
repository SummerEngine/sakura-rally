extends SceneTree
## Generates the procedural textures the shaders share.
##   $S --headless --disable-crash-handler --path . -s res://tools/build/gen_textures.gd
## Writes res://assets/textures/grain.png (RGBA tiling value noise:
## R fine, G coarse, B blotches, A mid) and petal.png (sakura petal cut-out).


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://assets/textures"))
	_grain()
	_petal()
	_leaf()
	print("TEXTURES OK")
	quit()


func _hash01(i: int, seed_value: int) -> float:
	var h := (i * 374761393 + seed_value * 668265263) & 0x7fffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff
	h = h ^ (h >> 16)
	return float(h & 0xffffff) / float(0xffffff)


func _tile_noise(size: int, freq: int, seed_value: int) -> PackedFloat32Array:
	var lat := PackedFloat32Array()
	lat.resize(freq * freq)
	for i in freq * freq:
		lat[i] = _hash01(i, seed_value)
	var out := PackedFloat32Array()
	out.resize(size * size)
	var s := float(freq) / float(size)
	for y in size:
		var fy := y * s
		var j := int(floor(fy))
		var v := fy - j
		v = v * v * (3.0 - 2.0 * v)
		var j0 := j % freq
		var j1 := (j + 1) % freq
		for x in size:
			var fx := x * s
			var i := int(floor(fx))
			var u := fx - i
			u = u * u * (3.0 - 2.0 * u)
			var i0 := i % freq
			var i1 := (i + 1) % freq
			var a := lat[j0 * freq + i0]
			var b := lat[j0 * freq + i1]
			var c := lat[j1 * freq + i0]
			var d := lat[j1 * freq + i1]
			out[y * size + x] = (a + (b - a) * u) * (1.0 - v) + (c + (d - c) * u) * v
	return out


func _grain() -> void:
	var n := 256
	var f1 := _tile_noise(n, 64, 1)
	var f2 := _tile_noise(n, 128, 2)
	var c1 := _tile_noise(n, 8, 3)
	var c2 := _tile_noise(n, 16, 4)
	var b1 := _tile_noise(n, 6, 5)
	var b2 := _tile_noise(n, 12, 6)
	var m1 := _tile_noise(n, 32, 7)
	var data := PackedByteArray()
	data.resize(n * n * 4)
	for i in n * n:
		data[i * 4] = int(clampf(f1[i] * 0.6 + f2[i] * 0.4, 0.0, 1.0) * 255.0)
		data[i * 4 + 1] = int(clampf(c1[i] * 0.66 + c2[i] * 0.34, 0.0, 1.0) * 255.0)
		data[i * 4 + 2] = int(clampf(b1[i] * 0.7 + b2[i] * 0.3, 0.0, 1.0) * 255.0)
		data[i * 4 + 3] = int(clampf(m1[i], 0.0, 1.0) * 255.0)
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, data)
	img.save_png("res://assets/textures/grain.png")


## Petal: notched tip, R = shade (deeper at the base), A = shape.
func _petal() -> void:
	var s := 64
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	for y in s:
		for x in s:
			var px := (x + 0.5) / s * 2.0 - 1.0 # -1..1
			var py := 1.0 - (y + 0.5) / s # 0 base .. 1 tip
			# teardrop width profile, widest at 0.55
			var w := sin(clampf(py / 0.95, 0.0, 1.0) * PI) * 0.62 * (0.6 + 0.4 * py)
			var inside := absf(px) < w and py > 0.04 and py < 0.95
			# notch at the tip
			if py > 0.8 and absf(px) < (py - 0.8) * 0.9:
				inside = false
			var shade := clampf(0.55 + py * 0.6, 0.0, 1.0)
			img.set_pixel(x, y, Color(shade, shade, shade, 1.0 if inside else 0.0))
	img.save_png("res://assets/textures/petal.png")


## Maple leaf silhouette (5 lobes), same encoding as the petal.
func _leaf() -> void:
	var s := 64
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	for y in s:
		for x in s:
			var p := Vector2((x + 0.5) / s * 2.0 - 1.0, (y + 0.5) / s * 2.0 - 1.0)
			p.y += 0.12
			var r := p.length()
			var a := atan2(p.x, -p.y)
			var lobes := 0.62 + 0.3 * pow(absf(cos(a * 2.5)), 2.0) - 0.18 * absf(a) / PI
			var inside := r < lobes
			# stem
			if absf(p.x) < 0.035 and p.y > 0.0 and p.y < 0.85:
				inside = true
			var shade := clampf(0.7 + 0.3 * (1.0 - r), 0.0, 1.0)
			img.set_pixel(x, y, Color(shade, shade, shade, 1.0 if inside else 0.0))
	img.save_png("res://assets/textures/leaf.png")
