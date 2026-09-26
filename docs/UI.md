# Sakura Rally - UI layer

Everything the player sees on top of the 3D world: title menu, settings, ink transitions,
race intro + countdown, HUD, finish + results, pause. Pure GDScript, built in code (no
hand-edited Control trees), driven only by the `Game` / `Sound` autoload APIs from
`docs/CONTRACTS.md`.

## Integrating in Main

```gdscript
const UI_ROOT := preload("res://scenes/ui/ui_root.tscn")
var ui: CanvasLayer

func _ready() -> void:
	ui = UI_ROOT.instantiate()
	add_child(ui)                       # CanvasLayer, layer 10, PROCESS_MODE_ALWAYS
	Game.start_requested.connect(_on_start)
	Game.restart_requested.connect(_on_restart)
	Game.menu_requested.connect(_on_menu)
	Game.set_state(Game.State.MENU)     # the UI shows the title on MENU

func _on_start(map_id: String, mode: String) -> void:
	await ui.transition_out(map_id)     # ink covers the screen (loading card: map kanji + name)
	Game.set_state(Game.State.LOADING)
	# ...free the old map, load map + car, set Game.player_car / Game.session...
	Game.notify_session_started(map_id, mode)
	Game.set_state(Game.State.INTRO)    # UI slides in the map title card
	ui.transition_in()                  # ink lifts off during the intro camera move
	# ...intro camera; then COUNTDOWN + notify_countdown(3,2,1,0), RACING / FREE_ROAM

func _on_menu() -> void:
	await ui.transition_out()           # loading card shows 桜 SAKURA RALLY
	# ...load the menu map; menu_stage.enter(self) spawns the menu car for Game.menu_view...
	Game.set_state(Game.State.MENU)
	ui.transition_in()
```

`scripts/ui/preview/mock_driver.gd` implements this flow and is the reference for the UI side
(it has no menu car). Main also forwards `Game.menu_view_changed(view)` to
`menu_stage.set_view(view)` and, while the menu shows, `Game.settings_changed` to
`menu_stage.apply_car_settings()`.

### UI root API (`scripts/ui/ui_root.gd`)

| Call | Effect |
|---|---|
| `transition_out(map_id := "") -> Signal` | Brush-ink wipe covers the screen; the signal fires when fully covered. `await` it, then load behind it. |
| `transition_in() -> Signal` | Ink lifts off (towards the right); fires when the screen is clear. |
| `is_screen_covered() -> bool` | True between the two. |
| `set_hud_visible(bool)` | Race HUD only (replays, photo mode). |
| `set_ui_visible(bool)` | Whole UI. **F1** toggles it for clean video capture. |
| `shake(strength)` | Small UI screen shake (used by the finish slam and the medal stamp). |

### What the UI does on its own

| Game event | UI reaction |
|---|---|
| `state_changed` -> `MENU` | Title hub plays its intro (brush 桜, wordmark, hanko, hub items); back from a Time Attack drive it reopens the Time Attack page. |
| `start_requested` / `LOADING` | Title leaves (the chosen map card pops, the rest slides away). |
| `session_started`, `INTRO` | HUD configured for the map/mode; intro title card slides in. |
| `countdown_tick(3,2,1,0)` | Kinetic numerals over 三/二/一, ring sweep; GO! + 出発 with ink splash + flash. Plays `Sound.play_stinger(&"countdown"/&"go")`. |
| `COUNTDOWN`, `RACING`, `FREE_ROAM` | HUD slides in (time trial: timer + progress; free roam: odometer, no timer). |
| `checkpoint_passed` | Split popup under the timer (delta green/red vs best, none on a first run), progress tick pulses, timer pops. `play_stinger(&"checkpoint")`. |
| `notice(text)` | Centre paper pill for ~2 s (only while the HUD is up). |
| `race_finished(result)` | FINISH 完走 slam, time count-up, results card, medal hanko stamp, NEW RECORD ribbon. `play_stinger(&"finish")`, `&"record"`. Buttons: Retry (`request_restart`), Next map (`request_start(next, time_trial)`, the other stage), Menu (`request_menu`). A campaign stage (`result.campaign`) says the stage is complete, adds a "Rally standing" row and the next-stage road sign beside the card, and swaps the buttons for Continue (`request_campaign_continue`, focused), Retry stage, Quit to title (see Campaign screens). |
| `paused_changed` | Pause menu (blurred backdrop): Resume / Restart / Settings / Main menu. In the campaign: Resume / Retry stage (stages only) / Settings / Quit to title. |

