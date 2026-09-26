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
	# ...unload the map, start the menu flyover...
	Game.set_state(Game.State.MENU)
	ui.transition_in()
```

`scripts/ui/preview/mock_driver.gd` implements exactly this flow and is the reference.

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
| `state_changed` -> `MENU` | Title menu plays its intro (brush 桜, wordmark, hanko, cards). |
| `start_requested` / `LOADING` | Title leaves (chosen card pops, the rest slides away). |
| `session_started`, `INTRO` | HUD configured for the map/mode; intro title card slides in. |
| `countdown_tick(3,2,1,0)` | Kinetic numerals over 三/二/一, ring sweep; GO! + 出発 with ink splash + flash. Plays `Sound.play_stinger(&"countdown"/&"go")`. |
| `COUNTDOWN`, `RACING`, `FREE_ROAM` | HUD slides in (time trial: timer + progress; free roam: odometer, no timer). |
| `checkpoint_passed` | Split popup under the timer (delta green/red vs best, none on a first run), progress tick pulses, timer pops. `play_stinger(&"checkpoint")`. |
| `notice(text)` | Centre paper pill for ~2 s (only while the HUD is up). |
| `race_finished(result)` | FINISH 完走 slam, time count-up, results card, medal hanko stamp, NEW RECORD ribbon. `play_stinger(&"finish")`, `&"record"`. Buttons: Retry (`request_restart`), Next map (`request_start(next, time_trial)`, liaison maps skipped), Menu (`request_menu`). A campaign stage (`result.campaign`) adds a "Rally standing" row and swaps the buttons for Continue (`request_campaign_continue`, focused), Retry stage, Quit to title. |
| `paused_changed` | Pause menu (blurred backdrop): Resume / Restart / Settings / Main menu. In the campaign: Resume / Retry stage (stages only) / Settings / Quit to title. |

The UI owns the **`pause` action** (Esc / P / gamepad Start): it calls `Game.set_paused(true)`
during `COUNTDOWN`, `RACING`, `FREE_ROAM`, `LIAISON`, and `Game.set_paused(false)` from the
pause menu (`pause` or `ui_cancel` again resumes). Main should not also handle `pause`.

UI sounds: every button calls `Sound.play_ui(&"hover")` on focus/hover and `&"click"` /
`&"start"` / `&"back"` on press; pickers use `&"toggle"`. Music and ambience are left to Main
(`Sound.play_music(&"menu"/&"drive"/&"results")`) since it knows when scenes are ready.

Settings written by the UI (`Game.set_setting`): `master_volume`, `music_volume`,
`sfx_volume`, `quality`, `transmission`, `camera`, `units`, `fullscreen`, `car_color`.
The UI reads `units` for speed/odometer display. Applying volumes / quality / camera /
livery is the job of Sound / Main / the car (listen to `Game.settings_changed`).

Map cards use `MAPS[i].preview` when that texture exists; otherwise a procedural painted
landscape in the season palette (`shaders/ui/painted_scene.gdshader`).

## Campaign screens

The campaign (`Game.CAMPAIGN`, docs/CONTRACTS.md "Session and campaign") adds four screens,
switched by the UI root from `Game.state` like the rest:

| State / event | Screen |
|---|---|
| `JOURNEY` | **Journey map** (`screens/journey_map.gd`, `shaders/ui/journey_map.gdshader`): a painted washi map of the rally, spring greens through a summer bay to autumn maples, with the legs as hanko seals (春 夏 秋) on a dotted road from the start flag to the goal. It is the campaign's loading screen: the map washes in, the road is inked on at 12 fps, a leg just finished gets its seal slammed down (medal colour, time under it; ARRIVED on a liaison) with a petal burst, and the player's car (in its livery) drives to the next leg while that leg's map loads behind it. The right-hand card names the next leg (kicker, brush title, gold / best, "untimed" for a liaison) with a spinner and a loading line. Main awaits `ui.journey.travel_done` before covering the screen again. |
| `INTRO` (campaign) | The race intro card gets a kicker line: "SS1 · SPECIAL STAGE 1 OF 2", "L1 · LIAISON → MOMIJI VALLEY"; a liaison shows the distance to go instead of the best time. |
| `LIAISON` | **Liaison HUD** (`screens/liaison_hud.gd`): no timer. Top-left a blue Japanese road-direction sign to the next stage (brush name, distance left, a strip map of the road with the car dot and the time-control flag); bottom-right a small paper speed / gear card. Notices use the same centre pill as the race HUD. |
| `ARRIVED` | **Arrival card** (`screens/arrival_card.gd`): ARRIVED over an indigo brush swash with 到着 painted beneath, the destination and the next stage slide in and a time-control seal is stamped (`play_stinger(&"arrived")`). Main has already taken the car over within braking distance of the time control (notice "Time control ahead"); it rolls to rest there under a roadside shot, then the journey map follows. |
| `campaign_finished(summary)`, `FINALE` | **Finale** (`screens/campaign_finale.gd`), over a flyover of the last map: the rally classification (you and the rivals of `Game.RIVALS`, per-stage times with medal seals, total and gap) lands row by row from last place up on 12 fps steps, your row washed in sakura, then your position seal is stamped (`play_stinger(&"campaign_complete")`). Continue (or Esc) sinks the scene into ink for the end card: 完 painted large, SAKURA RALLY, the legs, the rivals, "Thanks for driving.", and Back to title (`request_menu`); the title then shows the campaign as finished (Replay). |

Tools: `tools/game/flows.gd -- flow=campaign` drives the whole campaign with checks
(headless or windowed; windowed saves a frame of every campaign screen to `out`), and
`tools/game/playthrough.gd -- mode=campaign` is the screenshot / FPS / audio-recording tour.

## Input

Everything works with keyboard, gamepad and mouse. Focus navigation uses Godot's `ui_*`
actions (arrows / d-pad / left stick, Enter / A to accept, Esc / B to go back; the engine's
built-in `ui_accept` / `ui_cancel` are keyboard-only, so `Game` adds A and B to them). Pickers
(mode, livery, settings rows) are a single focus stop each: left/right change the value,
up/down move between rows. Mouse hover moves focus, so the single sakura focus ring
(`widgets/focus_ring.gd`) always shows where you are. Keycap hints on the title switch to
gamepad glyphs after gamepad input.

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
- `scripts/ui/screens/` - `title_screen`, `settings_panel`, `transition_layer`, `race_intro`, `hud`, `results_screen`, `pause_menu`.
- `scripts/ui/widgets/` - `paper_card` (frosted washi card), `brush_kanji` (+ `kanji_strokes` stroke-order data), `kinetic_text`, `hanko`, `petal_field`, `map_card`, `segmented`, `paper_slider`, `livery_swatches`, `ink_button`, `focus_ring`, `key_hints`, `tachometer`, `stage_progress`, `sakura_spinner`, `shader_rect`.
- `shaders/ui/` - `paper_card`, `brush_reveal` (stroke-order kanji), `brush_band` (paint swash), `ink_wipe` (transition), `ink_splash` (GO!), `hanko`, `painted_scene`, `backdrop_blur`, shared `ui_common.gdshaderinc`.
- `scripts/ui/preview/` - `mock_driver`, `mock_car`, `mock_session`, `capture_runner`.
- `assets/fonts/` - subsets of Zen Maru Gothic (Medium/Bold/Black), Dela Gothic One, Yuji Syuku, with their OFL licences.
- `tools/ui/subset_fonts.py` - re-subsets the fonts; run after adding new Japanese text
  (it scans `scripts/` and `scenes/` for kana/kanji): `tools/ui/.venv/bin/python tools/ui/subset_fonts.py`
  (venv: `uv venv tools/ui/.venv && uv pip install --python tools/ui/.venv/bin/python fonttools brotli`).
- Campaign: `scripts/ui/screens/journey_map.gd`, `liaison_hud.gd`, `arrival_card.gd`, `campaign_finale.gd`; `shaders/ui/journey_map.gdshader`.

## Fonts and rendering notes

- Fonts are `preload`ed through `UITheme` constants. The display faces (Dela Gothic One,
  Yuji Syuku) import as MSDF so the huge countdown numerals and brush kanji stay crisp at any
  scale.
- Only the kanji present in the source are in the subset fonts. New Japanese strings need a
  re-run of `subset_fonts.py` (missing glyphs render as boxes).
