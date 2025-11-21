@tool
extends Node
class_name VRPhysicsLocomotion

## Update this as an example of a code change in Godot 4.5
## A VR locomotion node that uses physics for ground detection and terrain following
## Can be attached to an XROrigin3D and used like a Movement Component (Node)

# Movement settings
@export_group("Movement")
@export var speed: float = 2.0  # Movement speed
@export var sprint_multiplier: float = 2.0  # How much faster sprinting is
@export var toggle_sprint_mode: bool = true  # If true, sprint toggle, if false, hold to sprint
@export var deadzone: float = 0.2  # Ignore small thumbstick movements
@export var gravity: float = 9.8  # Gravity strength
@export var jump_strength: float = 4.0  # Jump force when jumping
@export var allow_jumping: bool = true  # Enable/disable jumping functionality
@export var hmd_height_offset: float = 0.0  # Adjusts camera height: positive = higher, negative = lower

@export_group("Turning")
@export var use_smooth_turning: bool = false  # Set to true for smooth turning, false for snap turning
@export var smooth_turn_speed: float = 45.0  # Degrees per second for smooth turning
@export var snap_turn_degrees: float = 30.0  # Degrees per snap turn

@export_group("Physics")
@export var capsule_radius: float = 0.3  # Radius of the player's collision capsule
@export var capsule_height: float = 1.8  # Height of the player's collision capsule

@export_group("VR Node Paths")
@export_node_path("XRController3D") var left_controller_path: NodePath = "../LeftController"
@export_node_path("XRController3D") var right_controller_path: NodePath = "../RightController" 
@export_node_path("XRCamera3D") var camera_path: NodePath = "../XRCamera3D"

@export_category("Debug")
@export var show_capsule: bool = true  # Whether to show the capsule mesh (for debugging)
@export var capsule_color: Color = Color(1.0, 0.0, 0.0, 0.8)  # Color of the capsule (red by default)
@export var show_debug_logs: bool = false  # Enable detailed debug logging

# Internal nodes
var physics_body: CharacterBody3D
var collision_shape: CollisionShape3D
var capsule_mesh: MeshInstance3D

# Node references
var xr_origin: XROrigin3D
var xr_camera: XRCamera3D
var left_controller: XRController3D
var right_controller: XRController3D

# Movement state
var vertical_velocity: float = 0.0
var move_dir = Vector3.ZERO
var is_jumping: bool = false
var is_sprinting: bool = false
var left_thumbstick_pressed: bool = false
var initialized: bool = false
var last_origin_position: Vector3 = Vector3.ZERO
var physical_movement: Vector3 = Vector3.ZERO
var initial_camera_local_pos = Vector3.ZERO
var initial_capsule_global_pos = Vector3.ZERO
var has_done_initial_setup = false

# Variables for snap turning cooldown
var can_snap_turn: bool = true
var snap_turn_cooldown: float = 0.25  # Seconds
var snap_timer: float = 0.0

# Direction vectors
var forward_direction = Vector3.FORWARD
var right_direction = Vector3.RIGHT

# Debug variables
var debug_timer: float = 0.0

func _get_configuration_warnings() -> PackedStringArray:
	var warnings = PackedStringArray()
	
	# Check if we're attached to an XROrigin3D
	if not get_parent() is XROrigin3D:
		warnings.append("VRPhysicsLocomotion should be a child of an XROrigin3D node.")
	
	# Check if controller paths are valid
	if left_controller_path.is_empty() or not get_node_or_null(left_controller_path):
		warnings.append("Left controller path is invalid or empty.")
	
	if right_controller_path.is_empty() or not get_node_or_null(right_controller_path):
		warnings.append("Right controller path is invalid or empty.")
	
	if camera_path.is_empty() or not get_node_or_null(camera_path):
		warnings.append("Camera path is invalid or empty.")
		
	return warnings

func _ready():
	if Engine.is_editor_hint():
		return
	
	# Wait until the next frame to initialize
	# This gives time for the scene to be fully loaded
	call_deferred("_initialize")

