extends Node3D

# Standard clipping planes (adjust these based on how deep your sand is 
# and how high your projector is mounted)
@export var near_clip: float = 0.1
@export var far_clip: float = 10.0

# ====================================================================
# 1. PASTE YOUR TERMINAL OUTPUT HERE
# ====================================================================
@export_group("Godot Extrinsics")
@export var proj_pos = Vector3(0.0, 3.0, 0.0) # <-- Replace with your pos
@export var proj_basis = Basis(Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)) # <-- Replace with your basis
@export_group("Godot Intrinsics")
@export var fx = 1050.5 # <-- Replace with your fx
@export var fy = 1050.5 # <-- Replace with your fy
@export var cx = 960.0  # <-- Replace with your cx
@export var cy = 680.0  # <-- Replace with your cy
@export var W = 1920.0  # <-- Replace with your W
@export var H = 1080.0  # <-- Replace with your H

@onready var camera :Camera3D = $SubViewport/Camera3D

# Streamer
@export_group("Streamer")
@export var useStreamer :bool = false
@export var targetIP :String = "172.0.0.1"
@export var targetPort :String = "5004"

var pipe: FileAccess
var ffmpeg_pid: int = 0
var rd: RenderingDevice

func _ready():

	# ====================================================================
	# 2. APPLY EXTRINSICS (Position and Rotation)
	# ====================================================================
	# Set the camera to the exact physical location of the projector
	camera.global_transform = Transform3D(proj_basis, proj_pos)


	# Calculate the physical boundaries of the projection at the near clipping plane.
	# Note: OpenCV's Y-axis points down, while Godot's Y-axis points up, 
	# so the math flips the signs for the top and bottom calculations.
	
	var left = -cx * near_clip / fx
	var right = (W - cx) * near_clip / fx
	
	var top = cy * near_clip / fy
	var bottom = -(H - cy) * near_clip / fy

	# Godot needs the total width of the near plane, and the X/Y offset from center
	var frustum_width = right - left 
	var offset_x = (right + left) / 2.0
	var offset_y = (top + bottom) / 2.0

	# Apply the settings directly to the Godot 4 camera
	camera.projection = Camera3D.PROJECTION_FRUSTUM
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.set_frustum(frustum_width, Vector2(offset_x, offset_y), near_clip, far_clip)
	
	print("Godot 4 Projector Camera Calibrated Successfully!")
	
	$SubViewport.size = Vector2i(W, H)
	$SubViewport.size_2d_override = Vector2i(W, H)
	
	if useStreamer:
		rd = RenderingServer.get_rendering_device()
	
		# 1. Start FFmpeg process reading from stdin and streaming via RTP
		# This example uses libx264 (CPU) with the 'zerolatency' tune. 
		# If you have an Nvidia GPU, change libx264 to h264_nvenc for massive performance gains.
		var width = $SubViewport.size.x
		var height = $SubViewport.size.y

		var command = PackedStringArray([
		"-f", "rawvideo",
		"-pixel_format", "rgba",
		"-video_size", str(width) + "x" + str(height),
		"-framerate", "60",
		"-i", "-", # Tell FFmpeg to read from standard input (stdin)
		"-c:v", "h264_nvenc", # libx264 (CPU) h264_nvenc (Nvidia) or h264_amf (AMD)
		"-preset", "ultrafast",
		"-tune", "zerolatency",
		"-f", "rtp",
		"rtp://" + targetIP + ":" + targetPort
		])
	
	# Godot 4.3+ method for opening a process with an active I/O pipe
		var exec_result = OS.execute_with_pipe("ffmpeg", command)
	
		if exec_result.has("stdio"):
			pipe = exec_result["stdio"]
			ffmpeg_pid = exec_result["pid"]
			print("FFmpeg Streaming Pipeline started (PID: ", ffmpeg_pid, ")")
		else:
			printerr("Failed to open FFmpeg pipe. Is FFmpeg installed and in your system PATH?")
	else:
		set_process(false)

func _process(_delta):
	if not pipe or not pipe.is_open():
		return
		
	# 1. Get the high-level RenderingServer RID for the viewport
	var tex_rid = $SubViewport.get_texture().get_viewport_texture().get_rid()
	
	# 2. Convert it to a low-level RenderingDevice RID
	var rd_rid = RenderingServer.texture_get_rd_texture(tex_rid)
	
	if rd_rid.is_valid():
		# 3. Request the texture data asynchronously (Godot 4.4+)
		# This prevents the dreaded get_image() stutter!
		rd.texture_get_data_async(rd_rid, 0, _on_texture_data_received)

# 4. The callback automatically receives the PackedByteArray natively
func _on_texture_data_received(data: PackedByteArray):
	if pipe and pipe.is_open():
		# Push the raw bytes directly into the FFmpeg stdin pipe
		pipe.store_buffer(data)

# Clean up the FFmpeg process when the game closes to prevent memory leaks/zombie processes
func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if pipe and pipe.is_open():
			pipe.close()
		if ffmpeg_pid > 0:
			OS.kill(ffmpeg_pid)
