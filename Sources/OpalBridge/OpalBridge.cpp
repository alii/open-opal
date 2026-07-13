#include "OpalBridge.h"

#include <depthai/depthai.hpp>

#include <algorithm>
#include <atomic>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

namespace {

std::mutex g_errMutex;
std::string g_lastError;

/// depthai also hunts for PoE devices over the local network, which makes macOS
/// pop a "wants to find devices on your local network" prompt the first time the
/// app runs. The C1 is USB-only, so restrict discovery and skip the prompt.
struct UsbOnlyInit {
    UsbOnlyInit() { setenv("DEPTHAI_PROTOCOL", "usb", /*overwrite=*/0); }
};
const UsbOnlyInit g_usbOnly;

// --- boot log ---------------------------------------------------------------

std::mutex g_logMutex;
OpalLogCallback g_logCb = nullptr;
void* g_logCtx = nullptr;
std::chrono::steady_clock::time_point g_logT0;

void bootLog(const std::string& s) {
    std::lock_guard<std::mutex> lk(g_logMutex);
    if(!g_logCb) return;
    double t = std::chrono::duration<double>(
                   std::chrono::steady_clock::now() - g_logT0).count();
    char buf[512];
    std::snprintf(buf, sizeof(buf), "[%5.2fs] %s", t, s.c_str());
    g_logCb(buf, g_logCtx);
}

const char* stateName(XLinkDeviceState_t s) {
    switch(s) {
        case X_LINK_FLASH_BOOTED: return "flash-booted (stock Opal UVC firmware)";
        case X_LINK_BOOTLOADER:   return "bootloader";
        case X_LINK_UNBOOTED:     return "ROM bootloader, awaiting firmware";
        case X_LINK_BOOTED:       return "booted (depthai firmware, RAM)";
        default:                  return "unknown";
    }
}

void setError(const std::string& e) {
    std::lock_guard<std::mutex> lk(g_errMutex);
    g_lastError = e;
}

int mapState(XLinkDeviceState_t s) {
    switch(s) {
        case X_LINK_BOOTLOADER:   return OPAL_STATE_BOOTLOADER;
        case X_LINK_BOOTED:       return OPAL_STATE_BOOTED;
        case X_LINK_FLASH_BOOTED: return OPAL_STATE_FLASH_BOOTED;
        case X_LINK_UNBOOTED:     return OPAL_STATE_UNBOOTED;
        default:                  return OPAL_STATE_UNKNOWN;
    }
}

dai::CameraControl::AntiBandingMode mapAntiBanding(OpalAntiBanding a) {
    using M = dai::CameraControl::AntiBandingMode;
    switch(a) {
        case OPAL_AB_50HZ: return M::MAINS_50_HZ;
        case OPAL_AB_60HZ: return M::MAINS_60_HZ;
        case OPAL_AB_AUTO: return M::AUTO;
        default:           return M::OFF;
    }
}

dai::CameraControl::AutoWhiteBalanceMode mapAwb(OpalAwbMode m) {
    using M = dai::CameraControl::AutoWhiteBalanceMode;
    switch(m) {
        case OPAL_AWB_AUTO:             return M::AUTO;
        case OPAL_AWB_INCANDESCENT:     return M::INCANDESCENT;
        case OPAL_AWB_FLUORESCENT:      return M::FLUORESCENT;
        case OPAL_AWB_WARM_FLUORESCENT: return M::WARM_FLUORESCENT;
        case OPAL_AWB_DAYLIGHT:         return M::DAYLIGHT;
        case OPAL_AWB_CLOUDY:           return M::CLOUDY_DAYLIGHT;
        case OPAL_AWB_TWILIGHT:         return M::TWILIGHT;
        case OPAL_AWB_SHADE:            return M::SHADE;
        default:                        return M::OFF;
    }
}

dai::CameraControl::AutoFocusMode mapAf(OpalAfMode m) {
    using M = dai::CameraControl::AutoFocusMode;
    switch(m) {
        case OPAL_AF_AUTO:               return M::AUTO;
        case OPAL_AF_MACRO:              return M::MACRO;
        case OPAL_AF_CONTINUOUS_VIDEO:   return M::CONTINUOUS_VIDEO;
        case OPAL_AF_CONTINUOUS_PICTURE: return M::CONTINUOUS_PICTURE;
        case OPAL_AF_EDOF:               return M::EDOF;
        default:                         return M::OFF;
    }
}

} // namespace

