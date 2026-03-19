extends Node

signal newHeightmap

@export var udp_port: int = 4242
var udp_server: PacketPeerUDP
var heightmap: Image

func _ready():
	# Initialize the UDP listener
	udp_server = PacketPeerUDP.new()
	var err = udp_server.bind(udp_port)
	if err != OK:
		print("Error binding to UDP port: ", err)
	else:
		print("Listening for Heightmap on UDP ", udp_port)


func _process(_delta):
	# Process all available packets in the buffer
	while udp_server.get_available_packet_count() > 0:
		var packet :PackedByteArray = udp_server.get_packet()
		
		# Load the PNG bytes into a Godot Image
		var img :Image = Image.new()
		var err :Error = img.load_png_from_buffer(packet)
		
		if err == OK:
			img.convert(Image.FORMAT_RF)
			img.flip_y()
			heightmap = img
			emit_signal("newHeightmap")
			# Optional: Pass this texture to your terrain shader material
			# var mat = $SandMesh.material_override as ShaderMaterial
			# mat.set_shader_parameter("heightmap", heightmap_texture)
