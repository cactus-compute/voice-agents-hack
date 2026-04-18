import CoreBluetooth
import Foundation

enum MeshConstants {
    static let serviceUUID = CBUUID(string: "A6B5C4D3-E2F1-0987-6543-210FEDCBA987")
    static let inboxUUID   = CBUUID(string: "A6B5C4D3-E2F1-0987-6543-210FEDCBA988")

    static let defaultTTL: UInt8 = 5
    static let cacheSize   = 256
    static let maxOutbound = 6
}