// ---------------------------------------------------------------------------

struct OpalDeviceHandle {
    std::unique_ptr<dai::Device>       device;
    std::shared_ptr<dai::DataInputQueue> controlQ;
    std::shared_ptr<dai::DataOutputQueue> videoQ;

    std::thread        capture;
    std::thread        control;
    std::atomic<bool>  running{false};
    std::atomic<bool>  firstFrameLogged{false};

    // Control coalescing.
    //
    // XLink sends BLOCK. Dragging a slider fires control changes far faster than
    // the device can consume them, so sending straight from the UI thread stalls
    // the UI and floods the device's control queue — which is what made white
    // balance feel like treacle.
    //
    // Instead, setters just record the desired state and return. This thread
    // pushes it to the device at a sane rate, and only ever sends the fields that
    // actually CHANGED. That second part matters as much as the throttle:
    // re-sending setAutoFocusMode restarts the autofocus search, so blindly
    // resending the whole control block on every tick made the lens hunt forever.
    std::mutex    ctrlMutex;
    OpalControls  desired{};
    OpalControls  lastSent{};
    bool          desiredValid = false;
    bool          lastSentValid = false;

    OpalFrameCallback  cb = nullptr;
    void*              ctx = nullptr;

    int width = 0, height = 0;          // ISP output size (what the host sees)
    int sensorWidth = 0, sensorHeight = 0;  // sensor size (what 3A regions use)
    std::string sensorName;
    int usbSpeed = 0;

    // telemetry
    std::mutex          telMutex;
    std::deque<double>  latencies;
    std::deque<double>  frameTimes;
    OpalTelemetry       tel{};
};

// Defined below; used by the control thread in opal_open.
static bool buildDelta(const OpalControls& c, const OpalControls& prev, bool havePrev,
                       dai::CameraControl& ctrl);

// ---------------------------------------------------------------------------

void opal_set_boot_logger(OpalLogCallback cb, void* ctx) {
    std::lock_guard<std::mutex> lk(g_logMutex);
    g_logCb = cb;
    g_logCtx = ctx;
}

int opal_list_devices(OpalDeviceInfo* out, int maxCount) {
    try {
        auto devices = dai::XLinkConnection::getAllConnectedDevices();
        int n = 0;
        for(const auto& d : devices) {
            if(n >= maxCount) break;
            OpalDeviceInfo info{};
            std::snprintf(info.mxid, OPAL_MXID_LEN, "%s", d.getMxId().c_str());
            std::snprintf(info.name, OPAL_NAME_LEN, "%s", d.name.c_str());
            info.state  = mapState(d.state);
            // FLASH_BOOTED (stock UVC firmware) and UNBOOTED are both openable;
            // we reboot the device with our pipeline either way.
            info.usable = (d.state == X_LINK_FLASH_BOOTED ||
                           d.state == X_LINK_UNBOOTED ||
                           d.state == X_LINK_BOOTLOADER);
            out[n++] = info;
        }
        return n;
    } catch(const std::exception& e) {
        setError(e.what());
        return 0;
    }
}

