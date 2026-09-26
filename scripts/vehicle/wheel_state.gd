class_name WheelState
extends RefCounted
## Per-wheel runtime state published by the car every physics tick (see docs/CONTRACTS.md).
## Order in `Car.wheels`: FL, FR, RL, RR. Fields above the separator are the shared contract;
## the rest are extras used by the visuals, camera and autopilot.

var contact: bool = false
var surface: StringName = &"none"
## Longitudinal slip ratio kappa = (spin * radius - ground speed) / ground speed. >0 wheelspin, <0 lock-up.
var slip_long: float = 0.0
## Lateral slip angle in radians (positive = contact patch moving to the car's right).
var slip_lat: float = 0.0
## Combined normalised slip: 0 rolling, ~1 at the grip peak, >1 sliding.
var slip: float = 0.0
## Tyre normal load in newtons.
var load: float = 0.0
## Suspension compression 0 (full droop) .. 1 (full bump).
var compression: float = 0.0
var contact_point: Vector3 = Vector3.ZERO
var contact_normal: Vector3 = Vector3.UP
## Wheel angular speed in rad/s (positive rolls the car forward).
var spin_speed: float = 0.0

# ---------------------------------------------------------------- extras
## Wheel centre at rest in car space.
var rest_position: Vector3 = Vector3.ZERO
var is_front: bool = false
var is_left: bool = false
## Steering angle in radians around car up (positive = towards the car's right).
var steer_angle: float = 0.0
## Accumulated spin angle in radians (wraps at TAU), for the visuals.
var spin_angle: float = 0.0
## Suspension length 0 (full bump) .. travel (full droop), metres.
var suspension_length: float = 0.0
## Vertical offset of the wheel centre from its rest height, metres (positive = up).
var offset_y: float = 0.0
## Speed at which the contact patch slides over the ground, m/s (for skid audio / dust).
var slide_speed: float = 0.0
## Grip coefficient of the current surface.
var surface_mu: float = 0.0
## Roughness of the current surface, 0..1.
var surface_roughness: float = 0.0
