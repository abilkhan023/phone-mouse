import Foundation
import LocalAuthentication
import Security

// Mac passwords for unlocking, one per paired Mac, in this iPhone's keychain.
// Each read asks for Face ID; a change to the enrolled faces makes the item
// unreadable, and the password is asked for again.
enum MacPasswords {
    private static let service = "dev.phonemouse.macPassword"

    static func has(_ host: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = base(host)
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    // Blocks while Face ID is up, so it is called off the main thread.
    static func read(_ host: String, reason: String) -> Result<String, OSStatusError> {
        let context = LAContext()
        context.localizedReason = reason
        var query = base(host)
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = context
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            return .failure(OSStatusError(status: status))
        }
        return .success(password)
    }

    struct OSStatusError: Error {
        let status: OSStatus
    }

    static func save(_ password: String, for host: String) -> Bool {
        forget(host)
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil) else { return false }
        var query = base(host)
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrAccessControl as String] = access
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func forget(_ host: String) {
        SecItemDelete(base(host) as CFDictionary)
    }

    private static func base(_ host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
    }
}