func _initialize():
	# Get node references
	if not is_inside_tree():
		return
		
	xr_origin = get_parent() as XROrigin3D
	
	if not xr_origin:
		push_error("VRPhysicsLocomotion must be a child of an XROrigin3D node")
		return
	
	if not is_instance_valid(get_node_or_null(camera_path)):
		push_error("Camera path is invalid")
		return
		
	if not is_instance_valid(get_node_or_null(left_controller_path)):
		push_error("Left controller path is invalid")
		return
		
	if not is_instance_valid(get_node_or_null(right_controller_path)):
		push_error("Right controller path is invalid")
		return
	
	xr_camera = get_node(camera_path) as XRCamera3D
	left_controller = get_node(left_controller_path) as XRController3D
	right_controller = get_node(right_controller_path) as XRController3D
	
	# Store initial origin position for physical movement tracking
	last_origin_position = xr_origin.global_position
	
	# Create physics body
	call_deferred("_create_physics_body")
	
	# Initialize controller input
	if left_controller and right_controller:
		left_controller.button_pressed.connect(_on_controller_button_pressed.bind(left_controller))
		right_controller.button_pressed.connect(_on_controller_button_pressed.bind(right_controller))
		left_controller.button_released.connect(_on_controller_button_released.bind(left_controller))
		right_controller.button_released.connect(_on_controller_button_released.bind(right_controller))
		left_controller.input_vector2_changed.connect(_on_controller_input_vector2_changed.bind(left_controller))
		right_controller.input_vector2_changed.connect(_on_controller_input_vector2_changed.bind(right_controller))
	
	initialized = true
	if show_debug_logs:
		print("VR Physics Locomotion initialized successfully")

func _exit_tree():
	# Clean up the physics body when the node is removed
	if physics_body and is_instance_valid(physics_body):
		physics_body.queue_free()

func _create_physics_body():
	if show_debug_logs:
		print("Creating physics body...")
	
	# Create a CharacterBody3D for physics
	physics_body = CharacterBody3D.new()
	physics_body.name = "PhysicsBody"
	physics_body.collision_layer = 2  # Player layer
	physics_body.collision_mask = 1   # Environment layer
	physics_body.up_direction = Vector3.UP
	physics_body.floor_stop_on_slope = true
	physics_body.floor_max_angle = deg_to_rad(85.0)  # Maximum slope angle
	physics_body.floor_snap_length = 3.5  # Better stair snapping
	
	# Add collision shape
	collision_shape = CollisionShape3D.new()
	var capsule = CapsuleShape3D.new()
	capsule.radius = capsule_radius
	capsule.height = capsule_height
	collision_shape.shape = capsule
	
	# Position the collision shape
	collision_shape.position = Vector3(0, capsule_height/2, 0)
	
	physics_body.add_child(collision_shape)
	
	# Add visual mesh if enabled
	if show_capsule:
		capsule_mesh = MeshInstance3D.new()
		var mesh = CapsuleMesh.new()
		mesh.radius = capsule_radius
		mesh.height = capsule_height
		capsule_mesh.mesh = mesh
		
		# Make it visible with strong color
		var material = StandardMaterial3D.new()
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = capsule_color
		capsule_mesh.material_override = material
		
		# Position the mesh at the same place as the collision shape
		capsule_mesh.position = collision_shape.position
		
		physics_body.add_child(capsule_mesh)
		if show_debug_logs:
			print("Added capsule mesh with color: ", capsule_color)
	
	# Add to scene at the same level as the XROrigin
	var parent_node = get_parent().get_parent()
	if show_debug_logs:
		print("Adding physics body to: ", parent_node.name)
	parent_node.add_child(physics_body)
	if show_debug_logs:
		print("Physics body added, in tree: ", physics_body.is_inside_tree())
	
	# Position capsule and initialize camera tracking
	if xr_origin and is_instance_valid(xr_origin) and xr_camera and is_instance_valid(xr_camera):
		# Capture initial camera local position NOW (before physics process runs)
		initial_camera_local_pos = xr_camera.transform.origin
		has_done_initial_setup = true
		
		if show_debug_logs:
			print("=== PHYSICS BODY INITIALIZATION ===")
			print("XROrigin global position: ", xr_origin.global_position)
			print("XROrigin rotation: ", xr_origin.rotation)
			print("XRCamera global position: ", xr_camera.global_position)
			print("XRCamera local position (transform.origin): ", xr_camera.transform.origin)
			print("Initial camera local pos captured: ", initial_camera_local_pos)
		
		# Calculate the rotated movement based on this initial position
		var local_movement = initial_camera_local_pos
		var rotated_movement = local_movement.rotated(Vector3.UP, xr_origin.rotation.y)
		
		if show_debug_logs:
			print("Local movement: ", local_movement)
			print("Rotated movement: ", rotated_movement)
		
		# Position capsule at HMD horizontal position
		var floor_position = xr_origin.global_position.y
		var target_x = xr_origin.global_position.x + rotated_movement.x
		var target_y = floor_position - capsule_height/2 + 0.1
		var target_z = xr_origin.global_position.z + rotated_movement.z
		
		if show_debug_logs:
			print("Target capsule position: (", target_x, ", ", target_y, ", ", target_z, ")")
		
		physics_body.global_position = Vector3(target_x, target_y, target_z)
		physics_body.global_rotation = xr_origin.global_rotation
		
		# Store the initial capsule position for use in physics process
		initial_capsule_global_pos = physics_body.global_position
		
		if show_debug_logs:
			print("Final physics body position: ", physics_body.global_position)
			print("Initial capsule stored: ", initial_capsule_global_pos)
			print("=====================================")

