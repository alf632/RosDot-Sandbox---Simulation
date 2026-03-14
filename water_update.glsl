#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, r32f) restrict readonly uniform image2D height_in;
layout(set = 0, binding = 1, rgba32f) restrict readonly uniform image2D flux_new;
layout(set = 0, binding = 2, r32f) restrict writeonly uniform image2D height_out;

struct Modifier { vec2 pos; float strength; float radius; };
layout(set = 0, binding = 3, std430) buffer ModData { Modifier mods[64]; } mod_list;

layout(push_constant) uniform Constants {
    int width; int height;
    float dt; float evaporation; // <-- Added evaporation here
    int source_count; int drain_count;
    int pad1; int pad2;
} params;

void main() {
    ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
    if (uv.x >= params.width || uv.y >= params.height) return;

    if (uv.x <= 1 || uv.x >= params.width-2 || uv.y <= 1 || uv.y >= params.height-2) {
        imageStore(height_out, uv, vec4(0.0));
        return;
    }

    float h = imageLoad(height_in, uv).x;
    vec4 f_out = imageLoad(flux_new, uv); 

    float in_r = imageLoad(flux_new, uv + ivec2(-1, 0)).x;
    float in_l = imageLoad(flux_new, uv + ivec2(1, 0)).y;
    float in_u = imageLoad(flux_new, uv + ivec2(0, 1)).z;
    float in_d = imageLoad(flux_new, uv + ivec2(0, -1)).w;

    float next_h = h + params.dt * ((in_r + in_l + in_u + in_d) - (f_out.x + f_out.y + f_out.z + f_out.w));

    // --- THE FIX: Global Evaporation ---
    next_h = max(0.0, next_h - params.evaporation * params.dt);

    vec2 current_uv = (vec2(uv) + 0.5) / vec2(params.width, params.height);
    for (int i = 0; i < params.source_count; i++) {
        if (distance(current_uv, mod_list.mods[i].pos) < mod_list.mods[i].radius) {
            next_h += mod_list.mods[i].strength * params.dt;
        }
    }
    for (int i = 0; i < params.drain_count; i++) {
        int idx = params.source_count + i;
        if (distance(current_uv, mod_list.mods[idx].pos) < mod_list.mods[idx].radius) {
            next_h = max(0.0, next_h - mod_list.mods[idx].strength * params.dt);
        }
    }

    imageStore(height_out, uv, vec4(max(0.0, next_h), 0.0, 0.0, 0.0));
}
