extends Node3D
class_name Projector

# Standard clipping planes (adjust these based on how deep your sand is 
# and how high your projector is mounted)
@export var near_clip: float = 0.1
@export var far_clip: float = 10.0

@export_group("Godot Extrinsics")
@export var proj_pos = Vector3(0.0, 3.0, 0.0) 
@export var proj_basis = Basis(Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)) 
@export_group("Godot Intrinsics")
@export var fx = 1050.5 
@export var fy = 1050.5 
@export var cx = 960.0  
@export var cy = 680.0  
@export var W :int = 1920  
@export var H :int = 1080  

@onready var camera :Camera3D = $SubViewport/Camera3D

# Streamer
@export_group("Streamer")
@export var useStreamer :bool = false
@export var targetIP :String = "127.0.0.1"
@export var targetPort :String = "5004"

var pipe: FileAccess
var ffmpeg_pid: int = 0
var rd: RenderingDevice
var is_fetching_frame: bool = false
var target_fps: int = 30
var frame_time: float = 1.0 / 30.0
var time_accumulator: float = 0.0

@export var resolution :String = "1920x1080x30"
@export var calibration :bool = false
@export var calibration_img :Image

func _ready():
	apply_calibration()

func apply_calibration():
	var splitres = resolution.split("x")
	W = int(splitres[0])
	H = int(splitres[1])
	$SubViewport.size = Vector2i(W, H)
	$SubViewport.size_2d_override = $SubViewport.size
	target_fps = int(splitres[2])
	frame_time = 1.0 / float(target_fps)
	
	#camera.global_transform = Transform3D(proj_basis, proj_pos)

	var left = -cx * near_clip / fx
	var right = (W - cx) * near_clip / fx
	
	var top = cy * near_clip / fy
	var bottom = -(H - cy) * near_clip / fy

	var frustum_width = right - left 
	var offset_x = (right + left) / 2.0
	var offset_y = (top + bottom) / 2.0

	camera.projection = Camera3D.PROJECTION_FRUSTUM
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.set_frustum(frustum_width, Vector2(offset_x, offset_y), near_clip, far_clip)
	
	print("Godot 4 Projector Camera Calibrated Successfully!")
	
	if useStreamer:
		rd = RenderingServer.get_rendering_device()
	
		#var command = PackedStringArray([
		#"-report", # <-- Dumps a detailed log file to your project root! Remove when in production.
		#"-f", "rawvideo",
		#"-pix_fmt", "rgba", # <-- FIXED typo from pixel_format
		#"-video_size", str(W) + "x" + str(H),
		#"-framerate", splitres[2],
		#"-i", "-", 
		#"-c:v", "h264_nvenc", 
		#"-preset", "ll",
		#"-tune", "ull",
		#"-f", "rtp",
		#"rtp://" + targetIP + ":" + targetPort
		#])
	
		#var exec_result = OS.execute_with_pipe("ffmpeg", command)
	
		var ffmpeg_cmd = 'ffmpeg -f rawvideo -pix_fmt rgba -video_size %dx%d -framerate %d -re -i - -c:v h264_nvenc -preset p2 -tune ull -profile:v main -bf 0 -g %d -strict_gop 1 -flags -global_header -pix_fmt yuv420p -f mpegts "udp://%s:%s?pkt_size=1316" 2> ffmpeg_crash_log.txt' % [W, H, target_fps, target_fps, targetIP, targetPort]
		
		var command = PackedStringArray(["-c", ffmpeg_cmd])
		
		var exec_result = OS.execute_with_pipe("bash", command)
		
		if exec_result.has("stdio"):
			pipe = exec_result["stdio"]
			ffmpeg_pid = exec_result["pid"]
			print("FFmpeg Streaming Pipeline started (PID: ", ffmpeg_pid, ")")
		else:
			printerr("Failed to open FFmpeg pipe. Is FFmpeg installed and in your system PATH?")
	else:
		set_process(false)

func _process(delta):
	# Fail-safe: Check if FFmpeg became a zombie process before we try to feed it
	if ffmpeg_pid > 0 and not OS.is_process_running(ffmpeg_pid):
		printerr("FFmpeg process died unexpectedly! Check the ffmpeg-*.log file in your project folder.")
		set_process(false)
		return

	if not pipe or not pipe.is_open():
		return
		
	time_accumulator += delta
	if time_accumulator < frame_time:
		return
		
	if calibration:
		pipe.store_buffer(calibration_img.get_data())
		pipe.flush()
		return
	
	# THE LOCK: Don't ask for a new frame if we are still processing the last one!
	if is_fetching_frame:
		return
		
	var tex_rid = $SubViewport.get_texture().get_rid()
	var rd_rid = RenderingServer.texture_get_rd_texture(tex_rid)
	
	if rd_rid.is_valid():
		is_fetching_frame = true # Lock the pipeline
		time_accumulator -= frame_time
		rd.texture_get_data_async(rd_rid, 0, _on_texture_data_received)

func _on_texture_data_received(data: PackedByteArray):
	if pipe and pipe.is_open():
		# Sanity check: Ensure Godot didn't hand us a corrupted/partial frame array
		var expected_size = W * H * 4 # RGBA = 4 bytes per pixel
		if data.size() == expected_size:
			pipe.store_buffer(data)
			pipe.flush()
		else:
			printerr("Frame drop! Expected ", expected_size, " bytes, got ", data.size())
		# UNLOCK: The frame is in the pipe, we are ready for the next one
	is_fetching_frame = false

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if pipe and pipe.is_open():
			pipe.close()
		if ffmpeg_pid > 0 and OS.is_process_running(ffmpeg_pid):
			OS.kill(ffmpeg_pid)
