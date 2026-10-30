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
    private var isActivated: Bool { licenseManager.state.isActivated }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                statusCard
                if let errorMessage {
                    errorLine(errorMessage)
                }
            }
            if !isActivated {
                codeGroup
                purchaseGroup
            }
            accountGroup
        }
    }

    // MARK: Status

    private var statusCard: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: statusSymbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 44, height: 44)
                .background(statusBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Ink.primary)
                Text(statusDetail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if licenseManager.state == .checking {
                StatusGlyph(kind: .working, size: 20)
            } else if isActivated {
                StatusPill(title: store.t("license.page.pill.multiDevice"), color: Theme.Palette.live)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wellSurface()
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        switch licenseManager.state {
        case .licensed: "checkmark.seal.fill"
        case .unlicensed: "key.fill"
        case .checking: "hourglass"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch licenseManager.state {
        case .licensed: Theme.Palette.live
        case .unlicensed, .checking: Theme.Ink.secondary
        case .unavailable: Theme.Palette.danger
        }
    }

    private var statusBackground: Color {
        switch licenseManager.state {
        case .licensed: Theme.tint(Theme.Palette.live)
        case .unlicensed, .checking: Theme.Surface.raised
        case .unavailable: Theme.tint(Theme.Palette.danger)
        }
    }

    private var statusTitle: String {
        switch licenseManager.state {
        case .checking: store.t("license.status.checking")
        case .unlicensed: store.t("license.page.unlicensed.title")
        case .licensed: store.t("license.page.licensed.title")
        case .unavailable: store.t("license.status.unavailable")
        }
    }

    private var statusDetail: String {
        switch licenseManager.state {
        case .checking:
            store.t("license.capabilities.checking")
        case .unlicensed:
            store.t("license.page.unlicensed.detail")
        case .licensed:
            licenseManager.principal == .account
                ? store.t("license.page.account.detail")
                : store.t("license.page.licensed.detail")
        case .unavailable:
            store.t("license.error.storage")
        }
    }

    private func errorLine(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StatusGlyph(kind: .failed, size: 18)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    // MARK: Activation code

    private var codeGroup: some View {
        SettingsGroup(title: store.t("license.code"), footer: store.t("license.code.help")) {
            HStack(spacing: 10) {
                TextField(store.t("license.code.placeholder"), text: $code)
                    .fieldSurface(monospaced: true)
                    .disabled(isBusy)
                    .onSubmit(submit)
                Button(action: submit) {
                    if licenseManager.isActivating {
                        Label(store.t("license.redeeming"), systemImage: "hourglass")
                    } else {
                        Text(store.t("license.redeem"))
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
            }
            .padding(14)
        }
    }

    private var purchaseGroup: some View {
        SettingsGroup(title: "") {
            SettingRow(store.t("license.page.purchase.title"), help: store.t("license.page.purchase.help")) {
                Link(destination: LicensePurchaseURLs.buyURL) {
                    Label(store.t("license.purchase.online"), systemImage: "arrow.up.right")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            }
        }
    }

    // MARK: Account

    private var accountGroup: some View {
        SettingsGroup(
            title: store.t("license.account.optional"),
            footer: licenseManager.authSession == nil
                ? store.t(licenseManager.needsClaim ? "license.claim.help" : "license.page.account.footer")
                : nil
        ) {
            if let session = licenseManager.authSession {
                signedInRow(session)
                if licenseManager.needsClaim {
                    RowDivider()
                    SettingRow(store.t("license.claim.title"), help: store.t("license.claim.help")) {
                        Button(action: claim) {
                            Text(store.t("license.claim"))
                        }
                        .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                        .disabled(isBusy)
                    }
                }
            } else {
                SettingRow(store.t("license.page.signIn.quick")) {
                    HStack(spacing: 8) {
                        if licenseManager.isSigningIn {
                            StatusGlyph(kind: .working, size: 18)
                        }
                        Button("Google") { signIn(.google) }
                            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                        Button("GitHub") { signIn(.github) }
                            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                    }
                    .disabled(isBusy)
                }
                RowDivider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(store.t("license.page.signIn.email"))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Ink.primary)
                    HStack(spacing: 8) {
                        TextField(store.t("license.signIn.email"), text: $email)
                            .fieldSurface()
                            .textContentType(.username)
                        SecureField(store.t("license.signIn.password"), text: $password)
                            .fieldSurface()
                            .textContentType(.password)
                            .onSubmit(signInWithEmail)
                        Button(store.t("license.page.signIn.submit"), action: signInWithEmail)
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                            .disabled(
                                email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || password.isEmpty
                                    || isBusy
                            )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    private func signedInRow(_ session: LicenseAuthSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Ink.secondary)
                .frame(width: 30, height: 30)
                .background(Theme.Surface.raised, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(session.email ?? session.userID.uuidString)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(store.t("license.signedIn"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            Spacer(minLength: 12)
            Button(store.t("license.signOut")) {
                Task { @MainActor in
                    await store.signOutLicense()
                }
            }
            .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
            .disabled(isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func claim() {
        errorMessage = nil
        Task { @MainActor in
            do {
                try await store.claimLicense()
            } catch {
                errorMessage = localizedActivationError(error)
            }
        }
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
}

struct LicenseSettingsSection: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject var licenseManager: LicenseManager
    var showsTitle = true

    var body: some View {
        SettingsGroup(title: showsTitle ? store.t("license.section") : "") {
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
