import Foundation

/// StupidMirror's multi-device use is part of the iTool yearly membership,
/// bought with Alipay on itool.tech. The page redirects to the visitor's
/// locale.
enum LicensePurchaseURLs {
    static let buyURL = URL(string: "https://itool.tech/pro?from=stupidmirror")!

    static func buyURL(chinese: Bool) -> URL {
        URL(string: "https://itool.tech/\(chinese ? "zh" : "en")/pro?from=stupidmirror")!
    }
}
