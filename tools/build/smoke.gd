extends SceneTree
## Headless smoke: engine version, physics engine, autoloads, input map, and the world: it
## builds once and every route selects (length, spawn, season at the spawn), with its gates.

func _initialize() -> void:
	await process_frame
	print("ENGINE ", Engine.get_version_info().string)
	print("PHYSICS ", ProjectSettings.get_setting("physics/3d/physics_engine"))
	print("GAME ", root.get_node_or_null("Game") != null, " SOUND ", root.get_node_or_null("Sound") != null)
	print("ACTIONS ", InputMap.has_action("throttle"), " ", InputMap.has_action("handbrake"))
	print("BUSES ", AudioServer.bus_count)
	var g = root.get_node("Game"); print("TIME ", g.format_time(83.4567), " ", g.format_delta(-0.43), " MAPS ", g.MAPS.size())
	var map := MapWorld.new()
	root.add_child(map)
	await map.build()
	print("WORLD %d ms routes=%s gates=%s garage=%s" % [map.stats["build_ms"], map.routes.keys(), map.gates.keys(),
			map.garage.origin])
	for id: String in map.routes:
		map.select_route(id)
		var w := map.season_at(map.spawn.origin)
		print("ROUTE %s closed=%s length=%.0f m checkpoints=%d spawn=%s season=(%.2f %.2f %.2f)" % [id, map.closed,
				map.track.length, map.checkpoints.size(), map.spawn.origin, w.x, w.y, w.z])
	quit()
