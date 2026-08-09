import Foundation
import Security
import XCTest
@testable import MomoMoreEfficient

final class TokenStoreTests: XCTestCase {
    func testProductionKeychainItemIsDeviceLocalUnlockedOnlyAndNonSynchronizable() {
        let attributes = KeychainTokenStore.addAttributes(tokenData: Data())

        XCTAssertEqual(
            attributes[kSecClass as String] as? String,
            kSecClassGenericPassword as String
        )
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(
            attributes[kSecAttrService as String] as? String,
            "com.davidqyc.momoMoreEfficient.maimemo-token"
        )
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, "main-account")
        XCTAssertFalse(KeychainTokenStore.isSynchronizable)
    }
}
