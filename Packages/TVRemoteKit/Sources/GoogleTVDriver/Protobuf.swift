import Foundation
import TVRemoteCore

struct Proto {
    enum Value {
        case number(UInt64)
        case bytes(Data)
    }

    private(set) var fields: [(Int, Value)] = []

    init(_ fields: [(Int, Value)] = []) {
        self.fields = fields
    }

    init(decoding data: Data) throws {
        var reader = ProtoReader(bytes: Array(data))
        while reader.index < reader.bytes.count {
            let tag = try reader.varint()
            let number = tag >> 3
            guard number > 0, number <= 0x1fff_ffff else { throw TVError.invalidResponse }
            switch tag & 7 {
            case 0: fields.append((Int(number), .number(try reader.varint())))
            case 1: _ = try reader.take(8)
            case 2:
                let length = try reader.varint()
                guard length <= UInt64(reader.bytes.count) else { throw TVError.invalidResponse }
                fields.append((Int(number), .bytes(try reader.take(Int(length)))))
            case 5: _ = try reader.take(4)
            default: throw TVError.invalidResponse
            }
        }
    }

    static func string(_ value: String) -> Value { .bytes(Data(value.utf8)) }
    static func message(_ nested: Proto) -> Value { .bytes(nested.encoded()) }

    func numbers(_ field: Int) -> [UInt64] {
        fields.compactMap { key, value in
            if key == field, case .number(let number) = value { return number }
            return nil
        }
    }

    func byteValues(_ field: Int) -> [Data] {
        fields.compactMap { key, value in
            if key == field, case .bytes(let bytes) = value { return bytes }
            return nil
        }
    }

    func number(_ field: Int) -> UInt64? { numbers(field).last }

    func message(_ field: Int) throws -> Proto? {
        try byteValues(field).last.map(Proto.init(decoding:))
    }

    func encoded() -> Data {
        var result = Data()
        for (number, value) in fields {
            let tag = UInt64(number) << 3
            switch value {
            case .number(let number):
                result.append(Self.varint(tag))
                result.append(Self.varint(number))
            case .bytes(let bytes):
                result.append(Self.varint(tag | 2))
                result.append(Self.varint(UInt64(bytes.count)))
                result.append(bytes)
            }
        }
        return result
    }

    static func varint(_ value: UInt64) -> Data {
        var bytes = Data()
        var remaining = value
        repeat {
            let next = UInt8(remaining & 127)
            remaining >>= 7
            bytes.append(next | (remaining > 0 ? 128 : 0))
        } while remaining != 0
        return bytes
    }
}

private struct ProtoReader {
    let bytes: [UInt8]
    var index = 0

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 7) {
            guard index < bytes.count else { throw TVError.invalidResponse }
            let byte = bytes[index]
            index += 1
            if shift == 63, byte > 1 { throw TVError.invalidResponse }
            result |= UInt64(byte & 127) << shift
            if byte < 128 { return result }
        }
        throw TVError.invalidResponse
    }

    mutating func take(_ count: Int) throws -> Data {
        guard count <= bytes.count - index else { throw TVError.invalidResponse }
        defer { index += count }
        return Data(bytes[index..<(index + count)])
    }
}

struct GoogleTVWire: Sendable {
    static let maximumFrame = 65_536

    let stream: any TLSByteStream

    func send(_ message: Proto) async throws {
        let body = message.encoded()
        guard !body.isEmpty, body.count <= Self.maximumFrame else { throw TVError.invalidCommand }
        try await stream.write(Proto.varint(UInt64(body.count)) + body)
    }

    func read(timeout: Duration = .seconds(3)) async throws -> Proto {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await readFrame() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TVError.timedOut
            }
            defer { group.cancelAll() }
            guard let bytes = try await group.next() else { throw TVError.unreachable }
            return try Proto(decoding: bytes)
        }
    }

    private func readFrame() async throws -> Data {
        var length = 0
        for shift in stride(from: 0, through: 14, by: 7) {
            let prefix = try await stream.read(maxBytes: 1)
            guard let byte = prefix.first else { throw TVError.unreachable }
            guard prefix.count == 1 else { throw TVError.invalidResponse }
            length |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                guard length > 0, length <= Self.maximumFrame else { throw TVError.invalidResponse }
                return try await readExactly(length)
            }
        }
        throw TVError.invalidResponse
    }

    private func readExactly(_ count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            let remaining = count - data.count
            let next = try await stream.read(maxBytes: remaining)
            guard !next.isEmpty else { throw TVError.unreachable }
            guard next.count <= remaining else { throw TVError.invalidResponse }
            data.append(next)
        }
        return data
    }
}
