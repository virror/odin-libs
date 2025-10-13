#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct Stuff
{
    float2 coordScale;
    float2 coordOffset;
    float4 color;
};

struct main0_out
{
    float4 FragColor [[color(0)]];
};

struct main0_in
{
    float2 TexCoord [[user(locn0)]];
    float2 FragPos [[user(locn1)]];
    float2 CamPos [[user(locn2)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant Stuff& stuff [[buffer(0)]], texture2d<float> my_texture [[texture(0)]], sampler my_textureSmplr [[sampler(0)]])
{
    main0_out out = {};
    float4 tex = my_texture.sample(my_textureSmplr, ((in.TexCoord * stuff.coordScale) + stuff.coordOffset));
    if (tex.w == 0)
    {
        discard;
    }
    out.FragColor = tex * stuff.color;
    return out;
}