OpalDeviceHandle* opal_open(const char* mxid, OpalPipelineConfig cfg,
                            OpalFrameCallback cb, void* ctx) {
    try {
        dai::Pipeline pipeline;

        auto cam = pipeline.create<dai::node::ColorCamera>();
        cam->setBoardSocket(dai::CameraBoardSocket::CAM_A);
        // Always 4K sensor mode — it's the IMX582's smallest. Scale on the ISP.
        cam->setResolution(dai::ColorCameraProperties::SensorResolution::THE_4_K);
        cam->setInterleaved(false);
        cam->setFps(static_cast<float>(std::clamp(cfg.fps, 1, 42)));
        if(!cfg.keep4K && cfg.ispNum > 0 && cfg.ispDen > 0) {
            cam->setIspScale(cfg.ispNum, cfg.ispDen);
        }

        // The C1's sensor sits upside down in the housing. Rotate on the ISP so
        // every downstream consumer — preview, bokeh, virtual camera — gets an
        // upright frame without anyone having to think about it.
        switch(cfg.orientation) {
            case OPAL_ORIENT_ROTATE_180:
                cam->setImageOrientation(dai::CameraImageOrientation::ROTATE_180_DEG); break;
            case OPAL_ORIENT_MIRROR:
                cam->setImageOrientation(dai::CameraImageOrientation::HORIZONTAL_MIRROR); break;
            case OPAL_ORIENT_VFLIP:
                cam->setImageOrientation(dai::CameraImageOrientation::VERTICAL_FLIP); break;
            default:
                cam->setImageOrientation(dai::CameraImageOrientation::NORMAL); break;
        }

        auto xout = pipeline.create<dai::node::XLinkOut>();
        xout->setStreamName("video");
        // Depth 1 + non-blocking: always hand the host the FRESHEST frame and
        // drop stale ones. A blocking depth-4 queue silently adds up to ~130ms.
        xout->input.setBlocking(false);
        xout->input.setQueueSize(1);
        cam->video.link(xout->input);

        auto xin = pipeline.create<dai::node::XLinkIn>();
        xin->setStreamName("control");
        xin->out.link(cam->inputControl);

        { std::lock_guard<std::mutex> lk(g_logMutex); g_logT0 = std::chrono::steady_clock::now(); }

        // What we're about to send, with honest numbers.
        try {
            auto fw = dai::Device::getEmbeddedDeviceBinary(false);
            char line[160];
            std::snprintf(line, sizeof(line),
                          "firmware image: %.1f MB (embedded in app, uploaded to VPU RAM — flash is never touched)",
                          fw.size() / 1048576.0);
            bootLog(line);
        } catch(...) {}

        try {
            dai::PipelineSchema schema;
            dai::Assets assets;
            std::vector<uint8_t> assetStorage;
            pipeline.serialize(schema, assets, assetStorage);
            std::string nodes;
            for(const auto& n : schema.nodes) {
                if(!nodes.empty()) nodes += " · ";
                std::string name = n.second.name;
                auto pos = name.rfind("::");
                if(pos != std::string::npos) name = name.substr(pos + 2);
                nodes += name;
            }
            bootLog("pipeline graph: " + nodes);
        } catch(...) {}

        // Watch the USB bus while the Device constructor runs. The Myriad
        // re-enumerates twice during boot (stock firmware -> ROM bootloader ->
        // depthai firmware), and polling the bus is the only way to see those
        // transitions — the constructor is a black box from out here.
        std::atomic<bool> watching{true};
        std::thread watcher([&watching]() {
            std::string last;
            while(watching) {
                try {
                    auto devs = dai::XLinkConnection::getAllConnectedDevices();
                    std::string now = devs.empty()
                        ? "device off the bus (re-enumerating)"
                        : std::string("device state: ") + stateName(devs.front().state);
                    if(now != last) { last = now; bootLog(now); }
                } catch(...) {}
                std::this_thread::sleep_for(std::chrono::milliseconds(80));
            }
        });

        // Find the requested device.
        std::unique_ptr<dai::Device> dev;
        bool found = false;
        try {
            if(mxid && mxid[0]) {
                for(const auto& info : dai::Device::getAllAvailableDevices()) {
                    if(info.getMxId() == std::string(mxid)) {
                        bootLog(std::string("target: mxid ") + mxid + " · resetting VPU, uploading firmware over XLink");
                        dev = std::make_unique<dai::Device>(pipeline, info, dai::UsbSpeed::SUPER_PLUS);
                        found = true;
                        break;
                    }
                }
                if(!found) {
                    watching = false; watcher.join();
                    setError("device not found: " + std::string(mxid));
                    return nullptr;
                }
            } else {
                dev = std::make_unique<dai::Device>(pipeline, dai::UsbSpeed::SUPER_PLUS);
            }
        } catch(...) {
            watching = false;
            watcher.join();
            throw;
        }
        watching = false;
        watcher.join();

        auto* h = new OpalDeviceHandle();
        // 3A metering regions are specified against the SENSOR resolution, before
        // any ISP downscale (depthai's CameraControl header is explicit about
        // this). We always configure the sensor at 4K, so that's the frame the
        // regions live in — NOT the 1080p we hand to the host.
        h->sensorWidth  = cam->getResolutionWidth();
        h->sensorHeight = cam->getResolutionHeight();
        h->device   = std::move(dev);
        h->videoQ   = h->device->getOutputQueue("video", 1, /*blocking=*/false);
        h->controlQ = h->device->getInputQueue("control");
        h->cb = cb;
        h->ctx = ctx;
        h->usbSpeed = static_cast<int>(h->device->getUsbSpeed());

        for(const auto& kv : h->device->getCameraSensorNames()) {
            h->sensorName = kv.second;
            break;
        }

        {
            const char* speed = h->usbSpeed >= 4 ? "SuperSpeed+ (10 Gbps)"
                              : h->usbSpeed == 3 ? "SuperSpeed (5 Gbps)"
                              : "High Speed (480 Mbps)";
            bootLog(std::string("XLink handshake ok · ") + speed);
            bootLog("sensor: " + h->sensorName + " · streams open: video (NV12), control");
        }

        h->running = true;

        // Coalescing control thread: drains at most ~30Hz, sends only deltas.
        h->control = std::thread([h]() {
            while(h->running) {
                OpalControls want{}, prev{};
                bool haveWant = false, havePrev = false;
                {
                    std::lock_guard<std::mutex> lk(h->ctrlMutex);
                    haveWant = h->desiredValid;
                    want = h->desired;
                    prev = h->lastSent;
                    havePrev = h->lastSentValid;
                }

                if(haveWant) {
                    dai::CameraControl ctrl;
                    if(buildDelta(want, prev, havePrev, ctrl)) {
                        try {
                            h->controlQ->send(ctrl);
                        } catch(const std::exception& e) {
                            setError(e.what());
                            break;
                        }
                    }
                    std::lock_guard<std::mutex> lk(h->ctrlMutex);
                    h->lastSent = want;
                    h->lastSentValid = true;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(33));
            }
        });

        h->capture = std::thread([h]() {
            while(h->running) {
                std::shared_ptr<dai::ImgFrame> f;
                try {
                    f = h->videoQ->tryGet<dai::ImgFrame>();
                } catch(const std::exception&) {
                    break; // device disconnected
                }
                if(!f) {
                    std::this_thread::sleep_for(std::chrono::microseconds(500));
                    continue;
                }

                const int w = f->getWidth();
                const int h_ = f->getHeight();
                h->width = w; h->height = h_;

                auto now = std::chrono::steady_clock::now();
                double latencyMs =
                    std::chrono::duration<double, std::milli>(now - f->getTimestamp()).count();

                if(!h->firstFrameLogged.exchange(true)) {
                    char line[128];
                    std::snprintf(line, sizeof(line),
                                  "first frame: %dx%d NV12 · %.0f ms sensor→host", w, h_, latencyMs);
                    bootLog(line);
                }

                {
                    std::lock_guard<std::mutex> lk(h->telMutex);
                    h->latencies.push_back(latencyMs);
                    if(h->latencies.size() > 60) h->latencies.pop_front();
                    double t = std::chrono::duration<double>(now.time_since_epoch()).count();
                    h->frameTimes.push_back(t);
                    if(h->frameTimes.size() > 60) h->frameTimes.pop_front();

                    h->tel.reportedExposureUs =
                        static_cast<int32_t>(f->getExposureTime().count());
                    h->tel.reportedIso          = f->getSensitivity();
                    h->tel.reportedLensPosition = f->getLensPosition();
                    h->tel.reportedColorTempK   = f->getColorTemperature();

                    std::vector<double> s(h->latencies.begin(), h->latencies.end());
                    std::sort(s.begin(), s.end());
                    h->tel.latencyMsP50 = s.empty() ? 0 : s[s.size()/2];
                    if(h->frameTimes.size() >= 2) {
                        double span = h->frameTimes.back() - h->frameTimes.front();
                        h->tel.fps = span > 0 ? (h->frameTimes.size()-1) / span : 0;
                    }
                }

                if(h->cb) {
                    // ColorCamera.video is NV12: a full-res Y plane immediately
                    // followed by an interleaved half-res CbCr plane. This maps
                    // 1:1 onto a biplanar CVPixelBuffer, so the host never has
                    // to do a color conversion on the CPU.
                    auto& data = f->getData();
                    const uint8_t* base = data.data();
                    const size_t yStride  = static_cast<size_t>(w);
                    const size_t uvStride = static_cast<size_t>(w);
                    const uint8_t* y  = base;
                    const uint8_t* uv = base + (yStride * static_cast<size_t>(h_));

                    if(data.size() >= yStride * h_ + uvStride * (h_ / 2)) {
                        int64_t hostNs = std::chrono::duration_cast<std::chrono::nanoseconds>(
                                             now.time_since_epoch()).count();
                        h->cb(y, yStride, uv, uvStride, w, h_, hostNs, latencyMs, h->ctx);
                    }
                }
            }
        });

        return h;
    } catch(const std::exception& e) {
        setError(e.what());
        return nullptr;
    }
}

