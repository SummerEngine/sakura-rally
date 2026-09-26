extends RefCounted
## Palette, fonts and the shared Theme for the whole UI layer.
## Every colour and type decision in scripts/ui derives from the constants here.

# ---------------------------------------------------------------- palette
const INK := Color("2a2235")
const INK_SOFT := Color(0.165, 0.133, 0.208, 0.62)
const INK_FAINT := Color(0.165, 0.133, 0.208, 0.12)
const PAPER := Color("fbf5ec")
const PAPER_WARM := Color("f4ede0")
const SAKURA := Color("e8517c")
const SAKURA_SOFT := Color("f49ab4")
const SAKURA_PALE := Color("fcd9e3")
const VERMILION := Color("e44a30")
const GOLD := Color("f2c552")
const GOLD_DEEP := Color("c9962a")
const SILVER := Color("b9bccb")
const BRONZE := Color("c98a5a")
const MATCHA := Color("5d9a4c")
const MAPLE := Color("e75b3d")
const MAPLE_GOLD := Color("f5b04a")
const SKY := Color("6aa8e8")
const WHITE := Color(1, 1, 1)

# ---------------------------------------------------------------- fonts
const FONT_UI_MEDIUM := preload("res://assets/fonts/ZenMaruGothic-Medium.ttf")
const FONT_UI_BOLD := preload("res://assets/fonts/ZenMaruGothic-Bold.ttf")
const FONT_UI_BLACK := preload("res://assets/fonts/ZenMaruGothic-Black.ttf")
const FONT_TITLE := preload("res://assets/fonts/DelaGothicOne-Regular.ttf")
const FONT_BRUSH := preload("res://assets/fonts/YujiSyuku-Regular.ttf")

const RADIUS_CARD := 26
const RADIUS_PILL := 999

static var _theme: Theme


## Accent colour for a map season ("spring" -> sakura, "autumn" -> maple).
static func season_accent(season: String) -> Color:
	return MAPLE if season == "autumn" else SAKURA


static func medal_color(medal: String) -> Color:
	match medal:
		"gold":
			return GOLD
		"silver":
			return SILVER
		"bronze":
			return BRONZE
	return INK_SOFT


static func medal_kanji(medal: String) -> String:
	match medal:
		"gold":
			return "金"
		"silver":
			return "銀"
		"bronze":
			return "銅"
	return "完"


## Tracked font: letter spacing in pixels on top of the base face.
static func tracked(base: Font, spacing: int) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = base
	fv.spacing_glyph = spacing
	return fv


static func pill(bg: Color, shadow_alpha: float = 0.14, border: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(RADIUS_PILL)
	sb.corner_detail = 12
	sb.content_margin_left = 26
	sb.content_margin_right = 26
	sb.content_margin_top = 13
	sb.content_margin_bottom = 13
	sb.shadow_color = Color(INK, shadow_alpha)
	sb.shadow_size = 14 if shadow_alpha > 0.0 else 0
	sb.shadow_offset = Vector2(0, 5)
	sb.anti_aliasing_size = 1.2
	if border.a > 0.0:
		sb.border_color = border
		sb.set_border_width_all(2)
	return sb


static func label_settings(font: Font, size: int, color: Color, shadow: bool = false) -> LabelSettings:
	var ls := LabelSettings.new()
	ls.font = font
	ls.font_size = size
	ls.font_color = color
	if shadow:
		ls.shadow_color = Color(INK, 0.35)
		ls.shadow_size = 10
		ls.shadow_offset = Vector2(0, 2)
	return ls


static func make_label(text: String, font: Font, size: int, color: Color, shadow: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.label_settings = label_settings(font, size, color, shadow)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Shared Theme: paper-pill buttons, ink text, focus handled by UIFocusRing (empty focus box).
static func get_theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = FONT_UI_BOLD
	t.default_font_size = 22
	t.set_color("font_color", "Label", INK)

	var normal := pill(Color(PAPER, 0.86))
	var hover := pill(Color(1, 1, 1, 0.97), 0.2)
	var pressed := pill(Color(PAPER_WARM, 0.97), 0.08)
	var disabled := pill(Color(PAPER, 0.45), 0.0)
	t.set_stylebox("normal", "Button", normal)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("hover_pressed", "Button", pressed)
	t.set_stylebox("disabled", "Button", disabled)
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	for c in ["font_color", "font_hover_color", "font_focus_color", "font_hover_pressed_color", "font_pressed_color"]:
		t.set_color(c, "Button", INK)
	t.set_color("font_disabled_color", "Button", INK_SOFT)
	t.set_font("font", "Button", FONT_UI_BOLD)
	t.set_font_size("font_size", "Button", 22)
	t.set_constant("h_separation", "Button", 12)

	# Primary button variation: vermilion, white text (Retry / Resume / Start).
	t.set_type_variation("PrimaryButton", "Button")
	t.set_stylebox("normal", "PrimaryButton", pill(VERMILION, 0.3))
	t.set_stylebox("hover", "PrimaryButton", pill(VERMILION.lightened(0.08), 0.36))
	t.set_stylebox("pressed", "PrimaryButton", pill(VERMILION.darkened(0.08), 0.18))
	t.set_stylebox("hover_pressed", "PrimaryButton", pill(VERMILION.darkened(0.08), 0.18))
	t.set_stylebox("focus", "PrimaryButton", StyleBoxEmpty.new())
	for c in ["font_color", "font_hover_color", "font_focus_color", "font_hover_pressed_color", "font_pressed_color"]:
		t.set_color(c, "PrimaryButton", WHITE)

	# Quiet text button (Quit, Back): no fill until hovered.
	t.set_type_variation("QuietButton", "Button")
	t.set_stylebox("normal", "QuietButton", pill(Color(PAPER, 0.0), 0.0))
	t.set_stylebox("hover", "QuietButton", pill(Color(PAPER, 0.8), 0.1))
	t.set_stylebox("pressed", "QuietButton", pill(Color(PAPER_WARM, 0.9), 0.0))
	t.set_stylebox("hover_pressed", "QuietButton", pill(Color(PAPER_WARM, 0.9), 0.0))
	t.set_stylebox("focus", "QuietButton", StyleBoxEmpty.new())
	for c in ["font_color", "font_hover_color", "font_focus_color", "font_hover_pressed_color", "font_pressed_color"]:
		t.set_color(c, "QuietButton", INK)
	_theme = t
	return t
