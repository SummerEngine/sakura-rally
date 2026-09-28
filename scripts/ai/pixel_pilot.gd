class_name PixelPilot
extends NeuralPilot
## Drives its parent Car from pixels (docs/PIXELS.md §8): the frame of a DriveEyes hood camera and
## 21 floats (DriveSense's motion and the controls held, and its last choice) go through a
## PixelPolicy on the GPU, where NeuralPilot's policy reads the road's geometry. NeuralPilot's
## loop, stuck fallback included, except that the answer comes back later: at a decision tick the
## eyes take a picture (drawn with the frame), once the frame is drawn the network runs on it, and
## the first physics tick that has the logits sets the hands, about 3 frames on (6 physics ticks at
## 60 fps; in the training eval a 6-8 tick delay cost 0.4-2.5 s a lap). The hands keep the last
## choice meanwhile, and one picture is in flight at a time, so at a low frame rate it decides
## less often. It takes the likeliest choice, as the eval does.

var pixels: PixelPolicy
var eyes: DriveEyes
var _vec := PackedFloat32Array()
## Its last choice (training's `prev`): DriveHands' rest (the wheel straight, no pedal, no
## handbrake) until the first answer.
var _last := PackedInt32Array([3, 1, 0])
## A picture was taken this frame: the network runs on it once the frame is drawn.
var _shot := false
## The answer being waited for (PixelPolicy.request), 0: none.
var _ticket: int = 0


func _enter_tree() -> void:
	RenderingServer.frame_post_draw.connect(_on_frame_drawn)


func _ready() -> void:
	super()
	eyes = DriveEyes.new()
	add_child(eyes.viewport)
	if pixels != null:
		_vec.resize(pixels.vec_size)


func _exit_tree() -> void:
	super()
	RenderingServer.frame_post_draw.disconnect(_on_frame_drawn)


func _has_driver() -> bool:
	return pixels != null


func _physics_process(delta: float) -> void:
	if _ticket != 0:
		var z := pixels.take(_ticket)
		if not z.is_empty():
			_ticket = 0
			_last = _answer(pixels.best(z))
	if not _shot and _ticket == 0 and (Engine.get_physics_frames() + phase) % DriveHands.DECISION_TICKS == 0:
		_look(delta)
		_fill_vec()
		eyes.look(car.global_transform)
		_shot = true
	hands.apply(car, delta)


## The network's floats, as train_pixels.py's vec_of: DriveSense's last ones (the motion and the
## controls held), then the last choice one-hot per group.
func _fill_vec() -> void:
	var at := pixels.vec_size
	for d in pixels.action_dims:
		at -= d
	var from := DriveSense.OBS_SIZE - at
	for i in at:
		_vec[i] = _obs[from + i]
	for g in pixels.action_dims.size():
		for i in pixels.action_dims[g]:
			_vec[at + i] = 1.0 if i == _last[g] else 0.0
		at += pixels.action_dims[g]


## After the frame that drew the picture: the network's pass goes into the next frame.
func _on_frame_drawn() -> void:
	if _shot:
		_shot = false
		_ticket = pixels.request(eyes.texture_rd(), _vec)
