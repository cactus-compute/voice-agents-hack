import CoreBluetooth
import Foundation

protocol MeshPeripheralDelegate: AnyObject {
    func peripheral(didReceive data: Data, from centralId: String)
}

/// Runs the Peripheral role: advertises the mesh service UUID and hosts
/// one writable "inbox" characteristic. Incoming writes are forwarded to
/// the delegate (MeshManager).
final class MeshPeripheral: NSObject {
    weak var delegate: MeshPeripheralDelegate?

    private var manager: CBPeripheralManager!
    private var inbox: CBMutableCharacteristic!
    private var advertising = false

    func start() {
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    private func setupService() {
        inbox = CBMutableCharacteristic(
            type: MeshConstants.inboxUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let service = CBMutableService(type: MeshConstants.serviceUUID, primary: true)
        service.characteristics = [inbox]
        manager.add(service)
    }

    private func startAdvertising() {
        guard !advertising else { return }
        advertising = true
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [MeshConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: "MeshNode"
        ])
    }
}

extension MeshPeripheral: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            setupService()
        } else {
            advertising = false
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didAdd service: CBService,
                           error: Error?) {
        if error == nil {
            startAdvertising()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for req in requests {
            guard req.characteristic.uuid == MeshConstants.inboxUUID,
                  let data = req.value else { continue }
            delegate?.peripheral(didReceive: data, from: req.central.identifier.uuidString)
            peripheral.respond(to: req, withResult: .success)
        }
    }
}
