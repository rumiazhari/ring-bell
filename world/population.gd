class_name Population
extends RefCounted
## Spawn manifest for the Prototype 0 test block.
##
## Pure data: who exists, where they start, what they carry, how brave they
## are. main.gd turns these entries into live actors; save/load reuses the
## same shape so respawning after load needs no special cases.
##
## Positions must match LevelBuilder's layout:
##   Apartment interior: x -20..-8, z -17..-10 (door on east wall)
##   Store interior:     x  10..19, z   9..15 (door on west wall)

const PLAYER_ENTRY := {
	"id": &"player",
	"name": "Aki Sato",
	"occupation": "Delivery rider",
	"faction": &"survivors",
	"is_player": true,
	"position": Vector3(0, 0.1, 4),
	"facing": Vector3(0, 0, -1),
	"color": Color(0.35, 0.55, 0.85),
	"weapon": &"pipe",
	"items": {&"canned_food": 2, &"water_bottle": 2},
}

const SURVIVORS := [
	{
		"id": &"npc_kenji",
		"name": "Kenji Tanaka",
		"occupation": "Carpenter, father of Hana",
		"faction": &"survivors",
		"position": Vector3(-13, 0.1, -12),
		"facing": Vector3(1, 0, 0),
		"color": Color(0.72, 0.6, 0.42),
		"weapon": &"",
		"items": {&"canned_food": 2},
		"cowardice": 0.8,
	},
	{
		# QUEST TARGET: a real simulated survivor living her own life.
		"id": &"npc_hana",
		"name": "Hana Tanaka",
		"occupation": "Student, daughter of Kenji",
		"faction": &"survivors",
		"position": Vector3(22, 0.1, -8),
		"facing": Vector3(0, 0, 1),
		"color": Color(0.85, 0.7, 0.75),
		"weapon": &"",
		"items": {&"water_bottle": 2, &"canned_food": 1},
		"cowardice": 1.5,
	},
	{
		"id": &"npc_masa",
		"name": "Old Masa",
		"occupation": "Shopkeeper of Sato Mart",
		"faction": &"survivors",
		"position": Vector3(13, 0.1, 11),
		"facing": Vector3(-1, 0, 0),
		"color": Color(0.55, 0.62, 0.45),
		"weapon": &"",
		"items": {},
		"cowardice": 1.3,
	},
	{
		"id": &"npc_rina",
		"name": "Rina Okada",
		"occupation": "Nurse from the riverside clinic",
		"faction": &"survivors",
		"position": Vector3(-4, 0.1, 14),
		"facing": Vector3(0, 0, 1),
		"color": Color(0.9, 0.9, 0.95),
		"weapon": &"",
		"items": {&"bandage": 1},
		"cowardice": 1.2,
	},
	{
		"id": &"npc_tetsu",
		"name": "Tetsu Gonda",
		"occupation": "Warehouse forklift operator",
		"faction": &"survivors",
		"position": Vector3(-22, 0.1, 6),
		"facing": Vector3(0, 0, -1),
		"color": Color(0.45, 0.48, 0.55),
		"weapon": &"",
		"items": {&"canned_food": 1},
		"cowardice": 0.6,
	},
	{
		"id": &"npc_yuki",
		"name": "Yuki Mori",
		"occupation": "Convenience store clerk (rival chain)",
		"faction": &"survivors",
		"position": Vector3(24, 0.1, -12),
		"facing": Vector3(-1, 0, 0),
		"color": Color(0.75, 0.65, 0.85),
		"weapon": &"",
		"items": {&"water_bottle": 1},
		"cowardice": 1.4,
	},
]

## Zombie start positions (slow shamblers near block edges and alleys).
## Deliberately kept away from Hana's corner so she survives a calm session -
## but wandering hordes CAN reach her, which is exactly the point.
const ZOMBIE_POSITIONS := [
	Vector3(-28, 0.1, -24), Vector3(26, 0.1, 22), Vector3(-26, 0.1, 18),
	Vector3(30, 0.1, -22), Vector3(0, 0.1, -27), Vector3(-6, 0.1, 27),
	Vector3(15, 0.1, -25), Vector3(-33, 0.1, -2), Vector3(34, 0.1, 5),
	Vector3(-12, 0.1, -30), Vector3(20, 0.1, 29), Vector3(4, 0.1, -16),
	Vector3(-18, 0.1, 12), Vector3(12, 0.1, 18), Vector3(-31, 0.1, 28),
	Vector3(35, 0.1, -12),
]
