import CoreBluetooth
import Foundation

protocol MeshCentralDelegate: AnyObject {
    func central(connectedPeersChanged count: Int)
}

/// Runs the Central role: scans for the mesh service UUID, connects to
/// discovered peers (up to maxOutbound), discovers each peer's inbox
/// characteristic, and writes outgoing/forwarded messages to connected peers.
final class MeshCentral: NSObject {
    weak var delegate: MeshCentralDelegate?

    private var manager: CBCentralManager!
    private var peers = [UUID: Peer]()
    private var pending = [UUID: CBPeripheral]()

    final class Peer {
        let peripheral: CBPeripheral
        var inbox: CBCharacteristic?
        var isConnected: Bool = false
        init(peripheral: CBPeripheral) { self.peripheral = peripheral }
    }

    func start() {
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    var connectedCount: Int {
        peers.values.filter { $0.isConnected && $0.inbox != nil }.count
    }

    func broadcast(_ data: Data, excluding: String? = nil) {
        for (id, peer) in peers {
            guard peer.isConnected, let inbox = peer.inbox else { continue }
            if id.uuidString == excluding { continue }
            peer.peripheral.writeValue(data, for: inbox, type: .withoutResponse)
        }
    }

    private func startScanning() {
        guard manager.state == .poweredOn else { return }
        manager.scanForPeripherals(
            withServices: [MeshConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func notifyCountChange() {
        delegate?.central(connectedPeersChanged: connectedCount)
    }
}

extension MeshCentral: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScanning()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        if peers[id] != nil || pending[id] != nil { return }
        if connectedCount >= MeshConstants.maxOutbound {
            pending[id] = peripheral
            return
        }
        let peer = Peer(peripheral: peripheral)
        peers[id] = peer
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peers[peripheral.identifier]?.isConnected = true
        peripheral.discoverServices([MeshConstants.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        peers.removeValue(forKey: peripheral.identifier)
        notifyCountChange()
        if let (id, candidate) = pending.first {
            pending.removeValue(forKey: id)
            let peer = Peer(peripheral: candidate)
            peers[id] = peer
            central.connect(candidate, options: nil)
        } else if !central.isScanning {
            startScanning()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        peers.removeValue(forKey: peripheral.identifier)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == MeshConstants.serviceUUID {
            peripheral.discoverCharacteristics([MeshConstants.inboxUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars where c.uuid == MeshConstants.inboxUUID {
            peers[peripheral.identifier]?.inbox = c
            notifyCountChange()
        }
    }
}
