#include <libusb-1.0/libusb.h>
#include <atomic>
#include <cerrno>
#include <sys/socket.h>

namespace {
std::atomic<unsigned> networkSockets{0};
std::atomic<unsigned> usbLists{0};
libusb_device* emptyDevices[] = {nullptr};

// Hide physical devices so missing-camera searches exercise the LAN fallback.
ssize_t emptyUsbList(libusb_context*, libusb_device*** devices) {
    ++usbLists;
    *devices = emptyDevices;
    return 0;
}

void freeUsbList(libusb_device** devices, int unref) {
    if(devices != emptyDevices) libusb_free_device_list(devices, unref);
}

// Observe attempts without sending packets during the test.
int observeSocket(int domain, int type, int protocol) {
    if(domain == AF_INET || domain == AF_INET6) {
        ++networkSockets;
        errno = EACCES;
        return -1;
    }
    return socket(domain, type, protocol);
}

struct Interpose {
    const void* replacement;
    const void* original;
};
__attribute__((used, section("__DATA,__interpose,interposing")))
Interpose interposes[] = {
    {reinterpret_cast<const void*>(emptyUsbList), reinterpret_cast<const void*>(libusb_get_device_list)},
    {reinterpret_cast<const void*>(freeUsbList), reinterpret_cast<const void*>(libusb_free_device_list)},
    {reinterpret_cast<const void*>(observeSocket), reinterpret_cast<const void*>(socket)},
};
} // namespace

extern "C" unsigned usbOnlyNetworkAttempts() { return networkSockets.load(); }
extern "C" unsigned usbOnlyUsbLists() { return usbLists.load(); }
extern "C" void usbOnlyResetNetworkAttempts() { networkSockets = 0; }