void opal_close(OpalDeviceHandle* h) {
    if(!h) return;
    h->running = false;
    if(h->capture.joinable()) h->capture.join();
    if(h->control.joinable()) h->control.join();
    h->cb = nullptr;
    h->controlQ.reset();
    h->videoQ.reset();
    h->device.reset();   // device reboots -> returns to stock UVC in ~5s
    delete h;
}

// Non-blocking: record what the user wants and get out. The control thread does
// the talking.
void opal_set_controls(OpalDeviceHandle* h, OpalControls c) {
    if(!h) return;
    std::lock_guard<std::mutex> lk(h->ctrlMutex);
    h->desired = c;
    h->desiredValid = true;
}

// Builds a CameraControl containing ONLY what changed since the last send.
// Returns false if nothing did, so we skip the send entirely.
static bool buildDelta(const OpalControls& c, const OpalControls& prev, bool havePrev,
                       dai::CameraControl& ctrl) {
    bool any = false;
    const bool all = !havePrev;   // first send: transmit everything

    // --- exposure ---
    if(all || c.autoExposure != prev.autoExposure ||
       (c.autoExposure && (c.evCompensation != prev.evCompensation ||
                           c.aeLock != prev.aeLock)) ||
       (!c.autoExposure && (c.exposureUs != prev.exposureUs || c.iso != prev.iso))) {
        if(c.autoExposure) {
            if(all || !prev.autoExposure) ctrl.setAutoExposureEnable();
            ctrl.setAutoExposureCompensation(std::clamp(c.evCompensation, -9, 9));
            ctrl.setAutoExposureLock(c.aeLock);
        } else {
            ctrl.setManualExposure(std::clamp(c.exposureUs, 1, 33000),
                                   std::clamp(c.iso, 100, 1600));
        }
        any = true;
    }

    // --- focus ---
    // Guarded tightly: re-issuing setAutoFocusMode makes the lens restart its
    // search, so it must be sent ONLY when the mode genuinely changes.
    if(all || c.manualFocus != prev.manualFocus ||
       (c.manualFocus && c.lensPosition != prev.lensPosition) ||
       (!c.manualFocus && c.afMode != prev.afMode)) {
        if(c.manualFocus) {
            ctrl.setManualFocus(std::clamp(c.lensPosition, 0, 255));
        } else {
            ctrl.setAutoFocusMode(mapAf(c.afMode));
        }
        any = true;
    }

    // --- white balance ---
    if(all || c.manualWhiteBalance != prev.manualWhiteBalance ||
       (c.manualWhiteBalance && c.whiteBalanceK != prev.whiteBalanceK) ||
       (!c.manualWhiteBalance && (c.awbMode != prev.awbMode || c.awbLock != prev.awbLock))) {
        if(c.manualWhiteBalance) {
            ctrl.setManualWhiteBalance(std::clamp(c.whiteBalanceK, 1000, 12000));
        } else {
            ctrl.setAutoWhiteBalanceMode(mapAwb(c.awbMode));
            ctrl.setAutoWhiteBalanceLock(c.awbLock);
        }
        any = true;
    }

    // --- the rest ---
    if(all || c.antiBanding != prev.antiBanding) {
        ctrl.setAntiBandingMode(mapAntiBanding(c.antiBanding)); any = true;
    }
    if(all || c.sharpness != prev.sharpness) {
        ctrl.setSharpness(std::clamp(c.sharpness, 0, 4)); any = true;
    }
    if(all || c.lumaDenoise != prev.lumaDenoise) {
        ctrl.setLumaDenoise(std::clamp(c.lumaDenoise, 0, 4)); any = true;
    }
    if(all || c.chromaDenoise != prev.chromaDenoise) {
        ctrl.setChromaDenoise(std::clamp(c.chromaDenoise, 0, 4)); any = true;
    }
    if(all || c.brightness != prev.brightness) {
        ctrl.setBrightness(std::clamp(c.brightness, -10, 10)); any = true;
    }
    if(all || c.contrast != prev.contrast) {
        ctrl.setContrast(std::clamp(c.contrast, -10, 10)); any = true;
    }
    if(all || c.saturation != prev.saturation) {
        ctrl.setSaturation(std::clamp(c.saturation, -10, 10)); any = true;
    }

    return any;
}

