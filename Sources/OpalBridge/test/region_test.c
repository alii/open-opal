#include "OpalBridge.h"
#include <stdio.h>
#include <unistd.h>
static void onFrame(const uint8_t*y,size_t a,const uint8_t*u,size_t b,int w,int h,int64_t t,double l,void*c){}
int main(void){
    OpalDeviceInfo d[4]; int n=opal_list_devices(d,4);
    if(!n){printf("no camera\n");return 1;}
    OpalPipelineConfig cfg={.ispNum=1,.ispDen=2,.fps=30,.keep4K=false,.orientation=OPAL_ORIENT_ROTATE_180};
    OpalDeviceHandle* h=opal_open(d[0].mxid,cfg,onFrame,NULL);
    if(!h){printf("FAILED: %s\n",opal_last_error());return 1;}

    OpalControls c={0};
    c.autoExposure=true; c.antiBanding=OPAL_AB_60HZ;
    opal_set_controls(h,c);
    sleep(3);

    OpalTelemetry t;
    struct { const char* name; float x,y,w,hh; } regions[] = {
        {"LEFT  half",  0.0f, 0.25f, 0.35f, 0.5f},
        {"RIGHT half",  0.65f,0.25f, 0.35f, 0.5f},
        {"TOP   band",  0.25f,0.0f,  0.5f,  0.3f},
        {"BOTTOM band", 0.25f,0.7f,  0.5f,  0.3f},
    };
    printf("If regions map correctly, exposure/ISO should DIFFER between areas\n");
    printf("of different brightness. (Identical numbers = region ignored.)\n\n");
    for(int i=0;i<4;i++){
        opal_set_exposure_region(h,regions[i].x,regions[i].y,regions[i].w,regions[i].hh);
        sleep(3);
        opal_get_telemetry(h,&t);
        printf("  %-12s -> exposure %6d us   ISO %4d\n",
               regions[i].name, t.reportedExposureUs, t.reportedIso);
    }
    opal_close(h);
    return 0;
}
