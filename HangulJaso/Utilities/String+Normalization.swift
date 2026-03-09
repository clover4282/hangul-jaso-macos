import Foundation

extension String {
    var nfc: String { precomposedStringWithCanonicalMapping }
    var nfd: String { decomposedStringWithCanonicalMapping }
    var isNFD: Bool { self != nfc }
    var isNFC: Bool { !isNFD }
}
