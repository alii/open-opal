"""Camera-free behavioral probes of the production reconnect and SDK request gates.

Only isolated C++ functions are compiled; no DepthAI library, USB, or app is used.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SDK = ROOT / "vendor/depthai-core"


def function(source, signature):
    """Extract a whole function, including its template prefix when supplied."""
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


class BootSafetyTests(unittest.TestCase):
    def compile_and_run(self, source, include=None):
        with tempfile.TemporaryDirectory(prefix="open-opal-boot-probe-") as temporary:
            directory = Path(temporary)
            cpp = directory / "probe.cpp"
            executable = directory / "probe"
            cpp.write_text(source)
            command = [os.environ.get("CXX", "clang++"), "-std=c++17", str(cpp), "-o", str(executable)]
            if include:
                command.extend(["-I", str(include)])
            compilation = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(compilation.returncode, 0, compilation.stdout + compilation.stderr)
            execution = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(execution.returncode, 0, execution.stdout + execution.stderr)

    def test_selected_identity_through_reconnects(self):
        bridge = (ROOT / "Sources/OpalBridge/OpalBridge.cpp").read_text()
        reconnect = function(bridge, "static bool findDeviceInState(")
        # Replace only time/wait primitives, not device selection or control flow.
        reconnect = reconnect.replace("std::chrono::steady_clock::now()", "fakeNow()")
        reconnect = reconnect.replace("std::this_thread::sleep_for(std::chrono::milliseconds(40));", "")
        prepare = function(bridge, "static bool prepareLegacyDevice(")
        self.compile_and_run(r'''
#include <cassert>
#include <chrono>
#include <exception>
#include <string>
#include <vector>
enum XLinkDeviceState_t { X_LINK_BOOTED, X_LINK_BOOTLOADER, X_LINK_UNBOOTED };
static int stage = 0, jumps = 0, romRequests = 0, polls = 0;
static bool stock = true;
static std::string error;
static auto fakeNow() {
    static int ticks = 0;
    return std::chrono::steady_clock::time_point(std::chrono::milliseconds(++ticks * 100));
}
namespace dai {
struct DeviceInfo {
    std::string mxid;
    XLinkDeviceState_t state;
    std::string name;
    std::string getMxId() const { return mxid; }
};
}
static std::vector<dai::DeviceInfo> snapshots[3];
namespace dai {
struct XLinkConnection {
    static std::vector<DeviceInfo> getAllConnectedDevices() { ++polls; return snapshots[stage]; }
    static void bootBootloader(const DeviceInfo& info) {
        assert(info.mxid == "selected"); ++jumps; stage = 1;
    }
};
struct DeviceBootloader {
    DeviceBootloader(const DeviceInfo& info, bool flashing) {
        assert(info.mxid == "selected"); assert(!flashing);
    }
    void bootUsbRomBootloader() { ++romRequests; stage = 2; }
};
}
static bool looksLikeStockC1(const std::string& id) { return stock && id == "selected"; }
static void bootLog(const std::string&) {}
static void setError(const std::string& message) { error = message; }
''' + reconnect + "\n" + prepare + r'''
static void reset() {
    stage = jumps = romRequests = polls = 0; stock = true; error.clear();
    snapshots[0] = {{"selected", X_LINK_BOOTED, "old-usb-address"}};
    snapshots[1] = {{"selected", X_LINK_BOOTLOADER, "new-usb-address"}};
    snapshots[2] = {{"selected", X_LINK_UNBOOTED, "rom-usb-address"}};
}
int main() {
    dai::DeviceInfo out{"untouched", X_LINK_BOOTED, "sentinel"};
    reset();
    // A changing USB address is fine when identity is known, including with peers.
    snapshots[2].insert(snapshots[2].begin(), {"unrelated", X_LINK_UNBOOTED, "other-port"});
    assert(prepareLegacyDevice("selected", out));
    assert(out.mxid == "selected" && out.name == "rom-usb-address");
    assert(jumps == 1 && romRequests == 1);

    // Neither one nor several unrelated ROM devices can be handed a pipeline.
    for(int count : {0, 1, 2}) {
        reset(); out.mxid = "untouched"; snapshots[2].clear();
        for(int i = 0; i < count; ++i) snapshots[2].push_back({"unrelated", X_LINK_UNBOOTED, "other-port"});
        assert(!prepareLegacyDevice("selected", out));
        assert(out.mxid == "untouched"); assert(!error.empty());
    }
    for(const std::string id : {std::string("changed-id"), std::string()}) {
        reset(); out.mxid = "untouched"; snapshots[2] = {{id, X_LINK_UNBOOTED, "rom-usb-address"}};
        assert(!prepareLegacyDevice("selected", out)); assert(out.mxid == "untouched");
    }
    reset(); snapshots[1] = {{"unrelated", X_LINK_BOOTLOADER, "other-port"}};
    assert(!prepareLegacyDevice("selected", out)); assert(romRequests == 0);
    reset(); snapshots[0] = {{"unrelated", X_LINK_BOOTED, "other-port"}};
    assert(!prepareLegacyDevice("selected", out)); assert(jumps == 0);
    reset(); stock = false;
    assert(!prepareLegacyDevice("selected", out)); assert(jumps == 0);
    reset(); snapshots[2] = {{"selected", X_LINK_BOOTED, "not-rom"}};
    assert(!prepareLegacyDevice("selected", out));
    reset();
    assert(!findDeviceInState(X_LINK_BOOTED, "", out, 1.0)); assert(polls == 0);
}
''')

    def test_only_ram_handoff_requests_bypass_version_checks(self):
        # Apply the shipped patch to pristine pinned SDK source in a temporary tree.
        # The installed SDK and its binaries remain untouched.
        baseline = subprocess.run(
            ["git", "-C", str(SDK), "show", "v2.30.0:src/device/DeviceBootloader.cpp"],
            check=True, capture_output=True, text=True,
        ).stdout
        with tempfile.TemporaryDirectory(prefix="open-opal-sdk-patch-") as temporary:
            target = Path(temporary) / "src/device/DeviceBootloader.cpp"
            target.parent.mkdir(parents=True)
            target.write_text(baseline)
            subprocess.run(
                ["git", "apply", str(ROOT / "patches/depthai-bootloader-0.0.0.patch")],
                cwd=temporary, check=True, capture_output=True, text=True,
            )
            patched = target.read_text()
        send = function(patched, "template <typename T>\nbool DeviceBootloader::sendRequest(")
        send_throw = function(patched, "template <typename T>\nvoid DeviceBootloader::sendRequestThrow(")
        protocol = SDK / "shared/depthai-bootloader-shared/include"
        declarations = (protocol / "depthai-bootloader-shared/Bootloader.hpp").read_text()
        requests = re.findall(r"struct (\w+) : BaseRequest", declarations)
        self.assertIn("UpdateFlash", requests)
        self.assertIn("UsbRomBoot", requests)
        cases = "\n".join(f"    exercise<Request::{request}>();" for request in requests)
        self.compile_and_run(r'''
#include <cassert>
#include <cstdio>
#include <exception>
#include <stdexcept>
#include <string>
#include <tuple>
#include <type_traits>
#include "depthai-bootloader-shared/Bootloader.hpp"
namespace Request = dai::bootloader::request;
namespace fmt {
template<typename... Args> std::string format(const char*, Args...) { return "version gate"; }
}
struct Stream {
    int writes = 0;
    void write(uint8_t*, size_t) { ++writes; }
};
struct DeviceBootloader {
    struct Version {
        int major = 0, minor = 0, patch = 0;
        Version(int a, int b, int c) : major(a), minor(b), patch(c) {}
        Version(const char* value) { assert(std::sscanf(value, "%d.%d.%d", &major, &minor, &patch) == 3); }
        Version getSemver() const { return *this; }
        std::string toString() const { return "probe"; }
        bool operator<(const Version& other) const {
            return std::tie(major, minor, patch) < std::tie(other.major, other.minor, other.patch);
        }
        bool operator==(const Version& other) const {
            return std::tie(major, minor, patch) == std::tie(other.major, other.minor, other.patch);
        }
    };
    Version version{0, 0, 0};
    Stream* stream;
    Version getVersion() const { return version; }
    template<typename T> bool sendRequest(const T&);
    template<typename T> void sendRequestThrow(const T&);
};
''' + send + "\n" + send_throw + r'''
template<typename T> void exercise() {
    for(int patch : {0, 1, 2, 11, 12, 14, 28, 99}) {
        Stream stream;
        DeviceBootloader loader{{0, 0, patch}, &stream};
        const bool exception = patch == 0 && (std::is_same<T, Request::GetBootloaderVersion>::value
                                              || std::is_same<T, Request::UsbRomBoot>::value);
        const bool expected = exception || !(loader.version < DeviceBootloader::Version(T::VERSION));
        for(bool throwing : {false, true}) {
            stream.writes = 0;
            bool accepted = true;
            try {
                if(throwing) loader.sendRequestThrow(T{});
                else accepted = loader.sendRequest(T{});
            } catch(const std::runtime_error&) { accepted = false; }
            assert(accepted == expected);
            assert(stream.writes == (expected ? 1 : 0));
        }
    }
}
int main() {
''' + cases + "\n}\n", include=protocol)


if __name__ == "__main__":
    unittest.main()
