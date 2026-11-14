import Foundation

/// 测试用的最小 LevelDB 文件构造器：只生成 `LevelDBReader` 需要读取的部分。
enum LevelDBTestFixture {
    static func varint(_ value: Int) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining > 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while remaining > 0
        return bytes
    }

    static func uint32(_ value: Int) -> [UInt8] {
        [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ]
    }

    /// LevelDB internal key 尾缀：小端 `sequence << 8 | type`。
    static func trailer(sequence: UInt64 = 1, type: UInt8 = 1) -> [UInt8] {
        let value = (sequence << 8) | UInt64(type)
        return (0..<8).map { UInt8((value >> (8 * UInt64($0))) & 0xff) }
    }

    /// LevelDB block：前缀压缩条目 + restart 数组。
    static func block(_ entries: [(key: [UInt8], value: [UInt8])]) -> [UInt8] {
        var bytes: [UInt8] = []
        var previous: [UInt8] = []
        for entry in entries {
            var shared = 0
            while shared < previous.count,
                  shared < entry.key.count,
                  previous[shared] == entry.key[shared] {
                shared += 1
            }
            bytes += varint(shared)
            bytes += varint(entry.key.count - shared)
            bytes += varint(entry.value.count)
            bytes += entry.key[shared...]
            bytes += entry.value
            previous = entry.key
        }
        bytes += uint32(0)  // restart[0] 偏移
        bytes += uint32(1)  // restart 数量
        return bytes
    }

    /// literal-only 的 snappy 数据，用于构造压缩块。
    static func snappyLiteral(_ input: [UInt8]) -> [UInt8] {
        var output = varint(input.count)
        var offset = 0
        while offset < input.count {
            let length = min(60, input.count - offset)
            output.append(UInt8((length - 1) << 2))
            output += input[offset..<(offset + length)]
            offset += length
        }
        return output
    }

    /// 生成一个只含单块数据的 SSTable。
    static func sstable(
        _ entries: [(key: String, value: String)],
        tombstones: Set<String> = [],
        compressDataBlock: Bool = false
    ) -> Data {
        let sorted = entries.sorted {
            Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8))
        }
        let dataEntries = sorted.map { entry -> (key: [UInt8], value: [UInt8]) in
            let isTombstone = tombstones.contains(entry.key)
            return (
                Array(entry.key.utf8) + trailer(sequence: isTombstone ? 2 : 1, type: isTombstone ? 0 : 1),
                Array(entry.value.utf8)
            )
        }
        let dataBlock = block(dataEntries)
        let storedBlock = compressDataBlock ? snappyLiteral(dataBlock) : dataBlock
        var file: [UInt8] = storedBlock + [compressDataBlock ? 1 : 0, 0, 0, 0, 0]

        guard let lastKey = dataEntries.last?.key else { return Data() }
        let indexKey = lastKey + trailer(sequence: UInt64.max >> 8)
        let indexBlock = block([
            (key: indexKey, value: varint(0) + varint(storedBlock.count))
        ])
        let indexOffset = file.count
        file += indexBlock + [0, 0, 0, 0, 0]

        var footer: [UInt8] = varint(0) + varint(0)
        footer += varint(indexOffset) + varint(indexBlock.count)
        while footer.count < 40 {
            footer.append(0)
        }
        footer += [0x57, 0xfb, 0x80, 0x8b, 0x24, 0x75, 0x47, 0xdb]
        file += footer
        return Data(file)
    }

    /// 生成一个 FULL 类型的 WriteBatch 日志文件；value 为 nil 表示删除。
    static func log(_ entries: [(key: String, value: String?)]) -> Data {
        var batch: [UInt8] = []
        let sequence: UInt64 = 1
        batch += (0..<8).map { UInt8((sequence >> (8 * UInt64($0))) & 0xff) }
        batch += uint32(entries.count)
        for entry in entries {
            if let value = entry.value {
                batch.append(1)
                batch += varint(entry.key.utf8.count)
                batch += entry.key.utf8
                batch += varint(value.utf8.count)
                batch += value.utf8
            } else {
                batch.append(0)
                batch += varint(entry.key.utf8.count)
                batch += entry.key.utf8
            }
        }

        var record: [UInt8] = [0, 0, 0, 0]  // CRC 校验在读取器中不参与判断
        record += [UInt8(batch.count & 0xff), UInt8((batch.count >> 8) & 0xff)]
        record.append(1)  // FULL
        record += batch
        return Data(record)
    }
}
