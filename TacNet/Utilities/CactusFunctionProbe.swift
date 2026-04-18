import Foundation

enum CactusFunctionProbe {
    static func verifyCallableSymbols() -> Bool {
        _ = cactusInit as (String, String?, Bool) throws -> CactusModelT
        _ = cactusComplete as (CactusModelT, String, String?, String?, ((String, UInt32) -> Void)?, Data?) throws -> String
        _ = cactusTranscribe as (CactusModelT, String?, String?, String?, ((String, UInt32) -> Void)?, Data?) throws -> String
        _ = cactusDestroy as (CactusModelT) -> Void
        return true
    }
}
