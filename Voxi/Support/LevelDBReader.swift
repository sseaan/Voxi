import Foundation

/// 只读解析 LevelDB 数据目录。
///
/// Rime 的用户词典（`*.userdb`）就是 LevelDB，这里只实现读取，不打开 LOCK、不写任何文件：
/// - SSTable（`*.ldb`）：footer → index block → data block，支持 snappy 压缩块；
/// - 预写日志（`*.log`）：按 32 KB 分块重组 record，再解析 WriteBatch。
///
/// 任何损坏（截断、未知压缩、越界）都只跳过对应条目，不抛错。数据按「旧表 → 新表 → 日志」
/// 应用，因此同一条目的最新值生效；删除标记会移除旧值。
enum LevelDBReader {
    /// 日志与 SSTable 的物理块大小。
    private static let logBlockSize = 32 * 1024
    private static let footerSize = 48
    private static let tableMagic: [UInt8] = [0x57, 0xfb, 0x80, 0x8b, 0x24, 0x75, 0x47, 0xdb]
    private static let maximumBlockOutput = 64 * 1024 * 1024

    /// 读取目录内所有 `.ldb` 与 `.log`，返回用户键值（字符串）。
    static func keyValues(inDirectory directory: URL) -> [String: String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let tables = contents
            .filter { $0.pathExtension == "ldb" }
            .sorted { fileNumber($0) < fileNumber($1) }
        let logs = contents
            .filter { $0.pathExtension == "log" }
            .sorted { fileNumber($0) < fileNumber($1) }

        var result: [String: String] = [:]
        for url in tables {
            guard let bytes = readBytes(url) else { continue }
            for (key, value) in parseTable(bytes) {
                if let value {
                    result[key] = value
                } else {
                    result.removeValue(forKey: key)
                }
            }
        }
        for url in logs {
            guard let bytes = readBytes(url) else { continue }
            for (key, value) in parseLog(bytes) {
                if let value {
                    result[key] = value
                } else {
                    result.removeValue(forKey: key)
                }
            }
        }
        return result
    }

    // MARK: - SSTable

    private static func parseTable(_ bytes: [UInt8]) -> [(String, String?)] {
        guard bytes.count >= footerSize else { return [] }
        guard Array(bytes[(bytes.count - 8)...]) == tableMagic else { return [] }

        var footerCursor = bytes.count - footerSize
        // metaindex handle：只有过滤器使用，这里不需要。
        guard readVarint(bytes, &footerCursor) != nil,
              readVarint(bytes, &footerCursor) != nil,
              let indexOffset = readVarint(bytes, &footerCursor),
              let indexSize = readVarint(bytes, &footerCursor),
              let indexBlock = readBlock(bytes, offset: indexOffset, size: indexSize)
        else { return [] }

        var result: [(String, String?)] = []
        var seen: Set<String> = []
        for entry in decodeBlock(indexBlock) {
            var handleCursor = 0
            guard let blockOffset = readVarint(entry.value, &handleCursor),
                  let blockSize = readVarint(entry.value, &handleCursor),
                  let dataBlock = readBlock(bytes, offset: blockOffset, size: blockSize)
            else { continue }

            for item in decodeBlock(dataBlock) {
                guard let keyData = decodeUserKey(item.key),
                      let key = String(bytes: keyData.bytes, encoding: .utf8)
                else { continue }
                // 同一个键可能有多条历史版本：同一张表内先出现的是最新版本。
                guard seen.insert(key).inserted else { continue }
                if keyData.isDeletion {
                    result.append((key, nil))
                } else if let value = String(bytes: item.value, encoding: .utf8) {
                    result.append((key, value))
                }
            }
        }
        return result
    }

    /// LevelDB data block 的键带 8 字节 internal key 尾缀（小端 `sequence << 8 | type`），
    /// 其中 type 是尾缀的第一个字节（也就是距离末尾第 8 个字节）。
    private static func decodeUserKey(_ key: [UInt8]) -> (bytes: [UInt8], isDeletion: Bool)? {
        guard key.count > 8 else { return nil }
        switch key[key.count - 8] {
        case 1:
            return (Array(key.dropLast(8)), false)
        case 0:
            return (Array(key.dropLast(8)), true)
        default:
            return nil
        }
    }

