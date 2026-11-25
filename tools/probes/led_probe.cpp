// Hardware probe: find the Myriad X GPIO that drives the C1's front light.
// Streams the sensor, then pulses one GPIO at a time (high, then low) and
// prints which pin and phase is live. Watch the light and note the number.
//
//   led_probe [first] [last] [seconds high] [seconds low]
//
// Quit OpenOpal first. A pin that resets the camera ends the run; start again
// from the next pin. Nothing is flashed: unplugging restores stock firmware.
#include "../../Sources/OpalBridge/OpalBridge.cpp"

#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    const int first = argc > 1 ? std::atoi(argv[1]) : 0;
    const int last = argc > 2 ? std::atoi(argv[2]) : 84;
    const double high = argc > 3 ? std::atof(argv[3]) : 2.0;
    const double low = argc > 4 ? std::atof(argv[4]) : high;

    dai::Pipeline pipeline;
    auto cam = pipeline.create<dai::node::ColorCamera>();
    cam->setBoardSocket(dai::CameraBoardSocket::CAM_A);
    cam->setResolution(dai::ColorCameraProperties::SensorResolution::THE_4_K);
    cam->setIspScale(1, 2);
    cam->setFps(30);
    auto xout = pipeline.create<dai::node::XLinkOut>();
    xout->setStreamName("video");
    xout->input.setBlocking(false);
    xout->input.setQueueSize(1);
    cam->video.link(xout->input);

    char script[1024];
    std::snprintf(script, sizeof(script), R"(
import GPIO
import time
for pin in range(%d, %d):
    node.warn('pin %%d high' %% pin)
    GPIO.setup(pin, GPIO.OUT, GPIO.PULL_NONE)
    GPIO.write(pin, 1)
    time.sleep(%f)
    node.warn('pin %%d low' %% pin)
    GPIO.write(pin, 0)
    time.sleep(%f)
    GPIO.setup(pin, GPIO.IN, GPIO.PULL_NONE)
node.warn('done')
)", first, last + 1, high, low);
    auto probe = pipeline.create<dai::node::Script>();
    probe->setScript(script);

    dai::DeviceInfo target;
    bool found = false;
    for(const auto& d : dai::XLinkConnection::getAllConnectedDevices()) {
        if(d.state == X_LINK_BOOTED && prepareLegacyDevice(d.getMxId(), target)) {
            found = true;
            break;
        }
        if(d.state == X_LINK_UNBOOTED || d.state == X_LINK_FLASH_BOOTED ||
           d.state == X_LINK_BOOTLOADER) {
            target = d;
            found = true;
            break;
        }
    }
    if(!found) {
        std::printf("no usable camera (%s)\n", g_lastError.c_str());
        return 1;
    }

    dai::Device device(pipeline, target, dai::UsbSpeed::SUPER_PLUS);
    device.setLogLevel(dai::LogLevel::WARN);
    device.setLogOutputLevel(dai::LogLevel::OFF);
    static std::atomic<bool> done{false};
    device.addLogCallback([](dai::LogMessage m) {
        std::printf("%s\n", m.payload.c_str());
        std::fflush(stdout);
        if(m.payload.find("done") != std::string::npos) done = true;
    });
    auto video = device.getOutputQueue("video", 1, false);
    std::printf("streaming; watch the light\n");
    std::fflush(stdout);
    while(!done && !device.isClosed()) {
        try {
            video->tryGet<dai::ImgFrame>();
        } catch(const std::exception& e) {
            std::printf("camera dropped: %s\n", e.what());
            return 2;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    return 0;
}