func _process(delta):
	if Engine.is_editor_hint() or not initialized:
		return
		
	# Handle snap turn cooldown
	if not can_snap_turn:
		snap_timer += delta
		if snap_timer >= snap_turn_cooldown:
			can_snap_turn = true
			snap_timer = 0.0
	
	if xr_camera and is_instance_valid(xr_camera) and xr_camera.is_inside_tree():
		update_direction_vectors()
	
	# Handle rotation with right thumbstick
	if right_controller and is_instance_valid(right_controller) and right_controller.is_inside_tree():
		var right_thumbstick = Vector2.ZERO
		if right_controller.is_button_pressed("primary"):
			right_thumbstick = right_controller.get_vector2("primary")
		
		# Apply deadzone
		if abs(right_thumbstick.x) < deadzone:
			right_thumbstick.x = 0
		
		if right_thumbstick.x != 0:
			if use_smooth_turning:
				# Smooth turning (corrected direction)
				var rotation_amount = -right_thumbstick.x * smooth_turn_speed * delta
				rotate_player(rotation_amount)
			else:
				# Snap turning (corrected direction)
				if can_snap_turn:
					var direction = -sign(right_thumbstick.x)
					rotate_player(snap_turn_degrees * direction)
					can_snap_turn = false
	
	# Handle sprint in hold mode
	if not toggle_sprint_mode:
		# In hold mode, sprint state directly matches thumbstick press state
		is_sprinting = left_thumbstick_pressed
	
	# Debug output every 2 seconds
	if show_debug_logs:
		debug_timer += delta
		if debug_timer >= 2.0 and physics_body and is_instance_valid(physics_body):
			debug_timer = 0.0
			print("Physics body Y position: ", physics_body.global_position.y)
			print("On floor: ", physics_body.is_on_floor())
			print("Vertical velocity: ", vertical_velocity)
			print("Sprinting: ", is_sprinting, " (", "Toggle Mode" if toggle_sprint_mode else "Hold Mode", ")")
			print("Capsule visible: ", show_capsule and is_instance_valid(capsule_mesh))

func _physics_process(delta):
	if Engine.is_editor_hint() or not initialized:
		return
		
	if not physics_body or not is_instance_valid(physics_body) or not physics_body.is_inside_tree():
		return
		
	if not xr_origin or not is_instance_valid(xr_origin) or not xr_origin.is_inside_tree():
		return
	
	if not left_controller or not is_instance_valid(left_controller) or not left_controller.is_inside_tree():
		return
		
	if not xr_camera or not is_instance_valid(xr_camera) or not xr_camera.is_inside_tree():
		return
	
	# One-time setup to record initial camera position
	if not has_done_initial_setup:
		if show_debug_logs:
			print("WARNING: Physics process capturing initial_camera_local_pos (should have been done in _create_physics_body)")
		initial_camera_local_pos = xr_camera.transform.origin
		has_done_initial_setup = true
	
	# Keep capsule directly under HMD using global position
	# This works even when XROrigin moves because we use absolute world coordinates
	physics_body.global_position.x = xr_camera.global_position.x
	physics_body.global_position.z = xr_camera.global_position.z
	
	# Calculate rotated_movement for the XROrigin update later
	# This is the offset from XROrigin to the camera in rotated space
	var current_local_pos = xr_camera.transform.origin
	var rotated_movement = current_local_pos.rotated(Vector3.UP, xr_origin.rotation.y)
	
	# Debug first frame position update
	if show_debug_logs:
		var frame_count = Engine.get_physics_frames()
		if frame_count < 5:  # Log first few frames
			print("=== PHYSICS PROCESS FRAME ", frame_count, " ===")
			print("XROrigin global position: ", xr_origin.global_position)
			print("XRCamera local pos: ", current_local_pos)
			print("XRCamera global pos: ", xr_camera.global_position)
			print("Rotated movement: ", rotated_movement)
			print("Physics body position: ", physics_body.global_position)
			var horizontal_distance = Vector2(
				xr_camera.global_position.x - physics_body.global_position.x,
				xr_camera.global_position.z - physics_body.global_position.z
			).length()
			print("Horizontal distance HMD to capsule: ", horizontal_distance, " meters")
	
	# ---- HANDLE THUMBSTICK MOVEMENT ----
	# Reset movement direction for thumbstick-based movement
	move_dir = Vector3.ZERO
	
	# Get the left thumbstick input for movement
	var left_thumbstick = Vector2.ZERO
	if left_controller.is_button_pressed("primary"):
		left_thumbstick = left_controller.get_vector2("primary")
	
	# Apply deadzone
	if left_thumbstick.length() < deadzone:
		left_thumbstick = Vector2.ZERO
	
	# Calculate movement direction based on camera orientation
	if left_thumbstick != Vector2.ZERO:
		move_dir += forward_direction * left_thumbstick.y
		move_dir += right_direction * left_thumbstick.x
		
		# Normalize to prevent diagonal movement from being faster
		if move_dir.length() > 1.0:
			move_dir = move_dir.normalized()
		
	# ---- APPLY PHYSICS ----
	# Apply gravity
	if not physics_body.is_on_floor():
		vertical_velocity -= gravity * delta
	else:
		vertical_velocity = -0.1  # Small downward force to keep grounded
	
	# Apply sprint multiplier if sprinting
	var current_speed = speed
	if is_sprinting:
		current_speed *= sprint_multiplier
	
	# Set velocity from thumbstick movement
	physics_body.velocity = move_dir * current_speed
	physics_body.velocity.y = vertical_velocity
	
	# Apply movement using CharacterBody3D physics
	physics_body.move_and_slide()
	
	# ---- UPDATE XRORIGIN POSITION ----
	# After physics is applied, we need to move the XROrigin to follow the physics body's movement
	# But we need to maintain the correct offset relationship
	
	# Calculate the new XROrigin position based on physics body
	xr_origin.global_position = physics_body.global_position - rotated_movement
	
	# Ensure the Y position of the XROrigin maintains the correct height
	# Old manual method
	#xr_origin.global_position.y = (physics_body.global_position.y - capsule_height/2) + hmd_height
	# Offset Method
	xr_origin.global_position.y = physics_body.global_position.y + hmd_height_offset
	
	# Update our tracking position for the next frame
	last_origin_position = xr_origin.global_position

