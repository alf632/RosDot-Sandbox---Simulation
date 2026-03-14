shader_type spatial;

uniform sampler2D terrain_map : hint_default_black;
uniform sampler2D color_gradient : source_color;
uniform float height_scale = 1.0;
uniform float contour_interval = 0.05; 
uniform float contour_thickness = 0.5;
uniform float plane_size = 6.0;

void vertex() {
    float t_h = texture(terrain_map, UV).r * height_scale;
    VERTEX.y += t_h;
    
    // Normal Calculation
    vec2 texel = 1.0 / vec2(textureSize(terrain_map, 0));
    float h_r = texture(terrain_map, UV + vec2(texel.x, 0.0)).r * height_scale;
    float h_u = texture(terrain_map, UV + vec2(0.0, texel.y)).r * height_scale;
    
    float world_step_x = plane_size * texel.x;
    float world_step_y = plane_size * texel.y;
    vec3 right_vec = normalize(vec3(world_step_x, h_r - t_h, 0.0));
    vec3 up_vec = normalize(vec3(0.0, h_u - t_h, world_step_y));
    NORMAL = normalize(cross(up_vec, right_vec));
}

void fragment() {
    float t_h = texture(terrain_map, UV).r * height_scale;
    float t_lookup = clamp(t_h / height_scale, 0.0, 1.0);
    vec3 terrain_col = texture(color_gradient, vec2(t_lookup, 0.0)).rgb;

    float z = t_h / contour_interval;
    float line = abs(fract(z - 0.5) - 0.5) / fwidth(z);
    float contour_mask = 1.0 - smoothstep(0.0, contour_thickness, line);
    
    ALBEDO = mix(terrain_col, vec3(0.0), contour_mask);
    ROUGHNESS = 0.8;
}