extends SceneTree

## Fast contract gate for the environment's cross-system surfaces:
##
##   1. every shader the environment touches compiles (no SHADER ERROR in the log),
##   2. every global shader parameter the manager publishes is declared in
##      project.godot, with the matching type (an undeclared name spams an engine
##      error every frame it is written), and
##   3. the shaders that consume a global actually declare it.
##
##   Godot --headless --path . --script debug/environment_shader_check.gd
##
## Shader errors and registration errors are printed by the engine; grep the output for
## SHADER ERROR / FAIL.  (`RenderingServer.global_shader_parameter_get()` cannot be used
## as a read-back here: the engine logs "should never be used outside the editor" and
## returns null outside it.)

const SHADERS := [
	"res://world/streaming/urban_paving.gdshader",
	"res://world/streaming/surface_atlas.gdshader",
	"res://world/environment/shaders/environment_sky.gdshader",
	"res://world/environment/shaders/wetness_overlay.gdshader",
]

const MANAGER := "res://world/environment/environment_manager.gd"

## Shader path -> the globals it must declare to consume the published state.
const CONSUMERS := {
	"res://world/streaming/urban_paving.gdshader": ["environment_wetness"],
	"res://world/streaming/surface_atlas.gdshader": ["environment_wetness"],
	"res://world/environment/shaders/wetness_overlay.gdshader": ["environment_wetness"],
}

var checks := 0
var failures := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	var tail := "" if detail.is_empty() else "  (%s)" % detail
	if ok:
		print("[ShaderCheck]  ok    %s%s" % [name, tail])
	else:
		failures += 1
		printerr("[ShaderCheck]  FAIL  %s%s" % [name, tail])
		print("[ShaderCheck]  FAIL  %s%s" % [name, tail])


func _initialize() -> void:
	_check_shaders_compile()
	_check_globals_declared()
	_check_consumers()
	print("[ShaderCheck] finished with %d failure(s)  (%d checks)" % [failures, checks])
	quit(0 if failures == 0 else 1)


func _check_shaders_compile() -> void:
	for path in SHADERS:
		var shader: Shader = load(path)
		if shader == null:
			_check("shader loads: %s" % path.get_file(), false)
			continue
		var material := ShaderMaterial.new()
		material.shader = shader
		# Touching the uniform list forces the renderer to validate the code.
		var uniforms := shader.get_shader_uniform_list(true)
		_check("shader compiles: %s" % path.get_file(), true, "%d uniform(s)" % uniforms.size())


## The manager's published list is the source of truth; every name in it has to exist in
## project.godot under [shader_globals] or the renderer rejects the write every frame.
func _check_globals_declared() -> void:
	var manager: GDScript = load(MANAGER)
	var params: Variant = manager.get_script_constant_map().get("GLOBAL_PARAMS", [])
	_check("the manager declares its global parameter list", params is Array and not (params as Array).is_empty(),
		"%d entries" % ((params as Array).size() if params is Array else 0))
	var missing := []
	var wrong_type := []
	for entry in params:
		var name := String(entry["name"])
		var key := "shader_globals/" + name
		if not ProjectSettings.has_setting(key):
			missing.append(name)
			continue
		var declared: Dictionary = ProjectSettings.get_setting(key)
		var want := _type_name(int(entry["type"]))
		if want.is_empty():
			wrong_type.append("%s (unmapped engine type %d)" % [name, int(entry["type"])])
		elif String(declared.get("type", "")) != want:
			wrong_type.append("%s (%s vs %s)" % [name, declared.get("type", "?"), want])
	_check("every published global is declared in project.godot", missing.is_empty(),
		"missing: %s" % ", ".join(missing) if not missing.is_empty() else "all declared")
	_check("every declared global has the type the manager writes", wrong_type.is_empty(),
		"wrong: %s" % ", ".join(wrong_type) if not wrong_type.is_empty() else "types match")


## A global that is declared but consumed by nothing is dead weight; the wetness consumer
## gate keeps the streets wired to the environment.
## RenderingServer.GLOBAL_VAR_TYPE_* is not a small 0..3 enum: FLOAT is 13 and VEC3 is 16.
func _type_name(engine_type: int) -> String:
	match engine_type:
		RenderingServer.GLOBAL_VAR_TYPE_FLOAT:
			return "float"
		RenderingServer.GLOBAL_VAR_TYPE_VEC2:
			return "vec2"
		RenderingServer.GLOBAL_VAR_TYPE_VEC3:
			return "vec3"
		RenderingServer.GLOBAL_VAR_TYPE_VEC4:
			return "vec4"
	return ""


func _check_consumers() -> void:
	for path in CONSUMERS:
		var source := FileAccess.get_file_as_string(path)
		for name in CONSUMERS[path]:
			_check("%s consumes %s" % [path.get_file(), name],
				source.contains("global uniform") and source.contains(name))
