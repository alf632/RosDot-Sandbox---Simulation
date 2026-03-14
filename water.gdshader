shader_type spatial;
// Enable transparency and ensure it casts shadows properly
render_mode blend_mix, depth_draw_always, shadows_disabled;

uniform sampler2D water_data : hint_default_black;
uniform sampler2D terrain_map : hint_default_black;
uniform sampler2D flux_data : hint_default_black;

// Depth texture to detect submerged objects
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;

uniform vec4 water_tint : source_color = vec4(0.1, 0.4, 0.7, 1.0);
uniform sampler2D normal_map : hint_normal; 
uniform float ripple_scale = 20.0;          
uniform float flow_speed = 1.0;             
uniform float ripple_strength = 0.8; 

uniform float height_scale = 1.0;
uniform float plane_size = 6.0;
uniform float foam_threshold = 0.01;

varying float v_water_h;

void vertex() {
    float w_h = texture(water_data, UV).r;
    float t_h = texture(terrain_map, UV).r;
    v_water_h = w_h;
    
    float total_h = (t_h + w_h) * height_scale;
    VERTEX.y += total_h;
    
    // Normal Calculation
    vec2 texel = 1.0 / vec2(textureSize(water_data, 0));
    float h_r = (texture(water_data, UV + vec2(texel.x, 0.0)).r + texture(terrain_map, UV + vec2(texel.x, 0.0)).r) * height_scale;
    float h_u = (texture(water_data, UV + vec2(0.0, texel.y)).r + texture(terrain_map, UV + vec2(0.0, texel.y)).r) * height_scale;
    float world_step_x = plane_size * texel.x;
    float world_step_y = plane_size * texel.y;
    vec3 right_vec = normalize(vec3(world_step_x, h_r - total_h, 0.0));
    vec3 up_vec = normalize(vec3(0.0, h_u - total_h, world_step_y));
    NORMAL = normalize(cross(up_vec, right_vec));
}

void fragment() {
    float w_h = v_water_h * height_scale;
    
    // If there is no water here, make this pixel completely invisible
    if (w_h < 0.005) {
        discard;
    }
    
    // --- TRUE DEPTH CALCULATION (For submerged objects!) ---
    // Read the depth buffer to find the physical distance to the object behind the water
    float depth_tex = texture(DEPTH_TEXTURE, SCREEN_UV).r;
    vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth_tex);
    vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
    view.xyz /= view.w;
    float linear_depth = -view.z;
    float surface_depth = -VERTEX.z;
    
    // The actual distance from the water surface to the submerged object
    float real_depth = linear_depth - surface_depth;
    
    // --- BEER'S LAW ---
    // The deeper the object is, the more opaque the water becomes
    float clarity = exp(-real_depth * 2.0);
    
    // --- VELOCITY & RIPPLES ---
    vec4 flux = texture(flux_data, UV);
    vec2 velocity = vec2(flux.x - flux.y, flux.w - flux.z);
    float speed = length(velocity);
    float ripple_visibility = smoothstep(0.001, 0.05, speed);
    
    vec2 flow_dir = speed > 0.001 ? velocity / speed : vec2(0.0);
    float time = TIME * flow_speed;
    float phase0 = fract(time);
    float phase1 = fract(time + 0.5);
    float flow_blend = abs((0.5 - phase0) * 2.0);

    vec2 uv0 = UV * ripple_scale - flow_dir * phase0 * speed * 2.0;
    vec2 uv1 = UV * ripple_scale - flow_dir * phase1 * speed * 2.0;
    vec3 normal0 = texture(normal_map, uv0).rgb;
    vec3 normal1 = texture(normal_map, uv1).rgb;
    
    // --- FOAM ---
    float static_foam = (1.0 - smoothstep(0.0, foam_threshold, w_h));
    float calm_mask = 1.0 - smoothstep(0.0, 0.5, speed);
    static_foam *= calm_mask;
    float flow_foam = smoothstep(0.2, 1.5, speed); 
    float total_foam = clamp(static_foam + flow_foam, 0.0, 1.0);
    
    // --- FINAL COMPOSITE ---
    vec3 final_col = mix(water_tint.rgb, vec3(1.0), total_foam);
    
    ALBEDO = final_col;
    // Set transparency based on true depth clarity, but keep foam solid
    ALPHA = mix(1.0 - clarity, 1.0, total_foam); 
    
    ROUGHNESS = mix(0.1, 0.6, flow_foam);
    NORMAL_MAP = mix(normal0, normal1, flow_blend);
    NORMAL_MAP_DEPTH = ripple_strength * ripple_visibility;
}