extends Node
## Main scene: owns the loaded map, the player car, cameras and the UI layers.
## Placeholder until the integration pass; see docs/CONTRACTS.md.


func _ready() -> void:
	Game.set_state(Game.State.MENU)
