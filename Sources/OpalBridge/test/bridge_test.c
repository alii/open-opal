#include "OpalBridge.h"
#include <stdio.h>
#include <unistd.h>

static int frames = 0;
static void onFrame(const uint8_t* y, size_t ys, const uint8_t* uv, size_t uvs,
                    int w, int h, int64_t t, double lat, void* ctx) {
    if (frames == 0) printf("  first frame: %dx%d  latency=%.1fms  Y[0]=%d\n", w, h, lat, y[0]);
    frames++;
}

int main(void) {
    OpalDeviceInfo devs[4];
    int n = opal_list_devices(devs, 4);
    printf("discovered %d device(s)\n", n);
    for (int i = 0; i < n; i++)
        printf("  mxid=%s name=%s state=%d usable=%d\n",
               devs[i].mxid, devs[i].name, devs[i].state, devs[i].usable);
    if (n == 0) { printf("no camera\n"); return 1; }

    OpalPipelineConfig cfg = { .ispNum = 1, .ispDen = 2, .fps = 30, .keep4K = false };
    printf("opening (boots our pipeline onto the Myriad)...\n");
    OpalDeviceHandle* h = opal_open(devs[0].mxid, cfg, onFrame, NULL);
    if (!h) { printf("FAILED: %s\n", opal_last_error()); return 1; }

    char sensor[64]; int speed, w, ht;
    opal_get_info(h, sensor, 64, &speed, &w, &ht);
    printf("  sensor=%s usbSpeed=%d\n", sensor, speed);

    sleep(2);

    printf("applying manual controls (1/250s, ISO 800, 50Hz, focus 90)...\n");
    OpalControls c = {0};
    c.autoExposure = false; c.exposureUs = 4000; c.iso = 800;
    c.manualFocus = true;   c.lensPosition = 90;
    c.antiBanding = OPAL_AB_50HZ;
    c.manualWhiteBalance = true; c.whiteBalanceK = 3200;
    c.sharpness = 2; c.lumaDenoise = 1; c.chromaDenoise = 1;
    opal_set_controls(h, c);
    sleep(2);

    OpalTelemetry t;
    opal_get_telemetry(h, &t);
    printf("  TELEMETRY: %.1f fps | p50 latency %.1fms | exp=%dus iso=%d lens=%d wb=%dK\n",
           t.fps, t.latencyMsP50, t.reportedExposureUs, t.reportedIso,
           t.reportedLensPosition, t.reportedColorTempK);
    printf("  frames received: %d\n", frames);

    printf("closing (camera returns to UVC in ~5s)...\n");
    opal_close(h);
    printf("OK\n");
    return 0;
}
