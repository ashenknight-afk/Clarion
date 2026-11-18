import Foundation
import LocalAuthentication
import Security

/// Stream keys as generic passwords in the login keychain, one per site. Nothing else stores them.
/// Ad hoc signed builds can't use the data protection keychain, so it is not asked for.
enum StreamKeychain {
    /// Outside the app (the checks) the service gets a `.checks` suffix, so the real keys are never touched.
    static let service: String = {
        if let bundle = Bundle.main.bundleIdentifier { return bundle + ".stream-key" }
        return "io.github.ashenknight-afk.clarion.stream-key.checks"
    }()

    static func key(for site: StreamSite) -> String? {
        var query = baseQuery(site)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Whether a key is saved. Asks for the item's attributes only, so the key itself is not read.
    static func hasKey(for site: StreamSite) -> Bool {
        var query = baseQuery(site)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// nil or empty deletes the key.
    @discardableResult
    static func set(_ key: String?, for site: StreamSite) -> OSStatus {
        let query = baseQuery(site)
        guard let key, !key.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = query
        add[kSecValueData] = data
        add[kSecAttrLabel] = "Clarion \(site.label) stream key"
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// The status a keychain call returns when it would have had to ask the user.
    static func needsInteraction(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled
            || status == errSecInteractionRequired
    }

    private static func baseQuery(_ site: StreamSite) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: site.rawValue,
        ]
        if Bundle.main.bundleIdentifier == nil {
            // The checks run unattended: fail instead of showing a keychain dialog.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext] = context
        }
        return query
    }
}
