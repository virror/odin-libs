#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct Stuff
{
    float4x4 model;
    float2 resolution;
    float2 cameraPos;
    float2 flip;
};

struct main0_out
{
    float2 TexCoord [[user(locn0)]];
    float2 FragPos [[user(locn1)]];
    float2 CamPos [[user(locn2)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float2 aPos [[attribute(0)]];
    float2 aTexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant Stuff& stuff [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = ((stuff.model * float4(in.aPos, 0.0, 1.0)) - float4(stuff.cameraPos, 0.0, 0.0))
        / float4(stuff.resolution.x / 2.0, stuff.resolution.y / 2, 1.0, 1.0);
    float2 tx = in.aTexCoord;
    if (stuff.flip.x == 1.0)
    {
        tx = float2(1.0 - tx.x, tx.y);
    }
    if (stuff.flip.y == 1.0)
    {
        tx = float2(tx.x, 1.0 - tx.y);
    }
    out.TexCoord = tx;
    out.FragPos = float2((stuff.model * float4(in.aPos, 0.0, 1.0)).xy);
    out.CamPos = stuff.cameraPos;
    return out;
}