void opal_trigger_autofocus(OpalDeviceHandle* h) {
    if(!h || !h->controlQ) return;
    try {
        dai::CameraControl ctrl;
        ctrl.setAutoFocusTrigger();
        h->controlQ->send(ctrl);
    } catch(const std::exception& e) { setError(e.what()); }
}

// Maps a normalized [0,1] rect onto SENSOR pixels. Getting this wrong is not
// subtle: computing it against the 1080p output instead of the 4K sensor pins
// every region into the top-left quadrant, so half the frame can never be
// focused or metered at all.
static bool sensorRect(OpalDeviceHandle* h, float x, float y, float w, float hh,
                       int& rx, int& ry, int& rw, int& rh) {
    if(h->sensorWidth == 0 || h->sensorHeight == 0) return false;
    const int W = h->sensorWidth, H = h->sensorHeight;
    rx = std::clamp(static_cast<int>(x * W), 0, W - 1);
    ry = std::clamp(static_cast<int>(y * H), 0, H - 1);
    rw = std::clamp(static_cast<int>(w * W), 1, W - rx);
    rh = std::clamp(static_cast<int>(hh * H), 1, H - ry);
    return true;
}

void opal_set_focus_region(OpalDeviceHandle* h, float x, float y, float w, float hh) {
    if(!h || !h->controlQ) return;
    try {
        int rx, ry, rw, rh;
        if(!sensorRect(h, x, y, w, hh, rx, ry, rw, rh)) return;

        dai::CameraControl ctrl;
        // One-shot AF. In CONTINUOUS mode the lens keeps re-deciding for itself,
        // so even a successful click-to-focus would drift straight back off you.
        // AUTO + trigger means: scan once, on this region, then hold.
        ctrl.setAutoFocusMode(dai::CameraControl::AutoFocusMode::AUTO);
        ctrl.setAutoFocusRegion(rx, ry, rw, rh);
        ctrl.setAutoExposureRegion(rx, ry, rw, rh);
        // Setting the region alone only tells the lens where to look NEXT time it
        // decides to hunt. Without an explicit trigger, a click often produced no
        // visible refocus at all. Ask for the scan.
        ctrl.setAutoFocusTrigger();
        h->controlQ->send(ctrl);

        // Keep the coalescing thread in step, or its next delta would "helpfully"
        // re-send CONTINUOUS and undo the lock we just took.
        {
            std::lock_guard<std::mutex> lk(h->ctrlMutex);
            h->desired.manualFocus = false;
            h->desired.afMode      = OPAL_AF_AUTO;
            h->lastSent.manualFocus = false;
            h->lastSent.afMode      = OPAL_AF_AUTO;
        }
    } catch(const std::exception& e) { setError(e.what()); }
}