The UI owns the **`pause` action** (Esc / P / gamepad Start): it calls `Game.set_paused(true)`
during `COUNTDOWN`, `RACING`, `FREE_ROAM`, `LIAISON`, and `Game.set_paused(false)` from the
pause menu (`pause` or `ui_cancel` again resumes). Main should not also handle `pause`.

UI sounds: every button calls `Sound.play_ui(&"hover")` on focus/hover and `&"click"` /
`&"start"` / `&"back"` on press; pickers use `&"toggle"`. Music and ambience are left to Main
(`Sound.play_music(&"menu"/&"drive"/&"results")`) since it knows when scenes are ready.

Settings written by the UI (`Game.set_setting`): `master_volume`, `music_volume`,
`sfx_volume`, `quality`, `transmission`, `camera`, `units`, `fullscreen`, `car_id`, `car_color`.
The UI reads `units` for speed/odometer display. Applying volumes / quality / camera is the job
of Sound / Main / the car (listen to `Game.settings_changed`); the menu car follows `car_id` /
`car_color` through `MenuStage` (below).

## Title hub

`screens/title_screen.gd` is a hub over the live flyover: logo, wordmark, hanko, petals and
mouse parallax as in episode 1, and a column of `widgets/hub_item.gd` entries (brush kanji,
tracked overline, title; focus paints a brush swash behind the item, nudges it right and turns
the kanji vermilion; the swash is the focus indicator, so the global ring skips hub items):

| Item | Does |
|---|---|
| 旅 Campaign | Label from `Game.campaign_status()`, counted in stages (the road between them is part of the drive): "New journey" (overline "2 STAGES"), "Continue · <next leg title>" (overline "STAGE n OF m", or "STAGE n OF m COMPLETE" when the road on is next), "Replay journey" once finished. A `widgets/journey_strip.gd` under it draws the stages as stamps joined by the road (driven / next / ahead, season tints). Press = `Game.request_campaign(fresh)`: continues an unfinished journey, otherwise starts one. |
| Start a new journey | Only while a journey is in progress. Asks first (`widgets/confirm_dialog.gd`, focus on "Keep going", Esc = keep), then `request_campaign(true)`. |
| 時 Time Attack | Opens the Time Attack page. |
| 車 Garage | Opens the garage (overline shows the current car and livery). |
| Settings / Quit | Settings panel / `Game.request_quit()`. |

Pages slide in over the hub inside the parallax layer; Esc / B / "Back" returns to the hub
and to the item that opened the page. The page showing is mirrored to
`Game.set_menu_view("title" | "time_attack" | "garage")`.

Entrances call `UIMotion.layout_now(node)` (sorts the containers under it on the spot) before
reading positions for their tweens. Don't wait for a drawn frame instead: on a first launch
the pipeline compiles keep the window from drawing for seconds while the game keeps
processing, and the intro would start seconds late (episode 2's first-run title came up
without its wordmark that way). `KineticText` runs on tweens for the same reason: every intro element
shares one clock, so a long frame moves the wordmark exactly as far as the logo and hanko.

**Time Attack** (`screens/time_attack_panel.gd`): Time Trial / Free Roam picker over one card
per stage of the world (`Game.MAPS`: Hanami, Momiji; the liaison is the road between them, not
a level). A card calls `Game.request_start(map_id, mode)`: a time trial drives that stage's loop
with the branch gates closed, free roam starts on the same grid with every gate open.

