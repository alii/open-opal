#include <depthai/xlink/XLinkConnection.hpp>
#include <XLink/XLink.h>
#include <cerrno>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>

extern "C" unsigned usbOnlyNetworkAttempts();
extern "C" unsigned usbOnlyUsbLists();
extern "C" void usbOnlyResetNetworkAttempts();

static bool require(bool condition, const char* message) {
    if(!condition) std::fprintf(stderr, "%s\n", message);
    return condition;
}

int main() {
    // Calibrate the observer before accepting a zero count as proof.
    const int descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    const int error = errno;
    if(descriptor >= 0) close(descriptor);
    if(!require(descriptor == -1 && error == EACCES && usbOnlyNetworkAttempts() == 1,
                "Socket observation is inactive")) return EXIT_FAILURE;
    usbOnlyResetNetworkAttempts();

    setenv("DEPTHAI_PROTOCOL", "usb", 1);
    bool okay = true;
    okay &= require(dai::XLinkConnection::getAllConnectedDevices().empty(), "Unexpected USB device in isolated discovery");
    okay &= require(!std::get<0>(dai::XLinkConnection::getFirstDevice()), "Unexpected first device");
    okay &= require(!std::get<0>(dai::XLinkConnection::getDeviceByMxId("missing-camera")), "Unexpected targeted device");

    deviceDesc_t request = {};
    request.protocol = X_LINK_TCP_IP;
    request.platform = X_LINK_MYRIAD_X;
    request.state = X_LINK_ANY_STATE;
    deviceDesc_t device = {};
    XLinkFindFirstSuitableDevice(request, &device);
    okay &= require(usbOnlyNetworkAttempts() == 0, "Discovery attempted an Internet socket");
    okay &= require(usbOnlyUsbLists() > 0, "USB isolation is inactive");
    std::printf("USB enabled: %d; TCP/IP enabled: %d; network socket attempts: %u\n",
                XLinkIsProtocolInitialized(X_LINK_USB_VSC),
                XLinkIsProtocolInitialized(X_LINK_TCP_IP), usbOnlyNetworkAttempts());
    return okay ? EXIT_SUCCESS : EXIT_FAILURE;
}