void opal_set_exposure_region(OpalDeviceHandle* h, float x, float y, float w, float hh) {
    if(!h || !h->controlQ) return;
    try {
        int rx, ry, rw, rh;
        if(!sensorRect(h, x, y, w, hh, rx, ry, rw, rh)) return;

        dai::CameraControl ctrl;
        ctrl.setAutoExposureRegion(rx, ry, rw, rh);
        h->controlQ->send(ctrl);
    } catch(const std::exception& e) { setError(e.what()); }
}

bool opal_get_info(OpalDeviceHandle* h, char* sensorName, size_t n,
                   int* usbSpeed, int* width, int* height) {
    if(!h) return false;
    if(sensorName && n) std::snprintf(sensorName, n, "%s", h->sensorName.c_str());
    if(usbSpeed) *usbSpeed = h->usbSpeed;
    if(width)    *width    = h->width;
    if(height)   *height   = h->height;
    return true;
}

bool opal_get_telemetry(OpalDeviceHandle* h, OpalTelemetry* out) {
    if(!h || !out) return false;
    std::lock_guard<std::mutex> lk(h->telMutex);
    *out = h->tel;
    return true;
}

const char* opal_last_error(void) {
    std::lock_guard<std::mutex> lk(g_errMutex);
    return g_lastError.c_str();
}