**Map cards** (`widgets/map_card.gd`): the map's top-down render
(`assets/ui/maps/<id>_top.png`, rounded top corners, `shaders/ui/map_image.gdshader`) with
`widgets/route_overlay.gd` on top: an ink-outlined route coloured by surface (tarmac / gravel
/ dirt), start and finish flags, checkpoint dots, and a legend chip with the length and the
surfaces. On focus the card lifts, the map zooms, the route redraws itself along its length
(0.9 s, out-expo) and a small car marker loops along it. Best time and medal sit in the
footer. The card draws its own focus outline as a
child of the lifted layer (same transform and corner radius, so no offset or lag during lift
and parallax) and sets `no_focus_ring`. A card without art shows a flat season-tinted panel.

**Garage** (`screens/garage_panel.gd`): a washi card on the left with
`widgets/car_selector.gd` (Game.CARS name, kanji, tagline, spec, animated stat bars for speed,
acceleration, grip, drift; left / right or the arrows switch) and `widgets/livery_picker.gd`
(paint-chip cards: an ink-edged brush stroke of the body colour over the stripe colour, the
livery's name and kanji; left / right or click). Only cars whose scene exists in the project are
listed. Choices save at once (`car_id`, `car_color`). Opening and closing the garage hides the
camera cut under a short ink wipe.

**Menu car** (`scripts/game/menu_stage.gd`, created by Main): spawns the selected car and
livery for the menu. In `"title"` / `"time_attack"` it laps under the autopilot with the cine
flyover; in `"garage"` it parks on the map's start grid (autopilot off, brakes held) while
`CineCamera.start_garage()` orbits it low and slow, off-centre to the right of the panel
(it swings through the widest arc clear of props and terrain, and backs off on narrow screens
so the car fits). A livery pick in the garage paints the new colour over the body with a brush
front from nose to tail (`shaders/ui/paint_sweep.gdshader`, 0.8 s, ink line on the front); a car
pick drops the other car onto the grid. Outside the garage both apply at once, so the flyover
always shows the chosen car and livery. After a liaison or a Free Roam on an open road
(`MapWorld.closed == false`) Main loads the menu map under the ink instead: the flyover
autopilot needs a closed loop.

### Top-down card art

`tools/build/capture_topdown.gd` builds the world once, then per stage route selects it, turns
off fog, clouds and petals, and renders it straight down with an orthographic camera framed on
the route bounds plus a margin at the card's aspect, in the game's toon + ink look and that
stage's season (the world's look follows the camera), at 3x and downsampled. It writes
`assets/ui/maps/<id>_top.png` (904 x 520) and `<id>_route.json` (format in
`docs/CONTRACTS.md`, route points every 8 m). It needs pixels (offscreen or a window; headless
has none); re-run it whenever the world's layout changes:

```
timeout 300 $S --summer-offscreen --audio-driver Dummy --disable-crash-handler --path . \
    -s res://tools/build/capture_topdown.gd -- hanami momiji
timeout 400 $S --headless --disable-crash-handler --path . --import
```

### Menu tour in the real game

`tools/ui/menu_tour.gd` drives the real title hub (live flyover, real menu car) with the ui_*
actions: hub, Time Attack, garage with every livery (one frame mid-sweep), a car switch when a
second car scene exists, and back to the flyover. It checks that the wordmark is settled and
drawn on the title frame (ink pixels in its rect), parking, saved
choices, the paint on the car, the respawned car's scene and the resumed autopilot, and saves
`<out>/menu_<shot>_<aspect>.png`:

```
for a in 16x9 21x9 16x10; do
  timeout 300 $S --disable-crash-handler --path . -s res://tools/ui/menu_tour.gd -- aspect=$a out=/tmp/menu_tour
done
```

## Campaign screens

The campaign (`Game.CAMPAIGN`: SS1 Hanami, L1 the road on, SS2 Momiji; docs/CONTRACTS.md
"Campaign in one world") is one continuous drive through the world with no cover or loading
between legs. The UI root switches its screens from `Game.state` like the rest:

