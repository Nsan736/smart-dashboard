import Foundation

/// Mapbox Vector Tile(protobuf)の最小限の読み取り。国土地理院のベクトルタイル提供実験(experimental_bvmap)の
/// 水部(waterarea)・注記(label)・記号(symbol)を読むのに使う。必要な層だけを読み、ほかの層は飛ばす。
struct VectorTile {
    enum GeometryType: Int {
        case unknown = 0
        case point = 1
        case lineString = 2
        case polygon = 3
    }

    enum Value: Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)

        var string: String? {
            if case .string(let text) = self { return text }
            return nil
        }

        var number: Double? {
            if case .number(let value) = self { return value }
            if case .string(let text) = self { return Double(text) }
            return nil
        }
    }

    struct Feature {
        var type: GeometryType
        var properties: [String: Value]
        /// タイルの中の座標(0〜extent)。リング・線ごとの点の並び
        var parts: [[SIMD2<Double>]]
    }

    struct Layer {
        var name: String
        var extent: Double
        var features: [Feature]
    }

    var layers: [String: Layer]

    enum DecodeError: Error {
        case truncated
        case unsupportedWireType(Int)
    }

    /// layerNames にある層だけを読む(nil ならすべて)
    init(data: Data, layerNames: Set<String>? = nil) throws {
        var reader = ProtobufReader(bytes: [UInt8](data))
        var result: [String: Layer] = [:]
        while !reader.isAtEnd {
            let (field, wire) = try reader.key()
            if field == 3, wire == 2 {
                let bytes = try reader.lengthDelimited()
                if let layer = try Self.layer(bytes, only: layerNames) { result[layer.name] = layer }
            } else {
                try reader.skip(wire)
            }
        }
        layers = result
    }

    private static func layer(_ bytes: ArraySlice<UInt8>, only: Set<String>?) throws -> Layer? {
        var reader = ProtobufReader(bytes: Array(bytes))
        var name = ""
        var extent = 4096.0
        var keys: [String] = []
        var values: [Value] = []
        var rawFeatures: [ArraySlice<UInt8>] = []
        while !reader.isAtEnd {
            let (field, wire) = try reader.key()
            switch (field, wire) {
            case (1, 2): name = String(decoding: try reader.lengthDelimited(), as: UTF8.self)
            case (2, 2): rawFeatures.append(try reader.lengthDelimited())
            case (3, 2): keys.append(String(decoding: try reader.lengthDelimited(), as: UTF8.self))
            case (4, 2): values.append(try value(try reader.lengthDelimited()))
            case (5, 0): extent = Double(try reader.varint())
            default: try reader.skip(wire)
            }
        }
        if let only, !only.contains(name) { return nil }
        var features: [Feature] = []
        features.reserveCapacity(rawFeatures.count)
        for raw in rawFeatures {
            features.append(try feature(raw, keys: keys, values: values))
        }
        return Layer(name: name, extent: extent, features: features)
    }

    private static func value(_ bytes: ArraySlice<UInt8>) throws -> Value {
        var reader = ProtobufReader(bytes: Array(bytes))
        var result = Value.string("")
        while !reader.isAtEnd {
            let (field, wire) = try reader.key()
            switch (field, wire) {
            case (1, 2): result = .string(String(decoding: try reader.lengthDelimited(), as: UTF8.self))
            case (2, 5): result = .number(Double(Float(bitPattern: try reader.fixed32())))
            case (3, 1): result = .number(Double(bitPattern: try reader.fixed64()))
            case (4, 0): result = .number(Double(Int64(bitPattern: try reader.varint())))
            case (5, 0): result = .number(Double(try reader.varint()))
            case (6, 0):
                let raw = try reader.varint()
                result = .number(Double(Int64(raw >> 1) ^ -Int64(raw & 1)))
            case (7, 0): result = .bool(try reader.varint() != 0)
            default: try reader.skip(wire)
            }
        }
        return result
    }

    private static func feature(_ bytes: ArraySlice<UInt8>, keys: [String], values: [Value]) throws -> Feature {
        var reader = ProtobufReader(bytes: Array(bytes))
        var tags: [UInt64] = []
        var type = GeometryType.unknown
        var geometry: [UInt64] = []
        while !reader.isAtEnd {
            let (field, wire) = try reader.key()
            switch (field, wire) {
            case (2, 2): tags = try reader.packedVarints()
            case (3, 0): type = GeometryType(rawValue: Int(try reader.varint())) ?? .unknown
            case (4, 2): geometry = try reader.packedVarints()
            default: try reader.skip(wire)
            }
        }
        var properties: [String: Value] = [:]
        var i = 0
        while i + 1 < tags.count {
            let k = Int(tags[i]), v = Int(tags[i + 1])
            if k < keys.count, v < values.count { properties[keys[k]] = values[v] }
            i += 2
        }
        return Feature(type: type, properties: properties, parts: decodeGeometry(geometry))
    }

    /// 命令(MoveTo=1、LineTo=2、ClosePath=7)の列を、点の並びにする
    static func decodeGeometry(_ commands: [UInt64]) -> [[SIMD2<Double>]] {
        var parts: [[SIMD2<Double>]] = []
        var current: [SIMD2<Double>] = []
        var x: Int64 = 0, y: Int64 = 0
        var i = 0
        func zigzag(_ v: UInt64) -> Int64 { Int64(v >> 1) ^ -Int64(v & 1) }
        while i < commands.count {
            let command = commands[i] & 7
            let count = Int(commands[i] >> 3)
            i += 1
            if command == 7 {
                if !current.isEmpty { parts.append(current); current = [] }
                continue
            }
            for _ in 0..<count {
                guard i + 1 < commands.count else { break }
                x += zigzag(commands[i])
                y += zigzag(commands[i + 1])
                i += 2
                if command == 1, !current.isEmpty {
                    parts.append(current)
                    current = []
                }
                current.append(SIMD2(Double(x), Double(y)))
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

/// protobuf の読み取り(varint、長さつき、固定長)
struct ProtobufReader {
    let bytes: [UInt8]
    private(set) var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count, shift < 64 else { throw VectorTile.DecodeError.truncated }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
    }

    mutating func key() throws -> (field: Int, wire: Int) {
        let raw = try varint()
        return (Int(raw >> 3), Int(raw & 7))
    }

    mutating func lengthDelimited() throws -> ArraySlice<UInt8> {
        let length = Int(try varint())
        guard length >= 0, index + length <= bytes.count else { throw VectorTile.DecodeError.truncated }
        defer { index += length }
        return bytes[index..<(index + length)]
    }

    mutating func fixed32() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw VectorTile.DecodeError.truncated }
        var value: UInt32 = 0
        for k in 0..<4 { value |= UInt32(bytes[index + k]) << (8 * UInt32(k)) }
        index += 4
        return value
    }

    mutating func fixed64() throws -> UInt64 {
        guard index + 8 <= bytes.count else { throw VectorTile.DecodeError.truncated }
        var value: UInt64 = 0
        for k in 0..<8 { value |= UInt64(bytes[index + k]) << (8 * UInt64(k)) }
        index += 8
        return value
    }

    mutating func packedVarints() throws -> [UInt64] {
        let slice = try lengthDelimited()
        var inner = ProtobufReader(bytes: Array(slice))
        var result: [UInt64] = []
        while !inner.isAtEnd { result.append(try inner.varint()) }
        return result
    }

    mutating func skip(_ wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: guard index + 8 <= bytes.count else { throw VectorTile.DecodeError.truncated }; index += 8
        case 2: _ = try lengthDelimited()
        case 5: guard index + 4 <= bytes.count else { throw VectorTile.DecodeError.truncated }; index += 4
        default: throw VectorTile.DecodeError.unsupportedWireType(wire)
        }
    }
}
