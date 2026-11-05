import AppKit
import SwiftUI

/// The Membership page: one device stays free without an account; several
/// devices at once need the iTool yearly membership on a signed-in account.
struct LicenseActivationView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject var licenseManager: LicenseManager

    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?

    private var isBusy: Bool { licenseManager.isSigningIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                statusCard
                if let errorMessage {
                    errorLine(errorMessage)
                }
            }
            if !licenseManager.state.isEntitled {
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
            } else if licenseManager.state.isEntitled {
                StatusPill(title: store.t("license.page.pill.multiDevice"), color: Theme.Palette.live)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wellSurface(radius: Theme.Radius.panel - DashboardWindowLayout.gutter, outlined: false)
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        switch licenseManager.state {
        case .member: "checkmark.seal.fill"
        case .signedOut, .notMember: "person.crop.circle"
        case .checking: "hourglass"
        case .unverified: "wifi.exclamationmark"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch licenseManager.state {
        case .member: Theme.Palette.live
        case .signedOut, .notMember, .checking: Theme.Ink.secondary
        case .unverified: Theme.Palette.pending
        case .unavailable: Theme.Palette.danger
        }
    }

    private var statusBackground: Color {
        switch licenseManager.state {
        case .member: Theme.tint(Theme.Palette.live)
        case .signedOut, .notMember, .checking: Theme.Surface.raised
        case .unverified: Theme.tint(Theme.Palette.pending)
        case .unavailable: Theme.tint(Theme.Palette.danger)
        }
    }

    private var statusTitle: String {
        switch licenseManager.state {
        case .checking: store.t("license.status.checking")
        case .signedOut: store.t("license.page.free.title")
        case let .notMember(status):
            status.tier == .monthly
                ? store.t("license.page.monthly.title")
                : store.t("license.page.notMember.title")
        case .member: store.t("license.page.member.title")
        case .unverified: store.t("license.page.unverified.title")
        case .unavailable: store.t("license.status.unavailable")
        }
    }

    private var statusDetail: String {
        switch licenseManager.state {
        case .checking:
            return store.t("license.capabilities.checking")
        case .signedOut:
            return store.t("license.page.free.detail")
        case let .notMember(status):
            if status.tier == .monthly {
                return expiryLine("license.page.monthly.detail", status.memberUntil)
            }
            return store.t("license.page.notMember.detail")
        case let .member(status):
            guard let validUntil = status.validUntil else {
                return store.t("license.page.member.detailNoEnd")
            }
            return expiryLine("license.page.member.detail", validUntil)
        case .unverified:
            return store.t("license.page.unverified.detail")
        case .unavailable:
            return store.t("license.error.storage")
        }
    }

    private func expiryLine(_ key: String, _ date: Date?) -> String {
        guard let date else { return store.t(key + "NoDate") }
        return String(format: store.t(key), formatted(date))
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: store.language.usesChinese ? "zh_CN" : "en_US")
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
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

    // MARK: Membership

    private var isMonthlyMember: Bool {
        if case let .notMember(status) = licenseManager.state { return status.tier == .monthly }
        return false
    }

    private var purchaseGroup: some View {
        SettingsGroup(title: store.t("license.page.membership.title"), footer: store.t("license.page.purchase.footer")) {
            SettingRow(
                store.t(isMonthlyMember ? "license.purchase.upgrade" : "license.purchase.join"),
                help: store.t(isMonthlyMember ? "license.page.upgrade.help" : "license.page.purchase.help")
            ) {
                HStack(spacing: 8) {
                    if licenseManager.isSignedIn {
                        Button {
                            refresh()
                        } label: {
                            if licenseManager.isChecking {
                                Label(store.t("license.refreshing"), systemImage: "hourglass")
                            } else {
                                Label(store.t("license.refresh"), systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
                        .disabled(licenseManager.isChecking)
                    }
                    Button {
                        store.openMembershipPurchase()
                    } label: {
                        Label(store.t(isMonthlyMember ? "license.purchase.upgradeButton" : "license.purchase.online"), systemImage: "arrow.up.right")
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                }
            }
        }
    }

    // MARK: Account

    private var accountGroup: some View {
        SettingsGroup(
            title: store.t("license.account"),
            footer: licenseManager.authSession == nil ? store.t("license.page.account.footer") : nil
        ) {
            if let session = licenseManager.authSession {
                signedInRow(session)
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
                Text(tierLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            Spacer(minLength: 12)
            if licenseManager.state.isEntitled {
                Button {
                    refresh()
                } label: {
                    Label(store.t("license.refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
                .disabled(licenseManager.isChecking)
            }
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

    private var tierLabel: String {
        switch licenseManager.state {
        case let .member(status), let .notMember(status):
            switch status.tier {
            case .yearly: return store.t("license.tier.yearly")
            case .monthly: return store.t("license.tier.monthly")
            case .free: return store.t("license.tier.free")
            }
        case .checking:
            return store.t("license.status.checking")
        default:
            return store.t("license.signedIn")
        }
    }

    private func refresh() {
        errorMessage = nil
        Task { @MainActor in
            await store.refreshMembership()
            if licenseManager.lastCheckFailed {
                errorMessage = store.t("license.error.offline")
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
                errorMessage = localizedError(error)
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
                errorMessage = localizedError(error)
            }
        }
    }

    private func localizedError(_ error: Error) -> String {
        if case LicenseAuthError.notConfigured = error {
            return store.t("license.error.notConfigured")
        }
        if error is MembershipCheckError || error is URLError {
            return store.t("license.error.offline")
        }
        return error.localizedDescription
    }
}
