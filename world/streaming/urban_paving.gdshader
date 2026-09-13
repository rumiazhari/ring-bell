shader_type spatial;
// Published by world/environment every frame: 0 dry .. 1 soaked.
global uniform float environment_wetness;
render_mode diffuse_burley;

uniform vec2 stone_size = vec2(0.32, 0.22);
uniform float joint_width = 0.045;
varying vec3 paving_position;

void vertex() {
	paving_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// World coordinates keep the pattern continuous across chunk owners.
	vec2 p = paving_position.xz / stone_size;
	p.x += mod(floor(p.y), 2.0) * 0.5;
	vec2 cell = floor(p);
	vec2 edge = min(fract(p), 1.0 - fract(p));
	float distance_to_joint = min(edge.x, edge.y);
	float aa = max(fwidth(distance_to_joint), 0.002);
	float stone = smoothstep(joint_width - aa, joint_width + aa, distance_to_joint);
	float variation = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
	// Wet cobbles darken and go glossy.  This global is the only wetness input the
	// city needs; before it was declared here, wetness only existed in the capture
	// fixture and the streets never changed.
	ALBEDO = COLOR.rgb * mix(0.46, mix(0.86, 1.12, variation), stone) * mix(1.0, 0.72, clamp(environment_wetness, 0.0, 1.0));
	ROUGHNESS = mix(0.93, 0.30, clamp(environment_wetness, 0.0, 1.0));
}
