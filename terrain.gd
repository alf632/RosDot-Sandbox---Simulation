#@tool
extends Node3D

@export_group("Simulation Settings")
@export var resolution := Vector2i(256, 256)
@export var pipe_area := 0.5
@export var gravity := 9.8
@export var terrain_retention := 0.009 # Must be higher than visual shader cutoff (0.005)
@export var evaporation_rate := 0.0002 # Keep this very small!
@export var damping := 0.99995     # Closer to 1.0 = more slippery
@export var sub_steps := 4       # How many times to simulate per frame
@export var mesh_size := 6.0          # The physical size of your PlaneMesh
@export var height_scale := 1.0       # Make sure this matches your visual shader!

var rd: RenderingDevice

# Shader and Pipeline RIDs
var flux_shader_rid: RID
var flux_pipeline_rid: RID
var update_shader_rid: RID
var update_pipeline_rid: RID

# Texture RIDs (GPU side)
var terrain_rd_rid: RID
var h1_rid: RID # Height Buffer A
var h2_rid: RID # Height Buffer B
var f1_rid: RID # Flux Buffer A
var f2_rid: RID # Flux Buffer B

# Pre-created Uniform Sets (To prevent memory leaks)
var set_A_flux: RID
var set_A_update: RID
var set_B_flux: RID
var set_B_update: RID

var modifier_buffer: RID
var water_sources = [] 
var water_drains = [] 
const MAX_MODIFIERS = 64 # Absolute max limit for combined sources/drains

var water_tex_rd := Texture2DRD.new()
var flux_tex_rd := Texture2DRD.new()
var terrain_tex: ImageTexture
var even_frame := true # Used for ping-pong logic

var cpu_terrain_data := PackedFloat32Array()
var cpu_water_data := PackedFloat32Array()
var cpu_flux_data := PackedFloat32Array()
var _physics_frames := 0

@onready var collision_shape :CollisionShape3D = $StaticBody3D/CollisionShape3D
@onready var terrain_mesh: MeshInstance3D = $TerrainMesh
@onready var water_mesh: MeshInstance3D = $WaterMesh