    // MARK: - Block

    private static func readBlock(_ bytes: [UInt8], offset: Int, size: Int) -> [UInt8]? {
        guard offset >= 0, size >= 0,
              offset <= bytes.count, size <= bytes.count - offset,
              bytes.count - offset - size >= 5
        else { return nil }

        let end = offset + size
        let raw = Array(bytes[offset..<end])
        switch bytes[end] {
        case 0:
            return raw
        case 1:
            return decompressSnappy(raw)
        default:
            return nil
        }
    }

    private static func decodeBlock(_ bytes: [UInt8]) -> [(key: [UInt8], value: [UInt8])] {
        guard bytes.count >= 4 else { return [] }
        let restartCount = uint32(bytes, at: bytes.count - 4)
        guard restartCount >= 0, restartCount <= (bytes.count - 4) / 4 else { return [] }
        let dataEnd = bytes.count - 4 - restartCount * 4
        guard dataEnd >= 0 else { return [] }

        var cursor = 0
        var previousKey: [UInt8] = []
        var result: [(key: [UInt8], value: [UInt8])] = []
        while cursor < dataEnd {
            guard let shared = readVarint(bytes, &cursor),
                  let nonShared = readVarint(bytes, &cursor),
                  let valueLength = readVarint(bytes, &cursor),
                  shared <= previousKey.count,
                  nonShared <= dataEnd - cursor,
                  valueLength <= dataEnd - cursor - nonShared
            else { break }

            let key = Array(previousKey.prefix(shared)) + Array(bytes[cursor..<(cursor + nonShared)])
            cursor += nonShared
            let value = Array(bytes[cursor..<(cursor + valueLength)])
            cursor += valueLength
            previousKey = key
            result.append((key, value))
        }
        return result
    }

    // MARK: - Write-ahead log

    private static func parseLog(_ bytes: [UInt8]) -> [(String, String?)] {
        var result: [(String, String?)] = []
        var pending: [UInt8]?
        var cursor = 0
        while cursor + 7 <= bytes.count {
            let remainingInBlock = logBlockSize - (cursor % logBlockSize)
            if remainingInBlock < 7 {
                cursor += remainingInBlock
                continue
            }

            let length = Int(bytes[cursor + 4]) | Int(bytes[cursor + 5]) << 8
            let type = bytes[cursor + 6]
            cursor += 7
            guard length <= bytes.count - cursor else { break }
            let fragment = Array(bytes[cursor..<(cursor + length)])
            cursor += length

            switch type {
            case 0:  // 预分配的零填充
                pending = nil
                continue
            case 1:  // FULL
                pending = fragment
            case 2:  // FIRST
                pending = fragment
                continue
            case 3:  // MIDDLE
                pending = (pending ?? []) + fragment
                continue
            case 4:  // LAST
                pending = (pending ?? []) + fragment
            default:
                pending = nil
                continue
            }
            if let record = pending {
                result.append(contentsOf: decodeWriteBatch(record))
            }
            pending = nil
        }
        return result
    }

    private static func decodeWriteBatch(_ record: [UInt8]) -> [(String, String?)] {
        guard record.count >= 12 else { return [] }
        let storedCount = uint32(record, at: 8)
        // 每条记录至少 2 字节（tag + 空键）；防止损坏的 count 造成长循环。
        guard storedCount >= 0, storedCount <= (record.count - 12) / 2 + 1 else { return [] }

        var cursor = 12
        var result: [(String, String?)] = []
        for _ in 0..<storedCount {
            guard cursor < record.count else { break }
            let tag = record[cursor]
            cursor += 1
            guard let keyLength = readVarint(record, &cursor),
                  keyLength <= record.count - cursor
            else { break }
            let key = Array(record[cursor..<(cursor + keyLength)])
            cursor += keyLength

            switch tag {
            case 0:  // 删除
                if let string = String(bytes: key, encoding: .utf8) {
                    result.append((string, nil))
                }
            case 1:  // 写入
                guard let valueLength = readVarint(record, &cursor),
                      valueLength <= record.count - cursor
                else { return result }
                let value = Array(record[cursor..<(cursor + valueLength)])
                cursor += valueLength
                if let string = String(bytes: key, encoding: .utf8),
                   let valueString = String(bytes: value, encoding: .utf8) {
                    result.append((string, valueString))
                }
            default:
                return result
            }
        }
        return result
    }

