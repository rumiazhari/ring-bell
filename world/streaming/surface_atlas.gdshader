// Surface detail for city/building/ground geometry.
//
// Background: the batcher emits one mesh surface per layer and used to rely
// purely on vertex colour, which is why everything read as flat untextured
// blocks. Every box now carries ONE extra vertex attribute:
//
//   UV = (atlas tile index, metres per tile)      [see MeshBatcher.TILE_*]
//
// and the pattern coordinates are derived in the vertex stage from WORLD
// position, so no second UV array is needed - vertex bytes are streaming
// budget here and this runs over every box in a streamed city.
//
// Uses a TEXTURE ARRAY, not an atlas image: each tile then has its own mip
// chain (an atlas blurs into its neighbours as mip levels mix, which is what
// made the first attempt look muddy at any distance) and per-layer REPEAT
// handles wrapping with contiguous UV derivatives, so mip selection is correct
// across tile repeats. Tiles are authored to be tileable (see
// tools/gen_surface_atlas.py).
//
// The tile is MULTIPLIED by the vertex colour, so the per-building palette and
// the decay weathering still apply on top; tiles carry structure only.
//
// Filtering is linear + mipmapped + anisotropic: surfaces are usually seen at
// grazing angles (floors, streets, walls down a corridor) and without
// anisotropic filtering those read as a blur no matter how sharp the source.

shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// NO source_color on purpose: the tiles are authored as neutral detail maps
// whose stored value IS the multiplier. Marking them source_color makes the
// engine treat them as sRGB and convert to linear, which silently drops the
// mean from 0.92 to ~0.83 and darkens every textured surface for no reason.
uniform sampler2DArray surface_tiles : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.92;
uniform float metallic_hint : hint_range(0.0, 1.0) = 0.0;
// 1 = full surface detail, 0 = plain vertex colour. Used by A/B capture runs
// (RB_NO_SURFACE_TILES=1) to measure exactly what the detail costs in light.
uniform float detail_strength : hint_range(0.0, 1.0) = 1.0;

varying flat float v_tile;
varying flat float v_span;
varying vec3 v_world;
varying vec3 v_wnormal;

void vertex() {
	v_tile = UV.x;
	v_span = max(UV.y, 0.05);
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// Planar world-space mapping on the dominant axis of the face normal.
	vec2 plane = abs(v_wnormal.x) > 0.5 ? v_world.zy
			: (abs(v_wnormal.y) > 0.5 ? v_world.xz : v_world.xy);
	// No fract() here: repeat_enable wraps per layer and keeps derivatives
	// continuous, so the mip level stays correct across tile boundaries.
	vec3 detail = texture(surface_tiles, vec3(plane / v_span, v_tile)).rgb;
	// Detail modulates around 1.0 rather than scaling down: with the tiles
	// normalised to a ~0.92 mean this is a ~8% darkening, and strength 0
	// reproduces the pre-texture look exactly.
	detail = mix(vec3(1.0), detail, detail_strength);
	ALBEDO = detail * COLOR.rgb;
	ROUGHNESS = surface_roughness;
	METALLIC = metallic_hint;
}
