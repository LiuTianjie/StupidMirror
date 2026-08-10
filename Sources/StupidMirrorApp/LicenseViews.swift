import SwiftUI

struct LicenseActivationView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject var licenseManager: LicenseManager

    @State private var code = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.t("license.activation.title"))
                        .font(.title2.weight(.semibold))
                    Text(store.t("license.activation.subtitle"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.cancelActivation()
                } label: {
                    Label(store.t("common.close"), systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(licenseManager.isActivating)
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                licenseStatus

                VStack(alignment: .leading, spacing: 8) {
                    Text(store.t("license.code"))
                        .font(.headline)
                    TextField(store.t("license.code.placeholder"), text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .onSubmit(submit)
                    Text(store.t("license.code.help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                purchasePlaceholder

                HStack {
                    Spacer()
                    Button(store.t("common.cancel")) {
                        store.cancelActivation()
                    }
                    .disabled(licenseManager.isActivating)

                    Button(action: submit) {
                        if licenseManager.isActivating {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text(store.t("license.activating"))
                            }
                        } else {
                            Label(store.t("license.activate"), systemImage: "key.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.accent)
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || licenseManager.isActivating)
                }
            }
            .padding(20)
        }
        .interactiveDismissDisabled(licenseManager.isActivating)
    }

    private var licenseStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.title3)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                if let detail = statusDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var purchasePlaceholder: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "qrcode")
                .font(.system(size: 48))
                .frame(width: 64, height: 64)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(store.t("license.purchase.title"))
                    .font(.headline)
                Text(store.t("license.purchase.placeholder"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    private func submit() {
        guard !licenseManager.isActivating else { return }
        errorMessage = nil
        Task { @MainActor in
            do {
                try await store.activateLicense(code: code)
            } catch {
                errorMessage = localizedActivationError(error)
            }
        }
    }

    private func localizedActivationError(_ error: Error) -> String {
        guard case let LicenseServiceError.rejected(code, _) = error else {
            if case LicenseServiceError.notConfigured = error {
                return store.t("license.error.notConfigured")
            }
            return error.localizedDescription
        }
        switch code {
        case "invalid_or_unavailable":
            return store.t("license.error.invalid")
        case "rate_limited":
            return store.t("license.error.rateLimited")
        case "license_revoked":
            return store.t("license.error.revoked")
        default:
            return error.localizedDescription
        }
    }

    private var statusIcon: String {
        switch licenseManager.state {
        case .licensed: "checkmark.seal.fill"
        case .trial, .trialNotStarted: "clock.fill"
        case .expired: "lock.fill"
        case .checking: "arrow.triangle.2.circlepath"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch licenseManager.state {
        case .licensed: Theme.Palette.live
        case .trial, .trialNotStarted: Theme.Palette.pending
        case .expired, .unavailable: Theme.Palette.danger
        case .checking: .secondary
        }
    }

    private var statusTitle: String {
        switch licenseManager.state {
        case .checking:
            store.t("license.status.checking")
        case .trialNotStarted:
            store.t("license.status.trialNotStarted")
        case .trial:
            store.t("license.status.trial")
        case .expired:
            store.t("license.status.expired")
        case .licensed:
            store.t("license.status.licensed")
        case .unavailable:
            store.t("license.status.unavailable")
        }
    }

    private var statusDetail: String? {
        switch licenseManager.state {
        case let .trial(expiresAt), let .expired(expiresAt):
            return String(format: store.t("license.status.expires"), expiresAt.formatted(date: .abbreviated, time: .shortened))
        case let .unavailable(message):
            return message
        case .trialNotStarted:
            return store.t("license.status.trialStartsOnMirror")
        case .licensed, .checking:
            return nil
        }
    }
}

struct LicenseSettingsSection: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject var licenseManager: LicenseManager

    var body: some View {
        Section(store.t("license.section")) {
            HStack {
                Label(statusTitle, systemImage: statusIcon)
                Spacer()
                if case let .trial(expiresAt) = licenseManager.state {
                    Text(expiresAt, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }

            if case let .unavailable(message) = licenseManager.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.danger)
            }

            Button {
                store.presentActivation()
            } label: {
                Label(store.t("license.openActivation"), systemImage: "key")
            }
        }
    }

    private var statusTitle: String {
        switch licenseManager.state {
        case .checking: store.t("license.status.checking")
        case .trialNotStarted: store.t("license.status.trialNotStarted")
        case .trial: store.t("license.status.trial")
        case .expired: store.t("license.status.expired")
        case .licensed: store.t("license.status.licensed")
        case .unavailable: store.t("license.status.unavailable")
        }
    }

    private var statusIcon: String {
        switch licenseManager.state {
        case .licensed: "checkmark.seal.fill"
        case .trial, .trialNotStarted: "clock"
        case .expired: "lock.fill"
        case .checking: "arrow.triangle.2.circlepath"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }
}
