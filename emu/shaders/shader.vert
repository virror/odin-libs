#version 460 core
layout (location = 0) in vec2 aPos;
layout (location = 1) in vec2 aTexCoord;

layout (location = 0) out vec2 TexCoord;

layout (set = 1, binding = 0) uniform Stuff {
    mat4 model;
	vec2 resolution;
    vec2 cameraPos;
    vec2 flip;
} stuff;

void main()
{
    gl_Position =
        (stuff.model * vec4(aPos, 0.0, 1.0) - vec4(stuff.cameraPos, 0.0, 0.0)) /
        vec4(stuff.resolution.x / 2.0, stuff.resolution.y / 2.0, 1, 1);

    vec2 tx = aTexCoord;
    if(stuff.flip.x == 1)
        tx = vec2(1.0 - tx.x, tx.y);
    if(stuff.flip.y == 1)
        tx = vec2(tx.x, 1.0 - tx.y);
    TexCoord = tx;
}