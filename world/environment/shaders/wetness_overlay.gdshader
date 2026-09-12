shader_type spatial;
// Reference consumer for the environment global uniforms published by
// world/environment/environment_manager.gd.
//
// Re-base a material on this shader, or copy the `global uniform` lines into an
// existing shader, to get weather-reactive surfaces with zero per-material
// scripting and zero per-frame material loops.
//
// The names must match EnvironmentManager.GP_* (and [shader_globals] in
// project.godot): environment_wetness, environment_rain_intensity,
// environment_storm, environment_wind_vector, environment_night_factor,
// environment_hour.

global uniform float environment_wetness;
global uniform float environment_rain_intensity;
global uniform float environment_storm;
global uniform vec3 environment_wind_vector;
global uniform float environment_night_factor;
global uniform float environment_hour;

uniform vec4 albedo : source_color = vec4(0.32, 0.31, 0.30, 1.0);
uniform float base_roughness : hint_range(0.0, 1.0) = 0.85;
uniform float wetness_strength : hint_range(0.0, 1.0) = 1.0;
uniform float groove_scale : hint_range(1.0, 400.0) = 60.0;

void fragment() {
	// Wet stone darkens and turns glossy.  The effect is capped (roughness floor
	// 0.18, no reflections pass) so a downpour never turns the street into a
	// mirror - "wet-looking roads, not a puddle renderer".
	float wet = clamp(environment_wetness * wetness_strength, 0.0, 1.0);
	float sheen = smoothstep(0.15, 0.75, wet);

	ALBEDO = albedo.rgb * mix(1.0, 0.70, wet);

	// Standing water collects in grooves: a cheap wind-driven streak that breaks
	// the uniformity of the sheen without a texture lookup.
	float streak = sin(UV.x * groove_scale + TIME * 0.35 + environment_wind_vector.x * 2.0) * 0.5 + 0.5;
	ROUGHNESS = clamp(mix(base_roughness, 0.18, sheen) - sheen * streak * 0.07, 0.05, 1.0);
	SPECULAR = mix(0.35, 0.85, sheen);

	// Rain dulls the diffuse response slightly and storms lift the dark end, so
	// geometry stays readable when the sky is black.  Never makes night brighter
	// than the lighting already is.
	ALBEDO *= mix(1.0, 0.94, clamp(environment_rain_intensity, 0.0, 1.0));
}
