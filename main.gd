extends Node3D

const BallScene = preload("res://floatingBall.tscn")

@onready var heightmapReceiver = $HeightmapReceiver
@onready var terrain = $Terrain

var ball_every := 1.0
var ball_spawntime := 0.0

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	heightmapReceiver.connect("newHeightmap", update_heightmap)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	ball_spawntime += delta
	if ball_spawntime >= ball_every:
		spawn_ball()
		ball_spawntime = 0.0

func update_heightmap():
	terrain.update_heightmap(heightmapReceiver.heightmap)

func spawn_ball():
	var newBall = BallScene.instantiate()
	newBall.find_child("FloatComponent").water_sim = terrain
	var msize = terrain.mesh_size
	var randpos = Vector3(randf()*(msize-1) - (msize-1)/2, 0, randf()*(msize-1) - (msize-1)/2)
	add_child(newBall)
	newBall.global_position = Vector3(randpos.x, terrain.get_surface_info(randpos).x+0.5, randpos.z)
