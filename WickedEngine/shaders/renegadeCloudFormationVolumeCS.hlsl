#include "globals.hlsli"
#include "renegadeCloudBodyTemplate.hlsli"
Texture3D<float4> detailNoise : register(t0);
RWTexture3D<float4> bodyVolume : register(u0);
[numthreads(8,8,8)]
void main(uint3 id : SV_DispatchThreadID)
{
    uint w,h,d;bodyVolume.GetDimensions(w,h,d);
    if(any(id>=uint3(w,h,d)))return;
    uint2 tile=uint2(w/2,h/2);
    uint variant=id.x/tile.x+2*(id.y/tile.y);
    float3 resolution=float3(tile,d);
    float3 uv=(float3(id.x%tile.x,id.y%tile.y,id.z)+.5)/resolution;
    float3 extent=float3(5000,4000,5000);
    float3 local=uv*extent-float3(2500,0,2500);
    bodyVolume[id]=RenegadeCumulusTemplateGeometry(detailNoise,local,variant,extent/resolution);
}
