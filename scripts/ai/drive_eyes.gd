class_name DriveEyes
extends RefCounted
## What the pixel driver sees (docs/PIXELS.md): one small RGB frame from a camera on the car's
## hood, rendered only when asked. The same camera in training (tools/rl_pixels/pixel_env.gd) and
## wherever the game gives a pixel driver its eyes, as DriveSense and DriveHands are shared.
##
## The viewport never updates by itself: look() poses the camera and marks the viewport for one
## update, and the next RenderingServer.force_draw() (or frame drawn) renders it. The viewport
## shares its parent's World3D; a car's own body is not in the picture only because the caller
## keeps it out (training cars have no visuals).

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
	viewport.add_child(camera)
	camera.current = true


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
