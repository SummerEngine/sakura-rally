class_name DriveEyes
extends RefCounted
## What the pixel driver sees (docs/PIXELS.md): one small RGB frame from a camera on the car's
## hood, rendered only when asked. The same camera in training (tools/rl_pixels/pixel_env.gd) and
## in the game (PixelPilot), as DriveSense and DriveHands are shared.
##
## The viewport never updates by itself: look() poses the camera and marks the viewport for one
## update, and the next RenderingServer.force_draw() (or frame drawn) renders it. The viewport
## shares its parent's World3D. It never draws GAME_ONLY_LAYER: no car is in the picture (training
## cars have no visuals), nor the game's screen effects.

const SIZE := Vector2i(128, 72)
## The camera in the car's frame (m): 3 m up (a bus driver's eye; from the 1.34 m hood the road's
## bends 50-150 m ahead were a few flat pixels), a little ahead of the car's centre.
const MOUNT := Vector3(0.0, 3.0, -0.45)
const PITCH_DEG := 10.0
## Vertical field of view, degrees (Camera3D keeps the height): about 92° across at 16:9.
const FOV := 60.0
## How far the camera's up leans from the car's up to the world's: body roll tilts the picture
## less than the car.
const LEVEL := 0.6
## Visual layer 20, drawn by the game's cameras and never by DriveEyes: every car's body and
## effects (CarVisuals, CarFX, the ghosts' labels), the ink lines' screen quad (PostFX) and the
## petals falling around the player's camera (SkyRig). The network trained in a world without them,
## and the cars it could see in the game are ghosts, which it drives through.
const GAME_ONLY_LAYER := 1 << 19

var viewport: SubViewport
var camera: Camera3D


func _init(size: Vector2i = SIZE) -> void:
	viewport = SubViewport.new()
	viewport.size = size
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.positional_shadow_atlas_size = 0
	camera = Camera3D.new()
	camera.fov = FOV
	camera.near = 0.1
	camera.far = 1500.0
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.cull_mask = 0xFFFFF & ~GAME_ONLY_LAYER
	viewport.add_child(camera)
	camera.current = true


## Puts every VisualInstance3D of `node`'s subtree (`node` included) on GAME_ONLY_LAYER alone.
static func keep_out(node: Node) -> void:
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = GAME_ONLY_LAYER
	for n in node.find_children("*", "VisualInstance3D", true, false):
		(n as VisualInstance3D).layers = GAME_ONLY_LAYER


## The frame as a RenderingDevice texture (PixelPolicy reads it on the GPU).
func texture_rd() -> RID:
	return RenderingServer.texture_get_rd_texture(viewport.get_texture().get_rid())


## Poses the camera on a car at `car_xf` (its global transform) and marks the viewport for one
## update. The viewport must be in the tree.
func look(car_xf: Transform3D) -> void:
	camera.global_transform = pose(car_xf)
	camera.force_update_transform()
	RenderingServer.viewport_set_update_mode(viewport.get_viewport_rid(), RenderingServer.VIEWPORT_UPDATE_ONCE)


## The camera's global transform on a car at `car_xf`.
static func pose(car_xf: Transform3D) -> Transform3D:
	var fwd := -car_xf.basis.z
	var up := car_xf.basis.y.lerp(Vector3.UP, LEVEL).normalized()
	var b := Basis.looking_at(fwd, up)
	b = b.rotated(b.x, -deg_to_rad(PITCH_DEG))
	return Transform3D(b, car_xf * MOUNT)
