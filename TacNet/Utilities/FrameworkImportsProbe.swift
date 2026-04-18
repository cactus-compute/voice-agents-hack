import Foundation
import CoreBluetooth
import AVFoundation
import CoreLocation
import SwiftData

enum FrameworkImportsProbe {
    static func touchFrameworkSymbols() {
        _ = CBCentralManager.self
        _ = AVAudioEngine.self
        _ = CLLocationManager.self
        if #available(iOS 17.0, *) {
            _ = ModelContainer.self
        }
    }
}
