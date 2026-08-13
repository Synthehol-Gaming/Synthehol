import Foundation

/// A node in Valve's text KeyValues format, used by Steam for `.acf` app manifests
/// and `.vdf` files such as `libraryfolders.vdf`.
public enum ValveKeyValues: Equatable, Sendable {
    case string(String)
    case object([String: ValveKeyValues])

    public subscript(key: String) -> ValveKeyValues? {
        guard case .object(let dict) = self else { return nil }
        // Steam is inconsistent about key casing (e.g. "StateFlags" vs "stateflags").
        return dict[key] ?? dict.first { $0.key.lowercased() == key.lowercased() }?.value
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        stringValue.flatMap(Int.init)
    }
}

public enum ValveKeyValuesError: Error, Equatable {
    case unexpectedEnd
    case unexpectedToken(String)
}

public extension ValveKeyValues {
    /// Parses a KeyValues document. The top level is treated as an object body, so
    /// a file like `"AppState" { ... }` yields `.object(["AppState": ...])`.
    static func parse(_ text: String) throws -> ValveKeyValues {
        var tokens = Tokenizer(text)
        let object = try parseObjectBody(&tokens, topLevel: true)
        return .object(object)
    }

    private static func parseObjectBody(
        _ tokens: inout Tokenizer, topLevel: Bool = false
    ) throws -> [String: ValveKeyValues] {
        var result: [String: ValveKeyValues] = [:]
        while let token = tokens.next() {
            switch token {
            case .close:
                if topLevel { throw ValveKeyValuesError.unexpectedToken("}") }
                return result
            case .open:
                throw ValveKeyValuesError.unexpectedToken("{")
            case .string(let key):
                switch tokens.next() {
                case .string(let value):
                    result[key] = .string(value)
                case .open:
                    result[key] = .object(try parseObjectBody(&tokens))
                case .close, .none:
                    throw ValveKeyValuesError.unexpectedEnd
                }
            }
        }
        if !topLevel { throw ValveKeyValuesError.unexpectedEnd }
        return result
    }

    private enum Token: Equatable {
        case string(String)
        case open
        case close
    }

    private struct Tokenizer {
        private var scalars: [Character]
        private var index = 0

        init(_ text: String) {
            scalars = Array(text)
        }

        mutating func next() -> Token? {
            while index < scalars.count {
                let ch = scalars[index]
                if ch.isWhitespace {
                    index += 1
                } else if ch == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                } else {
                    break
                }
            }
            guard index < scalars.count else { return nil }
            switch scalars[index] {
            case "{":
                index += 1
                return .open
            case "}":
                index += 1
                return .close
            case "\"":
                index += 1
                var value = ""
                while index < scalars.count, scalars[index] != "\"" {
                    if scalars[index] == "\\", index + 1 < scalars.count {
                        index += 1
                        switch scalars[index] {
                        case "n": value.append("\n")
                        case "t": value.append("\t")
                        default: value.append(scalars[index])
                        }
                    } else {
                        value.append(scalars[index])
                    }
                    index += 1
                }
                index += 1 // closing quote
                return .string(value)
            default:
                // Unquoted token (rare but legal in KeyValues).
                var value = ""
                while index < scalars.count, !scalars[index].isWhitespace,
                      scalars[index] != "{", scalars[index] != "}" {
                    value.append(scalars[index])
                    index += 1
                }
                return .string(value)
            }
        }
    }
}
