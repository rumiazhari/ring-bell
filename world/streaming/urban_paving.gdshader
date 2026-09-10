shader_type spatial;
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
	ALBEDO = COLOR.rgb * mix(0.46, mix(0.86, 1.12, variation), stone);
	ROUGHNESS = 0.93;
}