func _ready() -> void:
	rd = RenderingServer.get_rendering_device()
	
	# 1. Load and Compile BOTH Shaders
	var f_shader_file = load("res://water_flux.glsl")
	flux_shader_rid = rd.shader_create_from_spirv(f_shader_file.get_spirv())
	flux_pipeline_rid = rd.compute_pipeline_create(flux_shader_rid)

	var u_shader_file = load("res://water_update.glsl")
	update_shader_rid = rd.shader_create_from_spirv(u_shader_file.get_spirv())
	update_pipeline_rid = rd.compute_pipeline_create(update_shader_rid)

	# 2. Setup Terrain
	terrain_tex = _generate_noise_heightmap(resolution)
	terrain_rd_rid = _create_texture_rd(resolution, RenderingDevice.DATA_FORMAT_R32_SFLOAT, terrain_tex.get_image().get_data())
	collision_shape.shape.update_map_data_from_image(terrain_tex.get_image(), 0, height_scale)
	cpu_terrain_data = terrain_tex.get_image().get_data().to_float32_array()
	
	# Compress the 255x255 physics grid down to 6x6, and scale the height
	# We use (resolution - 1) because 256 vertices = 255 grid squares
	var scale_xz = mesh_size / float(resolution.x - 1)
	collision_shape.scale = Vector3(scale_xz, 1, scale_xz)
	
	# 3. Create GPU Textures (Ping-Pong pairs for Height and Flux)
	h1_rid = _create_texture_rd(resolution, RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	h2_rid = _create_texture_rd(resolution, RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	f1_rid = _create_texture_rd(resolution, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	f2_rid = _create_texture_rd(resolution, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)

	_clear_texture(h1_rid, 1)
	_clear_texture(h2_rid, 1)
	_clear_texture(f1_rid, 4)
	_clear_texture(f2_rid, 4)
	
	# 4. Initialize fixed-size Modifier Buffer (Max 64 items, 16 bytes each)
	var empty_mod_data = PackedByteArray()
	empty_mod_data.resize(MAX_MODIFIERS * 16)
	modifier_buffer = rd.storage_buffer_create(empty_mod_data.size(), empty_mod_data)

	# 5. Pre-create Uniform Sets
	_build_uniform_sets()

	water_tex_rd.texture_rd_rid = h1_rid
	flux_tex_rd.texture_rd_rid = f1_rid
	var t_mat = terrain_mesh.get_active_material(0)
	if t_mat is ShaderMaterial:
		t_mat.set_shader_parameter("terrain_map", terrain_tex)
	var w_mat = water_mesh.get_active_material(0)
	if w_mat is ShaderMaterial:
		w_mat.set_shader_parameter("water_data", water_tex_rd)
		w_mat.set_shader_parameter("flux_data", flux_tex_rd)
		w_mat.set_shader_parameter("terrain_map", terrain_tex)

	# Initialize Test Sources/Drains
	water_sources.append({"pos": Vector2(0.5, 0.5), "strength": 0.2, "radius": 0.02})
	#water_sources.append({"pos": Vector2(0.4, 0.6), "strength": 0.05, "radius": 0.02})
	#water_sources.append({"pos": Vector2(0.6, 0.6), "strength": 0.05, "radius": 0.02})
	#water_drains.append({"pos": Vector2(0.7, 0.7), "strength": 0.07, "radius": 0.02})
	_update_modifier_buffer()

func _process(delta: float) -> void:
	# Ensure workgroup sizes safely cover the whole texture without truncating
	var x_groups = ceil(resolution.x / 8.0)
	var y_groups = ceil(resolution.y / 8.0)
	
	var dt = delta / float(sub_steps)
	
	var compute_list = rd.compute_list_begin()
	
	# Run the simulation loop multiple times per frame
	for step in range(sub_steps):
		var flux_push = PackedByteArray()
		flux_push.append_array(PackedInt32Array([resolution.x, resolution.y]).to_byte_array())
		flux_push.append_array(PackedFloat32Array([dt, pipe_area, gravity, terrain_retention, damping]).to_byte_array())
		flux_push.resize(32)

		var update_push = PackedByteArray()
		update_push.append_array(PackedInt32Array([resolution.x, resolution.y]).to_byte_array())
		update_push.append_array(PackedFloat32Array([dt, evaporation_rate]).to_byte_array())
		update_push.append_array(PackedInt32Array([water_sources.size(), water_drains.size()]).to_byte_array())
		update_push.resize(32)

		# PASS 1: Flux
		rd.compute_list_bind_compute_pipeline(compute_list, flux_pipeline_rid)
		rd.compute_list_bind_uniform_set(compute_list, set_A_flux if even_frame else set_B_flux, 0)
		rd.compute_list_set_push_constant(compute_list, flux_push, flux_push.size())
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		rd.compute_list_add_barrier(compute_list)

		# PASS 2: Update
		rd.compute_list_bind_compute_pipeline(compute_list, update_pipeline_rid)
		rd.compute_list_bind_uniform_set(compute_list, set_A_update if even_frame else set_B_update, 0)
		rd.compute_list_set_push_constant(compute_list, update_push, update_push.size())
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		rd.compute_list_add_barrier(compute_list) # Crucial before the next sub-step reads!

		even_frame = !even_frame

	rd.compute_list_end()

	# Update Visual Shader references
	water_tex_rd.texture_rd_rid = h1_rid if even_frame else h2_rid
	flux_tex_rd.texture_rd_rid = f1_rid if even_frame else f2_rid

func _physics_process(delta: float) -> void:
	_physics_frames += 1
	
	if _physics_frames % 3 == 0:
		# 1. Read Height Data
		var target_h_rid = h1_rid if even_frame else h2_rid
		var h_bytes = rd.texture_get_data(target_h_rid, 0)
		if not h_bytes.is_empty():
			cpu_water_data = h_bytes.to_float32_array()
			
		# 2. Read Flux Data (NEW)
		var target_f_rid = f1_rid if even_frame else f2_rid
		var f_bytes = rd.texture_get_data(target_f_rid, 0)
		if not f_bytes.is_empty():
			cpu_flux_data = f_bytes.to_float32_array()


func get_surface_info(world_pos: Vector3) -> Vector2:
	if cpu_water_data.is_empty() or cpu_terrain_data.is_empty():
		return Vector2.ZERO
	
	# Map world space (-3.0 to +3.0) to UV space (0.0 to 1.0)
	# Assuming your PlaneMesh is centered at (0,0,0) with size 6x6
	var uv_x = (world_pos.x / mesh_size) + 0.5
	var uv_y = (world_pos.z / mesh_size) + 0.5
	
	# Check if object is out of bounds
	if uv_x < 0.0 or uv_x > 1.0 or uv_y < 0.0 or uv_y > 1.0:
		return Vector2.ZERO
		
	# Convert UV to integer pixel coordinates
	var px = clampi(int(uv_x * resolution.x), 0, resolution.x - 1)
	var py = clampi(int(uv_y * resolution.y), 0, resolution.y - 1)
	var idx = py * resolution.x + px
	
	# Calculate Total Height: (Terrain + Water) * scale
	var t_h = cpu_terrain_data[idx]
	var w_h = cpu_water_data[idx]
	
	# Vector2.x = Actual Physical Height (Terrain + Water)
	# Vector2.y = Water Depth (To check if we are actually in a puddle/lake)
	return Vector2(t_h * height_scale, w_h * height_scale)

func get_surface_velocity(world_pos: Vector3) -> Vector3:
	if cpu_flux_data.is_empty():
		return Vector3.ZERO
		
	var uv_x = (world_pos.x / mesh_size) + 0.5
	var uv_y = (world_pos.z / mesh_size) + 0.5
	
	if uv_x < 0.0 or uv_x > 1.0 or uv_y < 0.0 or uv_y > 1.0:
		return Vector3.ZERO
		
	var px = clampi(int(uv_x * resolution.x), 0, resolution.x - 1)
	var py = clampi(int(uv_y * resolution.y), 0, resolution.y - 1)
	
	# Base index for a 1D array representing a 2D grid
	var base_idx = py * resolution.x + px
	
	# Multiply by 4 because it's an RGBA array (4 floats per pixel)
	var array_idx = base_idx * 4
	
	var f_r = cpu_flux_data[array_idx]      # R channel (Right)
	var f_l = cpu_flux_data[array_idx + 1]  # G channel (Left)
	var f_u = cpu_flux_data[array_idx + 2]  # B channel (Up / -Z)
	var f_d = cpu_flux_data[array_idx + 3]  # A channel (Down / +Z)
	
	# Calculate net velocity
	var vel_x = f_r - f_l
	var vel_z = f_d - f_u
	
	# Return as a 3D vector (Y is 0 because flow is horizontal)
	return Vector3(vel_x, 0.0, vel_z)


func update_heightmap(img :Image):
	rd.texture_update(terrain_rd_rid, 0, img.get_data())
	terrain_tex.update(img)
	terrain_mesh.get_active_material(0).set_shader_parameter("terrain_map", terrain_tex)
	water_mesh.get_active_material(0).set_shader_parameter("terrain_map", terrain_tex)
	collision_shape.shape.update_map_data_from_image(img, 0, height_scale)
	cpu_terrain_data = img.get_data().to_float32_array()

func _update_modifier_buffer():
	var data = PackedFloat32Array()
	# 1. Pack Sources
	for s in water_sources:
		data.append_array([s.pos.x, s.pos.y, s.strength, s.radius])
	# 2. Pack Drains
	for d in water_drains:
		data.append_array([d.pos.x, d.pos.y, d.strength, d.radius])
	
	var bytes = data.to_byte_array()
	if bytes.size() > 0:
		# Update existing buffer instead of recreating it
		rd.buffer_update(modifier_buffer, 0, bytes.size(), bytes)

func _build_uniform_sets():
	# Helper to easily create Image Uniforms
	var make_img_u = func(binding: int, rid: RID):
		var u = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = binding
		u.add_id(rid)
		return u
		
	var mod_u = RDUniform.new()
	mod_u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	mod_u.binding = 3
	mod_u.add_id(modifier_buffer)
	
	var t_u = make_img_u.call(0, terrain_rd_rid)
	
	# SET A: Reads H1/F1, Writes F2/H2
	set_A_flux = rd.uniform_set_create([t_u, make_img_u.call(1, h1_rid), make_img_u.call(2, f1_rid), make_img_u.call(3, f2_rid)], flux_shader_rid, 0)
	set_A_update = rd.uniform_set_create([make_img_u.call(0, h1_rid), make_img_u.call(1, f2_rid), make_img_u.call(2, h2_rid), mod_u], update_shader_rid, 0)
	
	# SET B: Reads H2/F2, Writes F1/H1
	set_B_flux = rd.uniform_set_create([t_u, make_img_u.call(1, h2_rid), make_img_u.call(2, f2_rid), make_img_u.call(3, f1_rid)], flux_shader_rid, 0)
	set_B_update = rd.uniform_set_create([make_img_u.call(0, h2_rid), make_img_u.call(1, f1_rid), make_img_u.call(2, h1_rid), mod_u], update_shader_rid, 0)

func _create_texture_rd(size: Vector2i, format: int, data: PackedByteArray = []) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.width = size.x; fmt.height = size.y
	fmt.format = format
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return rd.texture_create(fmt, RDTextureView.new(), [data] if not data.is_empty() else [])

func _clear_texture(tex_rid: RID, channels: int):
	var clear_data = PackedFloat32Array()
	clear_data.resize(resolution.x * resolution.y * channels)
	clear_data.fill(0.0)
	rd.texture_update(tex_rid, 0, clear_data.to_byte_array())

# (Keep your _generate_noise_heightmap function here as it was)
func _generate_noise_heightmap(size: Vector2i) -> ImageTexture:
	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.frequency = 0.02
	var img = Image.create(size.x, size.y, false, Image.FORMAT_RF)
	for y in size.y:
		for x in size.x:
			var val = (noise.get_noise_2d(x, y) + 1.0) * 0.5
			img.set_pixel(x, y, Color(val, 0, 0, 1.0))
	return ImageTexture.create_from_image(img)
