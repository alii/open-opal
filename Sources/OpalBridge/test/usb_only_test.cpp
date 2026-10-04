#include <depthai/depthai.hpp>
#include <XLink/XLink.h>
#include <cstdio>
#include <cstdlib>

extern "C" unsigned usbOnlyNetworkAttempts();
extern "C" unsigned usbOnlyUsbLists();
extern "C" void usbOnlyResetNetworkAttempts();
// These helpers belong to the pinned XLink library, not its public API.
extern "C" int tcpip_create_search_context(void**, deviceDesc_t);
extern "C" int tcpip_close_search_context(void*);

static bool require(bool condition, const char* message) {
    if(!condition) std::fprintf(stderr, "%s\n", message);
    return condition;
}

int main() {
    // Calibrate the observer before accepting a zero count as proof.
    deviceDesc_t calibration = {};
    calibration.protocol = X_LINK_TCP_IP;
    void* context = nullptr;
    auto result = tcpip_create_search_context(&context, calibration);
    if(result == 0) tcpip_close_search_context(context);
    if(!require(usbOnlyNetworkAttempts() == 1, "Socket observation is inactive")) return EXIT_FAILURE;
    usbOnlyResetNetworkAttempts();

    setenv("DEPTHAI_PROTOCOL", "usb", 1);
    bool okay = true;
    okay &= require(dai::XLinkConnection::getAllConnectedDevices().empty(), "Unexpected USB device in isolated discovery");
    okay &= require(!std::get<0>(dai::XLinkConnection::getFirstDevice()), "Unexpected first device");
    okay &= require(!std::get<0>(dai::XLinkConnection::getDeviceByMxId("missing-camera")), "Unexpected targeted device");

    deviceDesc_t request = {};
    request.protocol = X_LINK_ANY_PROTOCOL;
    request.platform = X_LINK_MYRIAD_X;
    request.state = X_LINK_ANY_STATE;
    deviceDesc_t devices[4] = {};
    unsigned count = 0;
    XLinkFindAllSuitableDevices(request, devices, 4, &count);
    okay &= require(count == 0, "Unexpected device in all-protocol discovery");

    request.protocol = X_LINK_TCP_IP;
    okay &= require(XLinkFindFirstSuitableDevice(request, devices) != X_LINK_SUCCESS, "Network transport remains available");
    okay &= require(XLinkIsProtocolInitialized(X_LINK_USB_VSC), "USB transport was disabled");
    okay &= require(!XLinkIsProtocolInitialized(X_LINK_TCP_IP), "TCP/IP transport remains initialized");
    okay &= require(usbOnlyNetworkAttempts() == 0, "Discovery attempted an Internet socket");
    okay &= require(usbOnlyUsbLists() > 0, "USB isolation is inactive");
    std::printf("USB enabled: %d; TCP/IP enabled: %d; network socket attempts: %u\n",
                XLinkIsProtocolInitialized(X_LINK_USB_VSC),
                XLinkIsProtocolInitialized(X_LINK_TCP_IP), usbOnlyNetworkAttempts());
    return okay ? EXIT_SUCCESS : EXIT_FAILURE;
}