func update_direction_vectors():
	if not xr_camera or not is_instance_valid(xr_camera) or not xr_camera.is_inside_tree():
		return
		
	# Get the camera's forward and right directions, but remove vertical component
	var camera_transform = xr_camera.global_transform
	
	# Forward direction (z-axis) without vertical component
	forward_direction = -camera_transform.basis.z
	forward_direction.y = 0
	if forward_direction.length() > 0.001:
		forward_direction = forward_direction.normalized()
	else:
		forward_direction = Vector3.FORWARD
	
	# Right direction (x-axis) without vertical component
	right_direction = camera_transform.basis.x
	right_direction.y = 0
	if right_direction.length() > 0.001:
		right_direction = right_direction.normalized()
	else:
		right_direction = Vector3.RIGHT


func rotate_player(degrees):
	if not xr_origin or not is_instance_valid(xr_origin) or not xr_origin.is_inside_tree():
		return
		
	if not physics_body or not is_instance_valid(physics_body) or not physics_body.is_inside_tree():
		return
	
	# Simply rotate the XROrigin around its Y axis
	xr_origin.rotate_y(deg_to_rad(degrees))
	
	# Update the physics body rotation to match
	physics_body.global_rotation.y = xr_origin.global_rotation.y
	
	# No position updates needed here - all positioning is now handled 
	# in _physics_process with the rotated local movement calculations

func jump():
	print("JUMP FUNCTION CALLED!")
	if physics_body and is_instance_valid(physics_body) and physics_body.is_on_floor() and allow_jumping:
		print("JUMPING! On floor:", physics_body.is_on_floor())
		vertical_velocity = jump_strength
		is_jumping = true
		
		# Force immediate upward movement to ensure it happens
		physics_body.velocity.y = jump_strength
		physics_body.move_and_slide()
		
		print("Applied vertical velocity:", vertical_velocity)

func toggle_sprint():
	if toggle_sprint_mode:
		is_sprinting = !is_sprinting
		print("Sprint toggled: ", is_sprinting)

func _on_controller_button_pressed(name, controller):
	#Debug print controller input names 
	#print("Button pressed: ", name, " on controller: ", "left" if controller == left_controller else "right")
	# Handle jump
	if controller == right_controller and name == "ax_button" and allow_jumping:
		jump()
	
	# Handle sprint activation
	if controller == left_controller and name == "primary_click":
		left_thumbstick_pressed = true
		
		if toggle_sprint_mode:
			toggle_sprint()
		else:
			# In hold mode, we'll set the sprint state in _process
			pass

func _on_controller_button_released(name, controller):
	# Handle sprint deactivation for hold mode
	if controller == left_controller and name == "primary_click":
		left_thumbstick_pressed = false
		# The actual sprint state will be updated in _process

func _on_controller_input_vector2_changed(name, vector, controller):
	pass
