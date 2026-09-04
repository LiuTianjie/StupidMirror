import AppKit
import SwiftUI

struct LicenseActivationView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject var licenseManager: LicenseManager

    @State private var code = ""
    @State private var email = ""
    @State private var password = ""
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
                .disabled(licenseManager.isActivating || licenseManager.isSigningIn)
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                licenseStatus
                accountSection

                if licenseManager.needsClaim {
                    claimBanner
                }

                purchaseLinks

                VStack(alignment: .leading, spacing: 8) {
                    Text(store.t("license.code"))
                        .font(.headline)
                    TextField(store.t("license.code.placeholder"), text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .disabled(licenseManager.authSession == nil)
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

                HStack {
                    Spacer()
                    Button(store.t("common.cancel")) {
                        store.cancelActivation()
                    }
                    .disabled(licenseManager.isActivating || licenseManager.isSigningIn)

                    Button(action: submit) {
                        if licenseManager.isActivating {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text(store.t("license.redeeming"))
                            }
                        } else {
                            Label(store.t("license.redeem"), systemImage: "key.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.accent)
                    .disabled(
                        licenseManager.authSession == nil
                            || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || licenseManager.isActivating
                            || licenseManager.isSigningIn
                    )
                }
            }
            .padding(20)
        }
        .interactiveDismissDisabled(licenseManager.isActivating || licenseManager.isSigningIn)
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

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let session = licenseManager.authSession {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.t("license.signedIn"))
                            .font(.headline)
                        Text(session.email ?? session.userID.uuidString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(store.t("license.signOut")) {
                        Task { @MainActor in
                            await store.signOutLicense()
                        }
                    }
                    .disabled(licenseManager.isSigningIn || licenseManager.isActivating)
                }
            } else {
                Text(store.t("license.signIn.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        signIn(.google)
                    } label: {
                        Label(store.t("license.signIn.google"), systemImage: "globe")
                    }
                    Button {
                        signIn(.github)
                    } label: {
                        Label(store.t("license.signIn.github"), systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    if licenseManager.isSigningIn {
                        ProgressView().controlSize(.small)
                    }
                }
                .disabled(licenseManager.isSigningIn || licenseManager.isActivating)

                VStack(alignment: .leading, spacing: 8) {
                    TextField(store.t("license.signIn.email"), text: $email)
                        .textFieldStyle(.roundedBorder)
                    SecureField(store.t("license.signIn.password"), text: $password)
                        .textFieldStyle(.roundedBorder)
                    Button(store.t("license.signIn.emailSubmit")) {
                        signInWithEmail()
                    }
                    .disabled(
                        email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || password.isEmpty
                            || licenseManager.isSigningIn
                            || licenseManager.isActivating
                    )
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    private var claimBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.t("license.claim.title"))
                .font(.headline)
            Text(store.t("license.claim.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { @MainActor in
                    errorMessage = nil
                    do {
                        try await store.claimLicense()
                    } catch {
                        errorMessage = localizedActivationError(error)
                    }
                }
            } label: {
                Label(store.t("license.claim"), systemImage: "person.crop.circle.badge.checkmark")
            }
            .disabled(licenseManager.authSession == nil || licenseManager.isActivating || licenseManager.isSigningIn)
        }
        .padding(12)
        .background(Theme.Palette.pending.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var purchaseLinks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.t("license.purchase.title"))
                .font(.headline)
            Text(store.t("license.purchase.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Link(store.t("license.purchase.online"), destination: LicensePurchaseURLs.buyURL)
            }
            .font(.caption.weight(.medium))
            .disabled(licenseManager.authSession == nil)
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    private func signIn(_ provider: LicenseAuthProvider) {
        errorMessage = nil
        Task { @MainActor in
            do {
                try await store.signInLicense(provider: provider)
            } catch LicenseAuthError.cancelled {
                errorMessage = nil
            } catch {
                errorMessage = localizedActivationError(error)
            }
        }
    }

    private func signInWithEmail() {
        errorMessage = nil
        Task { @MainActor in
            do {
                try await store.signInLicense(email: email, password: password)
                password = ""
            } catch {
                errorMessage = localizedActivationError(error)
            }
        }
    }

    private func submit() {
        guard !licenseManager.isActivating, licenseManager.authSession != nil else { return }
        errorMessage = nil
        Task { @MainActor in
            do {
                try await store.redeemLicense(code: code)
            } catch {
                errorMessage = localizedActivationError(error)
            }
        }
    }

    private func localizedActivationError(_ error: Error) -> String {
        if case LicenseServiceError.loginRequired = error {
            return store.t("license.error.loginRequired")
        }
        if case LicenseServiceError.iToolCodeNotAccepted = error {
            return store.t("license.error.itool")
        }
        if case LicenseAuthError.notConfigured = error {
            return store.t("license.error.notConfigured")
        }
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
        case "login_required":
            return store.t("license.error.loginRequired")
        case "already_licensed":
            return store.t("license.error.alreadyLicensed")
        case "already_claimed":
            return store.t("license.error.alreadyClaimed")
        case "claim_required":
            return store.t("license.error.claimRequired")
        case "itool_code_not_accepted":
            return store.t("license.error.itool")
        default:
            return error.localizedDescription
        }
    }

    private var statusIcon: String {
        switch licenseManager.state {
        case .licensed: "checkmark.seal.fill"
        case .unlicensed: "lock.open.fill"
        case .checking: "arrow.triangle.2.circlepath"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch licenseManager.state {
        case .licensed: Theme.Palette.live
        case .unlicensed: Theme.Palette.pending
        case .unavailable: Theme.Palette.danger
        case .checking: .secondary
        }
    }

    private var statusTitle: String {
        switch licenseManager.state {
        case .checking:
            store.t("license.status.checking")
        case .unlicensed:
            store.t("license.status.unlicensed")
        case .licensed:
            store.t("license.status.licensed")
        case .unavailable:
            store.t("license.status.unavailable")
        }
    }

    private var statusDetail: String? {
        switch licenseManager.state {
        case .unavailable:
            return store.t("license.error.storage")
        case .unlicensed:
            return store.t("license.capabilities.unactivated")
        case .licensed:
            if licenseManager.needsClaim {
                return store.t("license.capabilities.needsClaim")
            }
            return licenseManager.principal == .account
                ? store.t("license.capabilities.account")
                : store.t("license.capabilities.activated")
        case .checking:
            return store.t("license.capabilities.checking")
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
            }

            Text(capabilitySummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if case .unavailable = licenseManager.state {
                Text(store.t("license.error.storage"))
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
        case .unlicensed: store.t("license.status.unlicensed")
        case .licensed: store.t("license.status.licensed")
        case .unavailable: store.t("license.status.unavailable")
        }
    }

    private var statusIcon: String {
        switch licenseManager.state {
        case .licensed: "checkmark.seal.fill"
        case .unlicensed: "lock.open.fill"
        case .checking: "arrow.triangle.2.circlepath"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var capabilitySummary: String {
        if licenseManager.needsClaim {
            return store.t("license.capabilities.needsClaim")
        }
        if licenseManager.state.isActivated {
            return licenseManager.principal == .account
                ? store.t("license.capabilities.account")
                : store.t("license.capabilities.activated")
        }
        return store.t("license.capabilities.unactivated")
    }
}
