shader_type sky;
// Ring Bell environment sky.
//
// One cheap analytic sky that answers to time of day, cloud cover, rain, storm
// intensity and fog - no textures, no equirect maps, no expensive physical
// atmosphere.  Stylised (Borderlands/Telltale-ish gradients + hard-ish cloud
// masks), not photoreal, and it stays readable at midnight and in a storm.
//
// Driven exclusively by `world/environment/atmosphere_controller.gd`; every
// uniform below is written from there each time the value meaningfully changes.

uniform vec3 zenith_color : source_color = vec3(0.30, 0.45, 0.68);
uniform vec3 horizon_color : source_color = vec3(0.62, 0.72, 0.84);
uniform vec3 ground_color : source_color = vec3(0.10, 0.11, 0.13);
uniform vec3 sun_color : source_color = vec3(1.0, 0.96, 0.90);
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform float sun_energy : hint_range(0.0, 6.0) = 1.0;
uniform float sun_disc_scale : hint_range(0.2, 3.0) = 1.0;
uniform vec3 moon_color : source_color = vec3(0.74, 0.80, 0.96);
uniform vec3 moon_direction = vec3(0.0, -1.0, 0.0);
uniform float moon_energy : hint_range(0.0, 6.0) = 0.0;
uniform vec3 cloud_color : source_color = vec3(0.86, 0.88, 0.93);
uniform vec3 cloud_shadow_color : source_color = vec3(0.30, 0.33, 0.40);
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.0;
uniform float cloud_sharpness : hint_range(0.02, 0.60) = 0.16;
uniform float cloud_scale : hint_range(0.5, 12.0) = 3.0;
uniform float cloud_darkness : hint_range(0.0, 1.0) = 0.0;
uniform float cloud_height : hint_range(0.05, 1.0) = 0.32;
uniform vec2 cloud_offset = vec2(0.0);
uniform float cloud_steps : hint_range(1.0, 5.0) = 3.0;
uniform vec3 haze_color : source_color = vec3(0.62, 0.66, 0.72);
uniform float haze_amount : hint_range(0.0, 1.0) = 0.10;
uniform float star_amount : hint_range(0.0, 1.0) = 0.0;
uniform float flash : hint_range(0.0, 1.0) = 0.0;
uniform float exposure_scale : hint_range(0.2, 3.0) = 1.0;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p, float steps) {
	float sum = 0.0;
	float amp = 0.5;
	vec2 q = p;
	for (int i = 0; i < 5; i++) {
		if (float(i) >= steps) {
			break;
		}
		sum += amp * value_noise(q);
		q = q * 2.03 + vec2(13.7, 7.1);
		amp *= 0.5;
	}
	return sum;
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	float up = clamp(dir.y, -1.0, 1.0);

	// --- gradient body -----------------------------------------------------
	vec3 base = mix(zenith_color, horizon_color, pow(clamp(1.0 - abs(up), 0.0, 1.0), 2.2));
	base = mix(ground_color, base, smoothstep(-0.07, 0.02, up));

	vec3 col = base;

	// --- sun disc + glow ---------------------------------------------------
	vec3 sun_dir = normalize(sun_direction);
	float sun_dot = dot(dir, sun_dir);
	float disc_cos = cos(0.012 * sun_disc_scale);
	float sun_core = smoothstep(disc_cos - 0.0016, disc_cos, sun_dot);
	float sun_glow = pow(clamp(sun_dot, 0.0, 1.0), 22.0) * 0.55
		+ pow(clamp(sun_dot, 0.0, 1.0), 5.0) * 0.16;
	col += sun_color * (sun_core * 2.2 + sun_glow) * sun_energy;

	// --- moon disc (only when the moon is up) ------------------------------
	if (moon_energy > 0.001) {
		vec3 moon_dir = normalize(moon_direction);
		float moon_dot = dot(dir, moon_dir);
		float moon_disc_cos = cos(0.010 * sun_disc_scale);
		float moon_core = smoothstep(moon_disc_cos - 0.0012, moon_disc_cos, moon_dot);
		float moon_glow = pow(clamp(moon_dot, 0.0, 1.0), 30.0) * 0.25;
		col += moon_color * (moon_core * 1.5 + moon_glow) * moon_energy;
	}

	// --- clouds ------------------------------------------------------------
	float mask = 0.0;
	if (cloud_cover > 0.001 && up > -0.02) {
		vec2 plane = dir.xz / max(dir.y, 0.03) * cloud_height;
		vec2 uv = plane * cloud_scale + cloud_offset;
		float n = fbm(uv, cloud_steps);
		float threshold = 1.0 - cloud_cover;
		mask = smoothstep(threshold, threshold + cloud_sharpness, n);
		mask *= mix(0.30, 1.0, smoothstep(0.005, 0.11, dir.y));
		vec3 tint = mix(cloud_color, cloud_shadow_color, cloud_darkness);
		float toward_sun = clamp(sun_dot, 0.0, 1.0);
		tint = mix(tint, cloud_color * 1.12, toward_sun * 0.45);
		col = mix(col, tint, clamp(mask, 0.0, 1.0));
	}

	// --- stars (clear nights only) ----------------------------------------
	if (star_amount > 0.001 && up > 0.02) {
		vec2 cell = floor(dir.xz / 0.0035 + dir.y * 17.0);
		float star = hash12(cell);
		star = pow(max(star - 0.9952, 0.0) * 208.0, 1.4);
		col += vec3(0.85, 0.88, 1.0) * star * star_amount
			* (1.0 - clamp(mask, 0.0, 1.0))
			* smoothstep(0.02, 0.20, dir.y);
	}

	// --- horizon haze / fog band -------------------------------------------
	float haze = haze_amount * pow(clamp(1.0 - abs(up) * 2.2, 0.0, 1.0), 1.5);
	haze = max(haze, clamp(haze_amount, 0.0, 1.0) * (1.0 - smoothstep(0.0, 0.18, dir.y)) * 0.9);
	col = mix(col, haze_color, clamp(haze, 0.0, 0.94));

	// --- lightning ---------------------------------------------------------
	if (flash > 0.001) {
		col += vec3(0.72, 0.78, 1.0) * flash * (0.45 + 0.55 * max(mask, 0.30));
	}

	COLOR = col * exposure_scale;
	ALPHA = 1.0;
}
