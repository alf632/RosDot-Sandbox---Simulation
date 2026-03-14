extends Node3D
class_name WaterFloater

@export var water_sim: Node3D        # Drag your simulation node here in the Inspector
@export var float_force := 100.0      # Upward buoyancy multiplier
@export var drift_strength := 50.0   # How easily the object is swept away
@export var water_drag := 2.0        # Physical drag force applied when submerged
@export var object_height := 0.05

var body: RigidBody3D

func _ready() -> void:
	# 1. Ensure this node is actually attached to a RigidBody3D
	body = get_parent() as RigidBody3D
	if not body:
		push_warning("WaterFloater must be a child of a RigidBody3D!")
		set_physics_process(false)

func _physics_process(delta: float) -> void:
	if not is_instance_valid(water_sim) or not body:
		return

	var info = water_sim.get_surface_info(global_position)
	var surface_y = info.x
	var water_depth = info.y
	
	var water_vel = water_sim.get_surface_velocity(global_position)
	
	if water_depth > 0.005 or water_vel != Vector3.ZERO:
		var height = global_position.y
		var submerged_depth = surface_y + water_depth - height
		
		if submerged_depth > 0.0:
			#body.process_mode = Node.PROCESS_MODE_ALWAYS
			# Calculate where this floater is relative to the parent's center
			# This is critical so the rigid body rotates when pushed from a corner!
			var local_offset = global_position - body.global_position

			# Apply mass-adjusted buoyancy
			var submerged_ratio = clamp(submerged_depth / object_height, 0.0, 1.0)
			var b_force = Vector3.UP * float_force * body.mass * submerged_ratio
			body.apply_force(b_force, local_offset)
			
			# Apply Drift
			var d_force = water_vel * drift_strength * body.mass
			body.apply_force(d_force, local_offset)
			
			# Apply Drag
			# Instead of magically slowing down the whole object, we apply a counter-force
			# against the body's velocity at this specific point. This scales perfectly
			# even if you have 10 floater nodes attached to one ship.
			var point_velocity = body.linear_velocity
			body.apply_force(-point_velocity * water_drag * body.mass, local_offset)
