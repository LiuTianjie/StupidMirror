import AppKit
import SwiftUI

struct LicenseActivationView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject var licenseManager: LicenseManager

    @State private var code = ""
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?

    private var isBusy: Bool { licenseManager.isActivating || licenseManager.isSigningIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                icon: "key",
                title: store.t("license.activation.title"),
                subtitle: store.t("license.activation.subtitle"),
                closeHelp: store.t("common.close"),
                closeDisabled: isBusy
            ) {
                store.cancelActivation()
            }

            VStack(alignment: .leading, spacing: 18) {
                licenseStatus

                VStack(alignment: .leading, spacing: 8) {
                    GroupLabel(title: store.t("license.code"))
                    TextField(store.t("license.code.placeholder"), text: $code)
                        .fieldSurface(monospaced: true)
                        .disabled(isBusy)
                        .onSubmit(submit)
                    Text(store.t("license.code.help"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .padding(.horizontal, 4)
                }

                if let errorMessage {
                    HStack(alignment: .top, spacing: 10) {
                        StatusGlyph(kind: .failed, size: 18)
                        Text(errorMessage)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                purchaseLinks

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        accountSection
                        if licenseManager.needsClaim {
                            claimBanner
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    Text(store.t("license.account.optional"))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Ink.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)

            SheetFooter {
                Spacer()
                Button(store.t("common.cancel")) {
                    store.cancelActivation()
                }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .disabled(isBusy)

                Button(action: submit) {
                    if licenseManager.isActivating {
                        Label(store.t("license.redeeming"), systemImage: "hourglass")
                    } else {
                        Label(store.t("license.redeem"), systemImage: "key")
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
            }
        }
        .interactiveDismissDisabled(isBusy)
    }

    private var licenseStatus: some View {
        CheckLine(
            glyph: statusGlyph,
            lead: store.t("license.status.subtitle"),
            object: statusTitle,
            detail: statusDetail,
            detailColor: Theme.Ink.tertiary
        )
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wellSurface()
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let session = licenseManager.authSession {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.t("license.signedIn"))
                            .font(.system(size: 13, weight: .medium))
                        Text(session.email ?? session.userID.uuidString)
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.Ink.tertiary)
                    }
                    Spacer()
                    Button(store.t("license.signOut")) {
                        Task { @MainActor in
                            await store.signOutLicense()
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                    .disabled(isBusy)
                }
            } else {
                Text(store.t("license.signIn.help"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button {
                        signIn(.google)
                    } label: {
                        Label(store.t("license.signIn.google"), systemImage: "globe")
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                    Button {
                        signIn(.github)
                    } label: {
                        Label(store.t("license.signIn.github"), systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                    if licenseManager.isSigningIn {
                        StatusGlyph(kind: .working, size: 20)
                    }
                }
                .disabled(isBusy)

                VStack(alignment: .leading, spacing: 8) {
                    TextField(store.t("license.signIn.email"), text: $email)
                        .fieldSurface()
                    SecureField(store.t("license.signIn.password"), text: $password)
                        .fieldSurface()
                    Button(store.t("license.signIn.emailSubmit")) {
                        signInWithEmail()
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                    .disabled(
                        email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || password.isEmpty
                            || isBusy
                    )
                }
            }
        }
        .padding(14)
        .wellSurface()
    }

    private var claimBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusGlyph(kind: .warning)
            VStack(alignment: .leading, spacing: 6) {
                Text(store.t("license.claim.title"))
                    .font(.system(size: 13, weight: .semibold))
                Text(store.t("license.claim.help"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                .disabled(licenseManager.authSession == nil || isBusy)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wellSurface()
    }

    private var purchaseLinks: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.t("license.purchase.title"))
                    .font(.system(size: 13, weight: .medium))
                Text(store.t("license.purchase.help"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Link(destination: LicensePurchaseURLs.buyURL) {
                Label(store.t("license.purchase.online"), systemImage: "arrow.up.right")
            }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        }
        .padding(14)
        .wellSurface()
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
        guard !licenseManager.isActivating, !licenseManager.isSigningIn,
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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

    private var statusGlyph: StatusGlyph.Kind {
        switch licenseManager.state {
        case .licensed: licenseManager.needsClaim ? .warning : .done
        case .unlicensed: .warning
        case .checking: .working
        case .unavailable: .failed
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
        SettingsGroup(title: store.t("license.section")) {
            HStack(spacing: 12) {
                StatusGlyph(kind: statusGlyph)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.system(size: 13, weight: .medium))
                    Text(capabilitySummary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .unavailable = licenseManager.state {
                        Text(store.t("license.error.storage"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.danger)
                    }
                }
                Spacer(minLength: 12)
                Button {
                    store.presentActivation()
                } label: {
                    Label(store.t("license.openActivation"), systemImage: "key")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var statusGlyph: StatusGlyph.Kind {
        switch licenseManager.state {
        case .licensed: licenseManager.needsClaim ? .warning : .done
        case .unlicensed: .warning
        case .checking: .working
        case .unavailable: .failed
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
