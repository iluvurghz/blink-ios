import Foundation

/// Произвольный JSON. Нужен для «непрозрачной» копии объекта трека в записи манифеста и задаче:
/// приложение кладёт туда трек в форме сайта, ядро его не разбирает.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// Общие кодировщик и декодер: лишние поля сервера старые приложения не ломают.
public enum BlinkJSON {
    public static func encode<T: Encodable>(_ value: T) -> String? {
        let enc = JSONEncoder()
        guard let data = try? enc.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Разбор произвольного JSON-текста в словарь (для ответов сервера нестрогой формы).
    public static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
    }

    public static func array(_ text: String) -> [Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [Any]
    }
}

/// Достаём значения из словаря JSONSerialization одинаково на Apple и на Linux (там числа приходят иначе).
public enum JSONField {
    public static func string(_ o: [String: Any], _ name: String) -> String? {
        guard let v = o[name], !(v is NSNull) else { return nil }
        if let s = v as? String { return s }
        if let i = v as? Int { return String(i) }
        if let d = v as? Double {
            if d.isFinite && d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    public static func int64(_ o: [String: Any], _ name: String) -> Int64? {
        guard let v = o[name], !(v is NSNull) else { return nil }
        if let i = v as? Int { return Int64(i) }
        if let d = v as? Double {
            if d.isFinite && abs(d) < 9e18 { return Int64(d) }
            return nil
        }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let d = Double(s), d.isFinite, abs(d) < 9e18 { return Int64(d) }
        return nil
    }

    public static func int(_ o: [String: Any], _ name: String) -> Int? {
        guard let v = int64(o, name) else { return nil }
        return Int(truncatingIfNeeded: v)
    }

    public static func bool(_ o: [String: Any], _ name: String) -> Bool? {
        guard let v = o[name], !(v is NSNull) else { return nil }
        if let b = v as? Bool { return b }
        if let s = v as? String { return s == "true" ? true : (s == "false" ? false : nil) }
        return nil
    }

    public static func object(_ o: [String: Any], _ name: String) -> [String: Any]? {
        return o[name] as? [String: Any]
    }

    public static func array(_ o: [String: Any], _ name: String) -> [Any]? {
        return o[name] as? [Any]
    }
}