| State / event | Screen |
|---|---|
| `race_finished` (campaign stage) | **Results** say the stage is complete (kicker "SS1 · STAGE COMPLETE": time, medal, rally standing) while the car rolls to rest at the stage's finish stop behind them. A blue road sign swings in beside the card with what comes next: "NEXT · SS2", 紅葉谷 Momiji Valley, "Drive on: the road is open." and the road distance to it; after the last stage "NEXT · THE FINALE". Continue (focused) hides the card at once: the branch gate opens in view over the resting car, then the drive goes on from where the car stopped. |
| `INTRO` (campaign) | The race intro is the stage's **start card**: kicker "SS1 · SPECIAL STAGE 1 OF 2", the stage name, gold / best. SS2's plays on the spot at Momiji's grid right after the arrival, then the countdown. A liaison resumed from the title gets "DRIVE ON → SS2 START" and the destination's name with the distance to go. |
| `LIAISON` | **Liaison HUD** (`screens/liaison_hud.gd`): no timer, no leg code. Top-left a blue Japanese road-direction sign to the next stage's place (紅葉谷 Momiji Valley, "SS2 START", distance left, a strip map of the road with the car dot and the start flag); bottom-right a small paper speed / gear card. Notices use the same centre pill as the race HUD. |
| `ARRIVED` | **Arrival card** (`screens/arrival_card.gd`): ARRIVED over an indigo brush swash with 到着 painted beneath, the destination and "SS2 GRID · THE STAGE STARTS HERE" slide in and a seal with the stage code is stamped (`play_stinger(&"arrived")`). Main has already taken the car over within braking distance of the grid (notice "SS2 start ahead"); it rolls to rest there under a roadside shot, then the stage's start card follows. |
| `campaign_finished(summary)`, `FINALE` | **Finale** (`screens/campaign_finale.gd`), over a flyover of the Momiji loop: the rally classification (you and the rivals of `Game.RIVALS`, per-stage times with medal seals, total and gap) lands row by row from last place up on 12 fps steps, your row washed in sakura, then your position seal is stamped (`play_stinger(&"campaign_complete")`). Continue (or Esc) sinks the scene into ink for the end card: 完 painted large, SAKURA RALLY, the stages, the rivals, "Thanks for driving.", and Back to title (`request_menu`); the title then shows the campaign as finished (Replay). |

The title's Campaign item shows the progress as stages (`widgets/journey_strip.gd`: a stamp per
stage joined by the road, driven / next / ahead) and resumes at the saved leg: SS1 on Hanami's
grid, the road on from Hanami's finish stop with the gate open, SS2 on Momiji's grid.

Tools: `tools/game/flows.gd -- flow=campaign` drives the whole campaign with checks (no LOADING
between the stages, the car's pose across Continue, the gate, the arrival at rest, resume at
every leg; headless or offscreen, offscreen saves a frame of every campaign screen to `out`),
and `tools/game/playthrough.gd -- mode=campaign` is the screenshot / FPS / audio-recording tour.

## Input

Everything works with keyboard, gamepad and mouse. Focus navigation uses Godot's `ui_*`
actions (arrows / d-pad / left stick, Enter / A to accept, Esc / B to go back; the engine's
built-in `ui_accept` / `ui_cancel` are keyboard-only, so `Game` adds A and B to them). Pickers
(mode, livery, car, settings rows) are a single focus stop each: left/right change the value,
up/down move between rows. Mouse hover moves focus. The sakura focus ring
(`widgets/focus_ring.gd`) glides to each newly focused control and then follows it exactly;
hub items and map cards draw their own focus (meta `no_focus_ring`). Keycap hints on the title
switch to gamepad glyphs after gamepad input.

## Preview harness

```
S=/Applications/Summer.app/Contents/MacOS/Summer
$S --disable-crash-handler --path . res://scenes/ui/preview/ui_preview.tscn
```

