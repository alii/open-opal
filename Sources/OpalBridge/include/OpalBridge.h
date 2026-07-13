// OpalBridge — a thin C surface over depthai-core (C++) so Swift can drive the
// Opal C1's Myriad X over XLink without importing C++ into Swift directly.
//
// The C1 is a Luxonis DepthAI device (VID 0x03E7). Out of the box it runs a
// flashed firmware that presents a plain UVC webcam. Connecting over XLink
// reboots it with OUR pipeline, which takes the UVC node away — so while this
// bridge holds a device open, the system "Opal C1" camera disappears. Closing
// the device returns it to UVC in ~5s. This is expected and reversible.

#ifndef OPAL_BRIDGE_H
#define OPAL_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OPAL_MXID_LEN 64
#define OPAL_NAME_LEN 64

typedef struct OpalDeviceHandle OpalDeviceHandle;

typedef struct {
    char mxid[OPAL_MXID_LEN];
    char name[OPAL_NAME_LEN];
    int  state;        // OpalDeviceState
    bool usable;
} OpalDeviceInfo;

typedef enum {
    OPAL_STATE_UNKNOWN     = 0,
    OPAL_STATE_BOOTLOADER  = 1,
    OPAL_STATE_BOOTED      = 2,
    OPAL_STATE_FLASH_BOOTED = 3,  // stock Opal firmware: UVC webcam mode
    OPAL_STATE_UNBOOTED    = 4,
} OpalDeviceState;

// ---------------------------------------------------------------------------
// Pipeline configuration (applied at open; changing these requires a reopen)
// ---------------------------------------------------------------------------

typedef enum {
    OPAL_ORIENT_NORMAL     = 0,
    OPAL_ORIENT_ROTATE_180 = 1,
    OPAL_ORIENT_MIRROR     = 2,
    OPAL_ORIENT_VFLIP      = 3,
} OpalOrientation;

typedef struct {
    // The IMX582 ("LCM48") has NO native 1080p mode — its smallest sensor
    // config is 3840x2160. Pulling full 4K NV12 over USB is ~370 MB/s, which
    // saturates SuperSpeed: measured p50 latency 297ms and only 20fps.
    // Downscaling on the device ISP first drops that to 50ms at a solid 30fps.
    // So: always capture 4K, then let the ISP scale by ispNum/ispDen.
    int  ispNum;        // e.g. 1
    int  ispDen;        // e.g. 2 -> 1920x1080,  3 -> 1280x720
    int  fps;           // 1..42 at 4K sensor mode
    bool keep4K;        // true = no ISP scale (max quality, high latency)

    // The C1's sensor is mounted upside down in the housing. Opal's stock
    // firmware quietly corrects for this, so nobody ever noticed — but we boot
    // our own pipeline, so we get the raw sensor orientation and have to undo it
    // ourselves. The ISP does the rotation for free, which also means the fix
    // lands upstream of everything: preview, effects, and the virtual camera.
    OpalOrientation orientation;
} OpalPipelineConfig;

// ---------------------------------------------------------------------------
// Runtime controls (hot — sent over the XLink control queue, no reopen)
// ---------------------------------------------------------------------------

typedef enum {
    OPAL_AB_OFF = 0, OPAL_AB_50HZ = 1, OPAL_AB_60HZ = 2, OPAL_AB_AUTO = 3,
} OpalAntiBanding;

typedef enum {
    OPAL_AWB_OFF = 0, OPAL_AWB_AUTO = 1, OPAL_AWB_INCANDESCENT = 2,
    OPAL_AWB_FLUORESCENT = 3, OPAL_AWB_WARM_FLUORESCENT = 4,
    OPAL_AWB_DAYLIGHT = 5, OPAL_AWB_CLOUDY = 6, OPAL_AWB_TWILIGHT = 7,
    OPAL_AWB_SHADE = 8,
} OpalAwbMode;

