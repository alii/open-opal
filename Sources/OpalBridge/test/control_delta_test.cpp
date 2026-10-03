// Offline only: exercise the production command builder with real DepthAI
// CameraControl serialization. Never enumerate, construct, or open a Device.
#include "../OpalBridge.cpp"

#include <cstdlib>
#include <iostream>

using Command = dai::RawCameraControl::Command;

static void require(bool condition, const char* message) {
    if(!condition) {
        std::cerr << message << '\n';
        std::exit(1);
    }
}

static dai::RawCameraControl wire(const dai::CameraControl& ctrl) {
    std::vector<uint8_t> metadata;
    dai::DatatypeEnum type;
    ctrl.getRaw()->serialize(metadata, type);
    require(type == dai::DatatypeEnum::CameraControl, "wrong serialized datatype");
    dai::RawCameraControl result;
    dai::utility::deserialize(metadata, result);
    return result;
}

static uint64_t bit(Command command) {
    return uint64_t{1} << static_cast<uint8_t>(command);
}

static void expectRange(const dai::RawCameraControl& command, int lo, int hi) {
    require((command.cmdMask & bit(Command::AF_LENS_RANGE)) != 0,
            "missing serialized autofocus range");
    require(command.lensPosAutoInfinity == lo && command.lensPosAutoMacro == hi,
            "wrong serialized autofocus range");
}

static void expectModeAndRange(const OpalControls& current, const OpalControls& previous,
                               bool havePrevious, int lo, int hi) {
    dai::CameraControl ctrl;
    require(buildDelta(current, previous, havePrevious, ctrl), "missing focus transition");
    const auto command = wire(ctrl);
    require((command.cmdMask & bit(Command::AF_MODE)) != 0, "missing serialized autofocus mode");
    require(command.autoFocusMode == mapAf(current.afMode), "wrong serialized autofocus mode");
    require((command.cmdMask & bit(Command::MOVE_LENS)) == 0, "autofocus sent manual lens command");
    expectRange(command, lo, hi);
    if(havePrevious) {
        require(command.cmdMask == (bit(Command::AF_MODE) | bit(Command::AF_LENS_RANGE)),
                "focus-only transition serialized unrelated commands");
    }
}

int main() {
    const OpalAfMode modes[] = {OPAL_AF_OFF, OPAL_AF_AUTO, OPAL_AF_MACRO,
                               OPAL_AF_CONTINUOUS_VIDEO, OPAL_AF_CONTINUOUS_PICTURE,
                               OPAL_AF_EDOF};
    for(bool limited : {false, true}) {
        OpalControls automatic{};
        automatic.autoExposure = true;
        automatic.awbMode = OPAL_AWB_AUTO;
        automatic.limitAfRange = limited;
        automatic.afRangeInfinity = 90;
        automatic.afRangeMacro = 160;
        const int lo = limited ? 90 : 0;
        const int hi = limited ? 160 : 255;

        for(auto mode : modes) {
            automatic.afMode = mode;
            expectModeAndRange(automatic, automatic, false, lo, hi);

            // Same saved mode and bounds: only manualFocus changed. This used
            // to emit AF_MODE without restoring the range it resets.
            auto manual = automatic;
            manual.manualFocus = true;
            manual.lensPosition = 120;
            expectModeAndRange(automatic, manual, true, lo, hi);

            for(auto previousMode : modes) {
                if(previousMode == mode) continue;
                auto previous = automatic;
                previous.afMode = previousMode;
                expectModeAndRange(automatic, previous, true, lo, hi);
            }

            dai::CameraControl unchanged;
            require(!buildDelta(automatic, automatic, true, unchanged),
                    "unchanged controls were resent");
            require(wire(unchanged).cmdMask == 0, "unchanged controls serialized commands");

            auto exposure = automatic;
            exposure.evCompensation = 2;
            dai::CameraControl exposureCtrl;
            require(buildDelta(exposure, automatic, true, exposureCtrl), "missing exposure change");
            require(wire(exposureCtrl).cmdMask ==
                        (bit(Command::EXPOSURE_COMPENSATION) | bit(Command::AE_LOCK)),
                    "unrelated exposure update restarted focus");

            // The same production helper is used after one-shot mode commands
            // for click-to-focus and subject tracking, before region/trigger.
            dai::CameraControl region;
            setAfMode(automatic, dai::CameraControl::AutoFocusMode::AUTO, region);
            region.setAutoFocusRegion(100, 200, 300, 400);
            region.setAutoFocusTrigger();
            const auto regionCommand = wire(region);
            require(regionCommand.cmdMask == (bit(Command::AF_MODE) | bit(Command::AF_LENS_RANGE) |
                                               bit(Command::AF_REGION) | bit(Command::AF_TRIGGER)),
                    "one-shot focus commands were not serialized together");
            require(regionCommand.autoFocusMode == dai::CameraControl::AutoFocusMode::AUTO,
                    "one-shot region is not AUTO");
            expectRange(regionCommand, lo, hi);

            auto manualPosition = manual;
            manualPosition.lensPosition = 140;
            dai::CameraControl manualCtrl;
            require(buildDelta(manualPosition, manual, true, manualCtrl), "missing manual lens update");
            const auto manualCommand = wire(manualCtrl);
            require(manualCommand.cmdMask == bit(Command::MOVE_LENS) && manualCommand.lensPosition == 140,
                    "manual lens update serialized autofocus commands");

            // Bounds can be edited while manual without driving autofocus;
            // returning to auto must apply the new bounds, not the old ones.
            auto editedManual = manual;
            editedManual.afRangeInfinity = 100;
            editedManual.afRangeMacro = 150;
            dai::CameraControl deferred;
            require(!buildDelta(editedManual, manual, true, deferred), "manual range edit sent a command");
            auto restored = editedManual;
            restored.manualFocus = false;
            expectModeAndRange(restored, editedManual, true, limited ? 100 : 0, limited ? 150 : 255);
        }
    }

    OpalControls limited{};
    limited.afMode = OPAL_AF_AUTO;
    limited.limitAfRange = true;
    limited.afRangeInfinity = 90;
    limited.afRangeMacro = 160;
    auto updated = limited;
    updated.afRangeInfinity = 100;
    updated.afRangeMacro = 150;
    dai::CameraControl rangeOnly;
    require(buildDelta(updated, limited, true, rangeOnly), "missing range-only update");
    auto rangeCommand = wire(rangeOnly);
    require(rangeCommand.cmdMask == bit(Command::AF_LENS_RANGE), "range-only update restarted focus");
    expectRange(rangeCommand, 100, 150);

    auto full = limited;
    full.limitAfRange = false;
    dai::CameraControl clear;
    require(buildDelta(full, limited, true, clear), "missing range clear");
    require(wire(clear).cmdMask == bit(Command::AF_LENS_RANGE), "range clear restarted focus");
    expectRange(wire(clear), 0, 255);

    updated = full;
    updated.afRangeInfinity = 200;
    dai::CameraControl ignoredBounds;
    require(!buildDelta(updated, full, true, ignoredBounds), "disabled range edit sent commands");

    updated = limited;
    updated.afRangeInfinity = 400;
    updated.afRangeMacro = -20;
    dai::CameraControl clamped;
    require(buildDelta(updated, limited, true, clamped), "missing clamped range update");
    expectRange(wire(clamped), 0, 255);
    updated.afRangeInfinity = 160;
    updated.afRangeMacro = 90;
    dai::CameraControl reversed;
    require(buildDelta(updated, limited, true, reversed), "missing reversed range update");
    expectRange(wire(reversed), 90, 160);

    std::cout << "Offline serialized autofocus controls passed\n";
}