    // MARK: - Snappy

    /// LevelDB 的 snappy 压缩块（raw block 格式）。
    static func decompressSnappy(_ input: [UInt8]) -> [UInt8]? {
        var cursor = 0
        guard let declaredLength = readVarint(input, &cursor),
              declaredLength >= 0,
              declaredLength <= maximumBlockOutput
        else { return nil }

        var output: [UInt8] = []
        output.reserveCapacity(min(declaredLength, 1 << 16))

        while cursor < input.count {
            let tag = input[cursor]
            cursor += 1
            switch tag & 0x03 {
            case 0:  // literal
                var length = Int(tag >> 2)
                if length < 60 {
                    length += 1
                } else {
                    let extraBytes = length - 59
                    guard extraBytes >= 1, extraBytes <= 4,
                          extraBytes <= input.count - cursor
                    else { return nil }
                    var value = 0
                    for index in 0..<extraBytes {
                        value |= Int(input[cursor + index]) << (8 * index)
                    }
                    cursor += extraBytes
                    length = value + 1
                }
                guard length >= 0, length <= declaredLength - output.count,
                      length <= input.count - cursor
                else { return nil }
                output.append(contentsOf: input[cursor..<(cursor + length)])
                cursor += length
            default:
                var length = 0
                var offset = 0
                switch tag & 0x03 {
                case 1:
                    length = Int((tag >> 2) & 0x07) + 4
                    guard cursor < input.count else { return nil }
                    offset = (Int(tag >> 5) << 8) | Int(input[cursor])
                    cursor += 1
                case 2:
                    length = Int(tag >> 2) + 1
                    guard cursor + 2 <= input.count else { return nil }
                    offset = Int(input[cursor]) | Int(input[cursor + 1]) << 8
                    cursor += 2
                default:
                    length = Int(tag >> 2) + 1
                    guard cursor + 4 <= input.count else { return nil }
                    offset = Int(input[cursor])
                        | Int(input[cursor + 1]) << 8
                        | Int(input[cursor + 2]) << 16
                        | Int(input[cursor + 3]) << 24
                    cursor += 4
                }
                guard offset > 0, offset <= output.count,
                      length <= declaredLength - output.count
                else { return nil }
                // 重叠复制是 snappy 的常规用法，必须逐字节追加。
                var start = output.count - offset
                for _ in 0..<length {
                    output.append(output[start])
                    start += 1
                }
            }
        }
        return output.count == declaredLength ? output : nil
    }

    // MARK: - Bytes

    private static func readBytes(_ url: URL) -> [UInt8]? {
        // 正常 userdb 只有几 MB；超大文件直接跳过，避免一次读入拖住同步。
        let maximumFileSize = 64 * 1024 * 1024
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize <= maximumFileSize
        else { return nil }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return [UInt8](data)
    }

    private static func fileNumber(_ url: URL) -> Int {
        let name = url.lastPathComponent
        var digits = ""
        for character in name {
            guard character.isNumber else { break }
            digits.append(character)
        }
        return Int(digits) ?? 0
    }

    private static func readVarint(_ bytes: [UInt8], _ cursor: inout Int) -> Int? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < bytes.count, shift < 64 {
            let byte = bytes[cursor]
            cursor += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 {
                guard result <= UInt64(Int.max) else { return nil }
                return Int(result)
            }
            shift += 7
        }
        return nil
    }

    private static func uint32(_ bytes: [UInt8], at index: Int) -> Int {
        guard index >= 0, index + 4 <= bytes.count else { return 0 }
        return Int(bytes[index])
            | Int(bytes[index + 1]) << 8
            | Int(bytes[index + 2]) << 16
            | Int(bytes[index + 3]) << 24
    }
}
