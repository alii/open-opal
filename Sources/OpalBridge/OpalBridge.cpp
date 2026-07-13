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
    std::atomic<bool>  running{false};

    OpalFrameCallback  cb = nullptr;
    void*              ctx = nullptr;

    int width = 0, height = 0;
    std::string sensorName;
    int usbSpeed = 0;

    // telemetry
    std::mutex          telMutex;
    std::deque<double>  latencies;
    std::deque<double>  frameTimes;
    OpalTelemetry       tel{};
};

// ---------------------------------------------------------------------------

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

        // Find the requested device.
        std::unique_ptr<dai::Device> dev;
        bool found = false;
        if(mxid && mxid[0]) {
            for(const auto& info : dai::Device::getAllAvailableDevices()) {
                if(info.getMxId() == std::string(mxid)) {
                    dev = std::make_unique<dai::Device>(pipeline, info, dai::UsbSpeed::SUPER_PLUS);
                    found = true;
                    break;
                }
            }
            if(!found) { setError("device not found: " + std::string(mxid)); return nullptr; }
        } else {
            dev = std::make_unique<dai::Device>(pipeline, dai::UsbSpeed::SUPER_PLUS);
        }

        auto* h = new OpalDeviceHandle();
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

        h->running = true;
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
    h->cb = nullptr;
    h->controlQ.reset();
    h->videoQ.reset();
    h->device.reset();   // device reboots -> returns to stock UVC in ~5s
    delete h;
}

void opal_set_controls(OpalDeviceHandle* h, OpalControls c) {
    if(!h || !h->controlQ) return;
    try {
        dai::CameraControl ctrl;

        if(c.autoExposure) {
            ctrl.setAutoExposureEnable();
            ctrl.setAutoExposureCompensation(std::clamp(c.evCompensation, -9, 9));
            ctrl.setAutoExposureLock(c.aeLock);
        } else {
            ctrl.setManualExposure(std::clamp(c.exposureUs, 1, 33000),
                                   std::clamp(c.iso, 100, 1600));
        }

        if(c.manualFocus) {
            ctrl.setManualFocus(std::clamp(c.lensPosition, 0, 255));
        } else {
            ctrl.setAutoFocusMode(mapAf(c.afMode));
        }

        if(c.manualWhiteBalance) {
            ctrl.setManualWhiteBalance(std::clamp(c.whiteBalanceK, 1000, 12000));
        } else {
            ctrl.setAutoWhiteBalanceMode(mapAwb(c.awbMode));
            ctrl.setAutoWhiteBalanceLock(c.awbLock);
        }

        ctrl.setAntiBandingMode(mapAntiBanding(c.antiBanding));
        ctrl.setSharpness(std::clamp(c.sharpness, 0, 4));
        ctrl.setLumaDenoise(std::clamp(c.lumaDenoise, 0, 4));
        ctrl.setChromaDenoise(std::clamp(c.chromaDenoise, 0, 4));
        ctrl.setBrightness(std::clamp(c.brightness, -10, 10));
        ctrl.setContrast(std::clamp(c.contrast, -10, 10));
        ctrl.setSaturation(std::clamp(c.saturation, -10, 10));

        h->controlQ->send(ctrl);
    } catch(const std::exception& e) {
        setError(e.what());
    }
}

void opal_trigger_autofocus(OpalDeviceHandle* h) {
    if(!h || !h->controlQ) return;
    try {
        dai::CameraControl ctrl;
        ctrl.setAutoFocusTrigger();
        h->controlQ->send(ctrl);
    } catch(const std::exception& e) { setError(e.what()); }
}

void opal_set_focus_region(OpalDeviceHandle* h, float x, float y, float w, float hh) {
    if(!h || !h->controlQ || h->width == 0) return;
    try {
        int W = h->width, H = h->height;
        int rx = std::clamp(static_cast<int>(x * W), 0, W - 1);
        int ry = std::clamp(static_cast<int>(y * H), 0, H - 1);
        int rw = std::clamp(static_cast<int>(w * W), 1, W - rx);
        int rh = std::clamp(static_cast<int>(hh * H), 1, H - ry);

        dai::CameraControl ctrl;
        ctrl.setAutoFocusRegion(rx, ry, rw, rh);
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
