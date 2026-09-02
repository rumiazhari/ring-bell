extends Node
func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.has("--fringe-dump"):
		return
	print("[FringeDump] starting")
	var seeds: Array[int] = [WorldSeed.get_world_seed(), WorldSeed.get_world_seed() + 1234567]
	# Also allow --seed override for second run, but we dump both here
	var out_base := "C:/Vibe Code project/Godot Project/ring-bell/.hermes/autopilot/reports/fringe-part1/real"
	DirAccess.make_dir_recursive_absolute(out_base)
	for seed in seeds:
		var wp := WorldPlan.new(seed)
		var fringe = wp.fringe
		var builds: Array[Dictionary] = fringe.fringe_buildings()
		var lms: Array[Dictionary] = fringe.landmarks()
		print("[FringeDump] seed %d buildings %d landmarks %d" % [seed, builds.size(), lms.size()])
		var data := {
			"seed": seed,
			"buildings": builds,
			"landmarks": lms,
		}
		var path := "%s/fringe_dump_%d.json" % [out_base, seed]
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(data))
			f.close()
			print("[FringeDump] saved %s" % path)
		else:
			print("[FringeDump] failed to save %s" % path)
	# Also dump a simple top-down map image via Image
	await _generate_map_image(seeds[0])
	print("[FringeDump] done")
	get_tree().quit(0)

func _generate_map_image(seed: int) -> void:
	var wp := WorldPlan.new(seed)
	var fringe = wp.fringe
	var builds: Array[Dictionary] = fringe.fringe_buildings()
	var img_size := 1024
	var world_extent := 2500.0 # from -1250 to 1250
	var img := Image.create(img_size, img_size, false, Image.FORMAT_RGB8)
	img.fill(Color(0.62, 0.78, 0.62)) # countryside green
	# Draw terrain water etc as background: use hydrology
	# Draw roads as grey lines
	var rp := wp.road_network
	var segs: Array[Dictionary] = rp.road_segments()
	for seg in segs:
		var poly: PackedVector2Array = seg["polyline"] as PackedVector2Array
		for i in range(poly.size()-1):
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[i+1]
			if a.length() > 1300 and b.length() > 1300:
				continue
			var pa := _world_to_img(a, img_size, world_extent)
			var pb := _world_to_img(b, img_size, world_extent)
			_draw_line(img, pa, pb, Color(0.45, 0.45, 0.45), 2)
	# Draw fringe buildings color by type
	for b in builds:
		var c: Vector2 = b["center"] as Vector2
		if c.length() > 1250:
			continue
		var ft: StringName = b["fringe_type"] as StringName
		var col: Color
		if ft == &"inner_fringe":
			col = Color(0.82, 0.32, 0.32) # redish dense
		elif ft == &"outer_fringe":
			col = Color(0.82, 0.62, 0.22) # orange
		else:
			col = Color(0.72, 0.72, 0.82) # light blue peri
		var arch: StringName = b["arch"] as StringName
		if arch == &"small_factory" or arch == &"warehouse":
			col = Color(0.35, 0.35, 0.38) # industrial dark
		var p := _world_to_img(c, img_size, world_extent)
		var sz: int = 4
		if ft == &"inner_fringe":
			sz = 5
		elif ft == &"outer_fringe":
			sz = 4
		else:
			sz = 3
		_draw_rect(img, p, sz, col)
	# Draw landmarks as black crosses
	var lms: Array[Dictionary] = fringe.landmarks()
	for lm in lms:
		var c: Vector2 = lm["center"] as Vector2
		if c.length() > 1250:
			continue
		var p := _world_to_img(c, img_size, world_extent)
		_draw_cross(img, p, 7, Color(0,0,0))
	# Draw circles for 350 and 600 for reference (thin)
	_draw_circle(img, _world_to_img(Vector2.ZERO, img_size, world_extent), int(350/world_extent*img_size), Color(1,1,1,0.35), false)
	_draw_circle(img, _world_to_img(Vector2.ZERO, img_size, world_extent), int(600/world_extent*img_size), Color(1,1,1,0.35), false)
	var out_base := "C:/Vibe Code project/Godot Project/ring-bell/.hermes/autopilot/reports/fringe-part1/real"
	var path := "%s/fringe_map_seed_%d.png" % [out_base, seed]
	var err := img.save_png(path)
	if err == OK:
		print("[FringeDump] map saved %s" % path)
	else:
		print("[FringeDump] map save failed %d" % err)

func _world_to_img(p: Vector2, img_size: int, extent: float) -> Vector2i:
	# extent is half-size world (e.g. 1250), img center is extent
	var scale: float = float(img_size) / (extent*2.0)
	var x: int = int((p.x + extent) * scale)
	var y: int = int((extent - p.y) * scale) # flip y
	return Vector2i(clamp(x,0,img_size-1), clamp(y,0,img_size-1))

func _draw_line(img: Image, a: Vector2i, b: Vector2i, col: Color, w: int) -> void:
	var dx: int = abs(b.x - a.x)
	var dy: int = abs(b.y - a.y)
	var sx: int = 1 if a.x < b.x else -1
	var sy: int = 1 if a.y < b.y else -1
	var err: int = dx - dy
	var x: int = a.x
	var y: int = a.y
	while true:
		for ox in range(-w/2, w/2+1):
			for oy in range(-w/2, w/2+1):
				var px: int = clamp(x+ox, 0, img.get_width()-1)
				var py: int = clamp(y+oy, 0, img.get_height()-1)
				img.set_pixel(px, py, col)
		if x == b.x and y == b.y:
			break
		var e2: int = 2*err
		if e2 > -dy:
			err -= dy
			x += sx
		if e2 < dx:
			err += dx
			y += sy

func _draw_rect(img: Image, p: Vector2i, sz: int, col: Color) -> void:
	for dx in range(-sz, sz+1):
		for dy in range(-sz, sz+1):
			var px: int = clamp(p.x+dx, 0, img.get_width()-1)
			var py: int = clamp(p.y+dy, 0, img.get_height()-1)
			img.set_pixel(px, py, col)

func _draw_cross(img: Image, p: Vector2i, sz: int, col: Color) -> void:
	for d in range(-sz, sz+1):
		var px: int = clamp(p.x+d, 0, img.get_width()-1)
		var py: int = clamp(p.y, 0, img.get_height()-1)
		img.set_pixel(px, py, col)
		px = clamp(p.x, 0, img.get_width()-1)
		py = clamp(p.y+d, 0, img.get_height()-1)
		img.set_pixel(px, py, col)

func _draw_circle(img: Image, center: Vector2i, r: int, col: Color, fill: bool) -> void:
	for ang in range(0, 360, 2):
		var rad: float = deg_to_rad(float(ang))
		var x: int = int(center.x + cos(rad)*r)
		var y: int = int(center.y + sin(rad)*r)
		if x >=0 and x < img.get_width() and y >=0 and y < img.get_height():
			img.set_pixel(x, y, col)
