#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, r32f) restrict readonly uniform image2D terrain_map;
layout(set = 0, binding = 1, r32f) restrict readonly uniform image2D height_in;
layout(set = 0, binding = 2, rgba32f) restrict readonly uniform image2D flux_in;
layout(set = 0, binding = 3, rgba32f) restrict writeonly uniform image2D flux_out;

layout(push_constant) uniform Constants {
    int width; int height;
    float dt; float pipe_area; 
    float gravity; float retention;
    float damping;
    int pad1; 
} params;

void main() {
    ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
    if (uv.x >= params.width || uv.y >= params.height) return;

    float h = imageLoad(height_in, uv).x;
    float t = imageLoad(terrain_map, uv).x;
    float total_h = h + t;

    vec4 f_old = imageLoad(flux_in, uv);

    ivec2 bounds = ivec2(params.width - 1, params.height - 1);
    float h_r = imageLoad(height_in, clamp(uv + ivec2(1, 0), ivec2(0), bounds)).x + imageLoad(terrain_map, clamp(uv + ivec2(1, 0), ivec2(0), bounds)).x;
    float h_l = imageLoad(height_in, clamp(uv + ivec2(-1, 0), ivec2(0), bounds)).x + imageLoad(terrain_map, clamp(uv + ivec2(-1, 0), ivec2(0), bounds)).x;
    float h_u = imageLoad(height_in, clamp(uv + ivec2(0, -1), ivec2(0), bounds)).x + imageLoad(terrain_map, clamp(uv + ivec2(0, -1), ivec2(0), bounds)).x;
    float h_d = imageLoad(height_in, clamp(uv + ivec2(0, 1), ivec2(0), bounds)).x + imageLoad(terrain_map, clamp(uv + ivec2(0, 1), ivec2(0), bounds)).x;

    float K = params.dt * params.pipe_area * params.gravity;

    float f_r = max(0.0, (f_old.x + K * (total_h - h_r)) * params.damping);
    float f_l = max(0.0, (f_old.y + K * (total_h - h_l)) * params.damping);
    float f_u = max(0.0, (f_old.z + K * (total_h - h_u)) * params.damping);
    float f_d = max(0.0, (f_old.w + K * (total_h - h_d)) * params.damping);

    // --- THE FIX: Calculate how much water is actually allowed to leave ---
    float available_water = max(0.0, h - params.retention);
    float total_out = (f_r + f_l + f_u + f_d) * params.dt;
    
    // Scale down flux if it tries to pull more than the available water
    if (total_out > available_water && total_out > 0.0) {
        float factor = available_water / total_out;
        f_r *= factor; f_l *= factor; f_u *= factor; f_d *= factor;
    }

    imageStore(flux_out, uv, vec4(f_r, f_l, f_u, f_d));
}
