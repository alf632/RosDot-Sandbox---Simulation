extends Node

const ProjectorScene = preload("res://projector.tscn")

var server := TCPServer.new()
var clients : Array = []
var buffers : Dictionary = {} # Tracks partial data per client

func _ready():
	server.listen(5007)
	print("Godot TCP Server listening on 5007...")

func _process(delta):
	# Accept new connections
	if server.is_connection_available():
		var peer : StreamPeerTCP = server.take_connection()
		clients.append(peer)
		buffers[peer] = ""

	# Process existing connections
	for i in range(clients.size() - 1, -1, -1):
		var peer : StreamPeerTCP = clients[i]
		peer.poll()
		var status = peer.get_status()

		if status == StreamPeerTCP.STATUS_CONNECTED:
			var bytes = peer.get_available_bytes()
			if bytes > 0:
				buffers[peer] += peer.get_utf8_string(bytes)
				
		elif status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
			# Socket closed! We have the full message.
			var raw_json = buffers[peer]
			if raw_json.length() > 0:
				parse_and_execute(raw_json)
				
			buffers.erase(peer)
			clients.remove_at(i)

func parse_and_execute(raw_json: String):
	var json = JSON.new()
	if json.parse(raw_json) == OK:
		var msg = json.data
		match msg.get("command", ""):
			"update_projectors":
				print("Setting up stream targets: ", msg["data"])
				for proj_id in msg["data"]:
					print("Received new config for projector: ", proj_id)
					var proj = $Projectors.find_child(proj_id, false, false)
					if proj:
						proj.queue_free()
						await proj.tree_exited
					proj = ProjectorScene.instantiate()
					proj.name = proj_id
					proj.resolution = msg["data"][proj_id]["resolution"]
					proj.targetIP = msg["data"][proj_id]["target_ip"]
					proj.targetPort = str(msg["data"][proj_id]["target_port"])
					proj.useStreamer = true
					$Projectors.add_child(proj)
				
				
			"update_transform":
				print("Applying new math for Projector ", msg["projector_id"])
				var proj = $Projectors.find_child(msg["projector_id"], false, false)
				print(msg["data"])
				proj.apply_calibration()
				proj.calibration = false
				
				
			"calibrate_projector":
				print("Switching Projector ", msg["projector_id"], " to Calibration Mode")
				print("Received ChArUco image!")
				
				var b64 = msg["image_b64"]
				var raw_img_data = Marshalls.base64_to_raw(b64)
				var img = Image.new()
				img.load_png_from_buffer(raw_img_data)
				
				#var texture = ImageTexture.create_from_image(img)
				
				var proj = $Projectors.find_child(msg["projector_id"], false, false)
				proj.calibration_img = img
				proj.calibration = true
