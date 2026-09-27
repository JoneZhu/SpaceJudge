import Foundation
import Testing
import SpaceJudgeDomain

enum Fixtures {
    static func scanID(_ value: UInt8 = 1) -> ScanID {
        let bytes = (0..<16).map { index in UInt8((Int(value) + index) % 256) }
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return ScanID(rawValue: uuid)
    }

    static func record(
        id: UInt64,
        parent: UInt64?,
        name: UInt64 = 1,
        kind: NodeKind = .regularFile,
        flags: NodeFlags = [],
        logicalBytes: UInt64? = nil,
        allocatedBytes: UInt64? = nil,
        attributedBytes: UInt64,
        deviceID: UInt64? = nil,
        fileID: UInt64? = nil,
        scanID: ScanID = Fixtures.scanID()
    ) -> NodeRecord {
        NodeRecord(
            id: NodeID(id),
            scanID: scanID,
            parentID: parent.map(NodeID.init),
            name: NameID(name),
            kind: kind,
            flags: flags,
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            attributedBytes: attributedBytes,
            modifiedAt: nil,
            deviceID: deviceID,
            fileID: fileID
        )
    }
}
