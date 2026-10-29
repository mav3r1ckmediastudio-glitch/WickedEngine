// Short atmospheric streaks, scheduled independently of native star density.
// No entities, particle emitters or scene writes per frame. Compute-safe shader.
#ifndef RENEGADE_SHOOTING_STARS_HLSLI
#define RENEGADE_SHOOTING_STARS_HLSLI
float RenMeteorHash(float v) {return frac(sin(v*12.9898+78.233)*43758.5453);}
float3 RenMeteorStreak(float3 ray,float3 center,float2 travel,float age,float duration,
                       float travelRadians,float lengthDegrees,float brightness)
{
    if(age<0 || age>=duration || dot(ray,center)<.90) return 0;
    float t=age/duration;
    float3 right=normalize(cross(abs(center.y)>.999?float3(0,0,1):float3(0,1,0),center));
    float3 up=cross(center,right);
    float2 q=float2(dot(ray,right),dot(ray,up))/max(dot(ray,center),.01);
    float2 head=travel*((t-.5)*travelRadians);
    float behind=dot(head-q,travel);
    float width=radians(.035);
    float trail=radians(lengthDegrees)*smoothstep(0,.15,t);
    if(behind < -width*4 || behind > trail || trail<=0) return 0;
    float across=dot(q-head,float2(-travel.y,travel.x));
    float core=exp(-dot(q-head,q-head)/(width*width*3));
    float tail=exp(-across*across/(width*width))*
        pow(saturate(1-max(behind,0)/trail),1.6);
    float fade=smoothstep(0,.06,t)*(1-smoothstep(.58,1,t));
    return (float3(1,.97,.9)*core*2.5+float3(.64,.79,1)*tail)*brightness*fade;
}
float3 RenegadeShootingStars(float3 direction,float3 sun,float3 settings,float time,float previewTime)
{
    float night=RenegadeNightWeight(sun);
    [branch] if(settings.x<=0 || settings.y<=0 || night<=0 || direction.y<0) return 0;
    float3 ray=normalize(direction),colour=0;
    float interval=240/max(settings.x,.1); // four independent jittered lanes
    float current=floor(time/interval);
    [unroll] for(int lane=0;lane<4;++lane)
    [unroll] for(int previous=0;previous<2;++previous)
    {
        float slot=current-previous;
        float seed=slot*41.37+lane*81.7;
        float start=(slot+RenMeteorHash(seed+1)*.85)*interval;
        float duration=.45+.45*RenMeteorHash(seed+2);
        float age=time-start;
        [branch] if(age>=0 && age<duration)
        {
            float azimuth=6.2831853*RenMeteorHash(seed+3);
            float elevation=radians(18+54*RenMeteorHash(seed+4));
            float3 center=float3(cos(elevation)*sin(azimuth),sin(elevation),cos(elevation)*cos(azimuth));
            float2 travel=normalize(float2(RenMeteorHash(seed+5)>.5?1:-1,-.3-.6*RenMeteorHash(seed+6)));
            colour+=RenMeteorStreak(ray,center,travel,age,duration,
                radians(12+20*RenMeteorHash(seed+7)),settings.z,settings.y);
        }
    }
    // User preview appears near the current view, only when looking toward sky.
    float previewAge=time-previewTime;
    [branch] if(previewAge>=0 && previewAge<.9 && GetCamera().forward.y>-.15)
    {
        float3 center=normalize(GetCamera().forward+float3(0,.12,0));
        if(center.y>.04)
            colour+=RenMeteorStreak(ray,center,normalize(float2(1,-.45)),previewAge,.9,
                radians(26),settings.z,settings.y);
    }
    return colour*night*smoothstep(0,.06,ray.y);
}
#endif
