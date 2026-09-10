// Surface detail atlas for city/building geometry.
//
// Background: the batcher emits one mesh surface per layer and used to rely
// purely on vertex colour, which is why interiors read as flat untextured
// blocks. Every box now carries ONE extra vertex attribute:
//
//   UV = (atlas tile index, metres per tile)      [see MeshBatcher.TILE_*]
//
// The pattern coords themselves are derived in the vertex stage from WORLD
// position, so no second UV array is needed - vertex data stays small because
// this runs over every box in a streamed city (extra bytes per vertex showed
// up directly as slower chunk regeneration).
//
// The atlas is MULTIPLIED by the vertex colour, so the per-building palette,
// weathering and decay shading all still apply; the atlas only adds the
// surface structure that flat vertex colours could not express.
//
// Tiles are neutral grey by design: tinting stays the job of vertex colour.
// Filtering is plain linear+mipmap (no anisotropic): anisotropic sampling of a
// 1024px atlas over a whole city cost more than the detail was worth.

shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_enable;
// Atlas grid resolution (4x4 tiles by default).
uniform vec2 atlas_grid = vec2(4.0, 4.0);
// Half-texel inset as a fraction of one tile, to stop linear filtering from
// pulling in neighbouring tiles at the cell edges.
uniform float tile_inset = 0.004;
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.92;
uniform float metallic_hint : hint_range(0.0, 1.0) = 0.0;

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
	vec2 grid = atlas_grid;
	vec2 cell = vec2(mod(v_tile, grid.x), floor(v_tile / grid.x));
	// Planar world-space mapping on the dominant axis of the face normal:
	// detail tiles at a real size regardless of how large the box is.
	vec2 plane = abs(v_wnormal.x) > 0.5 ? v_world.zy
			: (abs(v_wnormal.y) > 0.5 ? v_world.xz : v_world.xy);
	vec2 local = clamp(fract(plane / v_span), vec2(tile_inset), vec2(1.0 - tile_inset));
	vec2 atlas_uv = (cell + local) / grid;
	vec3 detail = texture(atlas, atlas_uv).rgb;
	ALBEDO = detail * COLOR.rgb;
	ROUGHNESS = surface_roughness;
	METALLIC = metallic_hint;
}