A painted landscape stands in for the 3D world, a mock car (autopilot or W/S) and mock
session feed the HUD, and the driver plays the Main role (transitions, loading, intro,
countdown, finish). Extra keys: **F2** notice, **F3** next checkpoint, **F4** finish now
(gold record), **F5** finish now (slow, bronze), **F6** cycle window aspect 16:9 / 16:10 /
21:9, **F1** hide UI. Records set in the preview are restored on exit, so the player's save
is untouched.

Automated screenshot tour (drives the UI with the same input actions a player uses):

```
for a in 16x9 21x9 16x10; do
  timeout 200 $S --disable-crash-handler --path . res://scenes/ui/preview/ui_preview.tscn -- --capture=$a
done
```

Writes `docs/renders/ui_<screen>_<aspect>.png` and, for 16:9 and 21:9, animation contact
sheets `docs/renders/ui_anim_<name>_<aspect>.png` (frames left-to-right, top-to-bottom).

## Files

- `scenes/ui/ui_root.tscn`, `scripts/ui/ui_root.gd` - entry point, screen switching, pause input, shake, F1.
- `scripts/ui/ui_theme.gd` - palette, fonts, shared Theme (paper pills, vermilion primary, quiet).
- `scripts/ui/ui_motion.gd` - easing curves (expo, back, spring, 12-fps stepping) and tween helpers; all UI motion ignores `Engine.time_scale` and runs while paused.
- `scripts/ui/ui_api.gd` - `Game` / `Sound` access by node path (also works from `-s` tool scripts).
- `scripts/ui/screens/` - `title_screen` (hub), `time_attack_panel`, `garage_panel`, `settings_panel`, `transition_layer`, `race_intro`, `hud`, `results_screen`, `pause_menu`.
- `scripts/ui/widgets/` - `paper_card` (frosted washi card), `brush_kanji` (+ `kanji_strokes` stroke-order data), `kinetic_text`, `hanko`, `petal_field`, `hub_item`, `journey_strip`, `confirm_dialog`, `map_card`, `route_overlay`, `car_selector`, `livery_picker`, `segmented`, `paper_slider`, `ink_button`, `focus_ring`, `key_hints`, `tachometer`, `stage_progress`, `sakura_spinner`, `shader_rect`.
- `scripts/game/menu_stage.gd` - the menu car (flyover / garage parking, livery sweep, car switch).
- `shaders/ui/` - `paper_card`, `brush_reveal` (stroke-order kanji), `brush_band` (paint swash), `ink_wipe` (transitions), `ink_splash` (GO!), `hanko`, `map_image` (card art), `paint_sweep` (garage livery change, 3D), `painted_scene` (preview backdrop), `backdrop_blur`, shared `ui_common.gdshaderinc`.
- `assets/ui/maps/` - top-down card art and route data per map (`tools/build/capture_topdown.gd`).
- `tools/ui/menu_tour.gd` - real-game title hub / garage tour (above).
- `scripts/ui/preview/` - `mock_driver`, `mock_car`, `mock_session`, `capture_runner`.
- `assets/fonts/` - subsets of Zen Maru Gothic (Medium/Bold/Black), Dela Gothic One, Yuji Syuku, with their OFL licences.
- `tools/ui/subset_fonts.py` - re-subsets the fonts; run after adding new Japanese text
  (it scans `scripts/` and `scenes/` for kana/kanji): `tools/ui/.venv/bin/python tools/ui/subset_fonts.py`
  (venv: `uv venv tools/ui/.venv && uv pip install --python tools/ui/.venv/bin/python fonttools brotli`).
- Campaign: `scripts/ui/screens/liaison_hud.gd`, `arrival_card.gd`, `campaign_finale.gd`; the results' next-stage sign lives in `results_screen.gd`.

## Fonts and rendering notes

- Fonts are `preload`ed through `UITheme` constants. The display faces (Dela Gothic One,
  Yuji Syuku) import as MSDF so the huge countdown numerals and brush kanji stay crisp at any
  scale.
- Only the kanji present in the source are in the subset fonts. New Japanese strings need a
  re-run of `subset_fonts.py` (missing glyphs render as boxes).
