import SwiftUI

struct DevicePosturePicker: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject private var mirror: MirrorCaptureSession
    let session: DeviceSession
    var showsLabels = true

    init(session: DeviceSession, showsLabels: Bool = true) {
        self.session = session
        self.mirror = session.mirrorSession
        self.showsLabels = showsLabels
    }

    var body: some View {
        HStack(spacing: 3) {
            Button {
                store.rotateSimulator(session)
            } label: {
                Group {
                    if let icon = DeviceKitResources.duoBundle?.image(forResource: "rotate.device.right") {
                        Image(nsImage: icon).renderingMode(.template).resizable().scaledToFit()
                    } else {
                        Image(systemName: "rotate.right").resizable().scaledToFit()
                    }
                }
                .frame(width: showsLabels ? 23 : 20, height: showsLabels ? 24 : 22)
                .padding(.horizontal, showsLabels ? 7 : 5)
                .padding(.vertical, showsLabels ? 5 : 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(mirror.isChangingPosture || session.device.connectionState != .connected)
            .help(store.t("mirror.rotateDevice"))
            .accessibilityLabel(store.t("mirror.rotateDevice"))
            Divider().frame(height: 22).padding(.horizontal, 3)
            ForEach(DevicePosture.allCases) { posture in
                let selected = mirror.simulatorDisplay?.posture == posture
                Button {
                    store.changePosture(posture, for: session)
                } label: {
                    HStack(spacing: 5) {
                        Group {
                            if let icon = DeviceKitResources.postureIcon(posture, landscape: mirror.simulatorDisplay.map {
                                $0.activeScreen == "outer" ? !$0.isLandscape : $0.isLandscape
                            } ?? true) {
                                Image(nsImage: icon).renderingMode(.template).resizable().scaledToFit()
                            } else {
                                Image(systemName: posture.systemImage).resizable().scaledToFit()
                            }
                        }
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: showsLabels ? 23 : 20, height: showsLabels ? 22 : 20)
                        if showsLabels { Text(store.t(posture.labelKey)) }
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .padding(.horizontal, showsLabels ? 9 : 5)
                    .padding(.vertical, showsLabels ? 5 : 4)
                    .background(selected ? Color(nsColor: .systemBlue).opacity(0.12) : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Color(nsColor: .systemBlue) : Theme.Ink.secondary)
                .disabled(mirror.isChangingPosture || session.device.connectionState != .connected)
                .help(store.t(posture.labelKey))
                .accessibilityLabel(store.t(posture.labelKey))
                .accessibilityValue(selected ? store.t("mirror.posture.selected") : "")
            }
            if mirror.isChangingPosture && showsLabels {
                ProgressView().controlSize(.mini).padding(.horizontal, 5)
            }
        }
        .padding(showsLabels ? 3 : 2)
        .background(Theme.Surface.well, in: Capsule())
    }
}
