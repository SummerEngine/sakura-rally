extends SceneTree
## Headless smoke: engine version, physics engine, autoloads, input map.

func _initialize() -> void:
	await process_frame
	print("ENGINE ", Engine.get_version_info().string)
	print("PHYSICS ", ProjectSettings.get_setting("physics/3d/physics_engine"))
	print("GAME ", root.get_node_or_null("Game") != null, " SOUND ", root.get_node_or_null("Sound") != null)
	print("ACTIONS ", InputMap.has_action("throttle"), " ", InputMap.has_action("handbrake"))
	print("BUSES ", AudioServer.bus_count)
	var g = root.get_node("Game"); print("TIME ", g.format_time(83.4567), " ", g.format_delta(-0.43), " MAPS ", g.MAPS.size())
	quit()
