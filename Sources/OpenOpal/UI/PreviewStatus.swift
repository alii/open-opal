import SwiftUI

/// What the camera is up to when it is not simply showing a picture, drawn
/// over the preview.
///
/// Connecting, restarting, a failure, and "a setting needs a restart" all used
/// to appear in the panel itself, which pushed every control down and back up
/// again. The preview has nothing to show at those moments anyway, so they go
/// here and nothing else moves.
struct PreviewStatus: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        ZStack {
            if !camera.device.state.isLive {
                Color.black.opacity(0.72)
                connection
                    .padding(24)
                    .frame(maxWidth: 520, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(!camera.device.state.isLive)
        .overlay(alignment: .bottom) {
            if camera.settings.coldDirty, camera.device.state.isLive {
                HStack(spacing: 12) {
                    Text("Size, frame rate or rotation changed. The camera restarts to use it.")
                        .font(Opal.note)
                        .foregroundStyle(Opal.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Restart camera") { Task { await camera.applyColdChanges() } }
                        .buttonStyle(.glow)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.82))
                .overlay(alignment: .top) { Rectangle().fill(Opal.accent).frame(height: 1) }
            }
        }
        .animation(.easeOut(duration: 0.2), value: camera.device.state.isLive)
        .animation(.easeOut(duration: 0.2), value: camera.settings.coldDirty)
    }

    @ViewBuilder
    private var connection: some View {
        switch camera.device.state {
        case .searching, .connecting:
            VStack(alignment: .leading, spacing: 14) {
                heading(camera.isRebooting ? "Restarting camera" : "Connecting", color: Opal.accent)
                log
            }
        case .notFound:
            VStack(alignment: .leading, spacing: 8) {
                heading("No camera", color: Opal.warning)
                Text("Connect your Opal C1 over USB. It will be picked up by itself.")
                    .font(Opal.label)
                    .foregroundStyle(Opal.dim)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 14) {
                heading("Camera failed", color: Opal.warning)
                Text(message)
                    .font(Opal.label)
                    .foregroundStyle(Opal.text)
                    .textSelection(.enabled)
                    .lineLimit(4)
                log
            }
        case .streaming:
            EmptyView()
        }
    }

    private func heading(_ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(color).frame(width: 7, height: 7)
            Text(text.uppercased())
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(color)
        }
    }

    /// The bridge narrates the takeover as it happens. The newest step is
    /// bright and the ones before it fade, and the block is always six lines
    /// tall so it does not jump as steps arrive.
    private var log: some View {
        let steps = Array(camera.device.bootLog.suffix(6))
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let newest = index == steps.count - 1
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(newest ? ">" : "·")
                        .foregroundStyle(newest ? Opal.accent : Opal.faint)
                    Text(step)
                        .foregroundStyle(newest ? Opal.text : Opal.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(height: 6 * 19, alignment: .bottomLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
