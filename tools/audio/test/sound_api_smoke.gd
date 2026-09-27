extends SceneTree
## Headless smoke test for the Sound autoload: calls every documented API entry point with
## every documented argument plus unknown names, flips settings, pause and slow motion, and
## prints the bus layout. Unknown names must only warn (once), never error.
## Run: $S --headless --disable-crash-handler --path . -s res://tools/audio/test/sound_api_smoke.gd


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var sound := root.get_node("Sound")
	var game := root.get_node("Game")
	for i in AudioServer.bus_count:
		var effects: Array[String] = []
		for e in AudioServer.get_bus_effect_count(i):
			effects.append(AudioServer.get_bus_effect(i, e).get_class())
		print("BUS %s -> %s  %.1f dB  %s" % [AudioServer.get_bus_name(i), AudioServer.get_bus_send(i),
			AudioServer.get_bus_volume_db(i), ", ".join(effects)])
	for n in [&"hover", &"click", &"back", &"start", &"toggle", &"nope"]:
		sound.play_ui(n)
	for n in [&"countdown", &"go", &"checkpoint", &"finish", &"record", &"arrived", &"campaign_complete", &"nope"]:
		sound.play_stinger(n)
	sound.play_music(&"menu", 0.3)
	await create_timer(0.4).timeout
	sound.play_music(&"drive", 0.5)
	sound.play_music(&"drive", 0.5) # same track again: no restart
	await create_timer(0.2).timeout
	sound.play_music(&"results", 0.0)
	sound.play_music(&"liaison", 0.3)
	sound.play_music(&"missing_track")
	sound.play_ambience(0.2)
	await create_timer(0.3).timeout
	sound.set_ambience_mix(Vector3(0.0, 0.0, 1.0))
	sound.set_ambience_mix(Vector3(0.0, 0.5, 0.5))
	sound.play_ambience() # playing already: harmless
	sound.set_ambience_mix(Vector3(1.0, 0.0, 0.0))
	for n in [&"impact_light", &"impact_heavy", &"thump", &"stone", &"backfire", &"blowoff", &"shift", &"bogus"]:
		sound.play_3d(n, Vector3(1, 0, -3), -3.0)
	sound.play_3d(&"res://assets/audio/car/stone_1.wav", Vector3.ZERO)
	sound.play_3d(&"res://does/not/exist.wav", Vector3.ZERO)
	sound.set_slowmo(0.3)
	await create_timer(0.4).timeout
	print("SLOWMO ", snappedf(sound.slowmo, 0.01))
	sound.set_slowmo(1.0)
	sound.set_slowmo(5.0)
	game.set_state(game.State.RACING)
	game.set_paused(true)
	await create_timer(0.4).timeout
	game.set_paused(false)
	var old_music: float = game.get_setting("music_volume")
	game.set_setting("music_volume", 0.0)
	print("MUSIC BUS muted=%s" % AudioServer.is_bus_mute(AudioServer.get_bus_index("Music")))
	game.set_setting("music_volume", old_music)
	game.set_setting("master_volume", 0.5)
	print("MASTER %.2f dB" % AudioServer.get_bus_volume_db(0))
	sound.stop_music(0.2)
	sound.stop_ambience(0.0)
	sound.stop_music(0.2) # stopping twice is harmless
	await create_timer(0.5).timeout
	print("SOUND API SMOKE OK")
	game.request_quit()