typedef enum {
    OPAL_AF_OFF = 0, OPAL_AF_AUTO = 1, OPAL_AF_MACRO = 2,
    OPAL_AF_CONTINUOUS_VIDEO = 3, OPAL_AF_CONTINUOUS_PICTURE = 4, OPAL_AF_EDOF = 5,
} OpalAfMode;

typedef struct {
    // Exposure
    bool     autoExposure;
    int32_t  exposureUs;        // manual: 1..33000 (bounded by fps)
    int32_t  iso;               // manual: 100..1600
    int32_t  evCompensation;    // auto: -9..9
    bool     aeLock;

    // Focus  (the C1 has a real AF lens — hasAutofocus = true)
    OpalAfMode afMode;
    bool     manualFocus;
    int32_t  lensPosition;      // 0..255

    // White balance
    OpalAwbMode awbMode;
    bool     manualWhiteBalance;
    int32_t  whiteBalanceK;     // 1000..12000 Kelvin
    bool     awbLock;

    // Flicker — this is the "Hz" control in Composer's UI
    OpalAntiBanding antiBanding;

    // Image tuning
    int32_t  sharpness;         // 0..4
    int32_t  lumaDenoise;       // 0..4
    int32_t  chromaDenoise;     // 0..4
    int32_t  brightness;        // -10..10
    int32_t  contrast;          // -10..10
    int32_t  saturation;        // -10..10
} OpalControls;

// Frame callback. `y` and `uv` point into NV12 planes owned by the bridge and
// are ONLY valid for the duration of the call — copy out (into a CVPixelBuffer)
// before returning. Called on the bridge's capture thread.
typedef void (*OpalFrameCallback)(const uint8_t* y, size_t yStride,
                                  const uint8_t* uv, size_t uvStride,
                                  int width, int height,
                                  int64_t captureHostTimeNs,
                                  double latencyMs,
                                  void* ctx);

// --- boot log ----------------------------------------------------------------
// One human-readable line per stage of the takeover — reset, ROM bootloader,
// firmware upload, XLink handshake, pipeline instantiation — with real sizes
// and elapsed times. Set once, before any opal_open; lines arrive on internal
// threads.
typedef void (*OpalLogCallback)(const char* line, void* ctx);
void opal_set_boot_logger(OpalLogCallback cb, void* ctx);

// --- discovery -------------------------------------------------------------
int  opal_list_devices(OpalDeviceInfo* out, int maxCount);

// --- lifecycle -------------------------------------------------------------
// Boots our pipeline onto the device. Blocks ~2-5s. Returns NULL on failure;
// call opal_last_error() for a message.
OpalDeviceHandle* opal_open(const char* mxid, OpalPipelineConfig cfg,
                            OpalFrameCallback cb, void* ctx);
void opal_close(OpalDeviceHandle* h);

// --- runtime ---------------------------------------------------------------
void opal_set_controls(OpalDeviceHandle* h, OpalControls c);
void opal_trigger_autofocus(OpalDeviceHandle* h);
// Normalized [0,1] rect within the frame; drives AE + AF metering region.
void opal_set_focus_region(OpalDeviceHandle* h, float x, float y, float w, float h_);
// Auto-exposure metering region only (leaves focus alone). Used to meter on the
// person rather than the whole frame — with a bright window behind you, a
// full-frame average blows out the background and leaves your face in shadow.
void opal_set_exposure_region(OpalDeviceHandle* h, float x, float y, float w, float h_);

// --- introspection ---------------------------------------------------------
bool  opal_get_info(OpalDeviceHandle* h, char* sensorName, size_t n,
                    int* usbSpeed, int* width, int* height);
const char* opal_last_error(void);

// Live telemetry, so the UI can show real numbers instead of guessing.
typedef struct {
    double  latencyMsP50;
    double  fps;
    int32_t reportedExposureUs;
    int32_t reportedIso;
    int32_t reportedLensPosition;
    int32_t reportedColorTempK;
} OpalTelemetry;
bool opal_get_telemetry(OpalDeviceHandle* h, OpalTelemetry* out);

#ifdef __cplusplus
}
#endif
#endif // OPAL_BRIDGE_H
