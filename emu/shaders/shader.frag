#version 460 core
layout (location = 0) out vec4 FragColor;

layout (location = 0) in vec2 TexCoord;

layout (set = 3, binding = 0) uniform Stuff {
    vec2 coordScale;
    vec2 coordOffset;
    vec4 color;
} stuff;

layout (set = 2, binding = 0) uniform sampler2D my_texture;

void main()
{
    vec4 tex = texture(my_texture, TexCoord * stuff.coordScale + stuff.coordOffset);
    if (tex.w == 0) {
        discard;
    }
    FragColor = tex * stuff.color;
}