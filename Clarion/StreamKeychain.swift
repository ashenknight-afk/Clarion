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
        read(for: site).key
    }

    /// The key, and the keychain's status: a failure other than errSecItemNotFound means a key may
    /// be saved but couldn't be read (a denied prompt, a locked keychain).
    static func read(for site: StreamSite) -> (key: String?, status: OSStatus) {
        var query = baseQuery(site)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return (nil, status) }
        return (key, status)
    }

    /// Whether a read that gave no key failed for a reason other than there being none.
    static func isUnreadable(_ status: OSStatus) -> Bool {
        status != errSecSuccess && status != errSecItemNotFound
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

    /// In the checks the account carries the process id, so two runs at once never share an item.
    private static func account(_ site: StreamSite) -> String {
        Bundle.main.bundleIdentifier == nil ? "\(site.rawValue).\(getpid())" : site.rawValue
    }

    private static func baseQuery(_ site: StreamSite) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(site),
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
