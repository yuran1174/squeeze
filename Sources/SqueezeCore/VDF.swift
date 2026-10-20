import Foundation

/// Valve KeyValues (VDF) — the text format of Steam's `libraryfolders.vdf` and `appmanifest_*.acf`.
public indirect enum VDFNode: Equatable {
    case string(String)
    case object([VDFEntry])

    /// Child by key, case-insensitive (Steam is not consistent: "StateFlags", "stateflags").
    public subscript(key: String) -> VDFNode? {
        guard case .object(let entries) = self else { return nil }
        return entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var entries: [VDFEntry] {
        if case .object(let e) = self { return e }
        return []
    }
}

public struct VDFEntry: Equatable {
    public let key: String
    public let value: VDFNode
}

public enum VDFError: Error, Equatable {
    case unexpectedEnd
    case unexpectedToken(String)
}

public enum VDFParser {
    enum Token: Equatable {
        case text(String)
        case open
        case close
    }

    public static func parse(_ text: String) throws -> VDFNode {
        let tokens = tokenize(text)
        var i = 0
        return .object(try entries(tokens, &i, nested: false))
    }

    static func tokenize(_ text: String) -> [Token] {
        let s = Array(text.unicodeScalars)
        var out: [Token] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "\"" {
                var v = String.UnicodeScalarView()
                i += 1
                while i < s.count, s[i] != "\"" {
                    if s[i] == "\\", i + 1 < s.count {
                        switch s[i + 1] {
                        case "n": v.append("\n")
                        case "t": v.append("\t")
                        default: v.append(s[i + 1])
                        }
                        i += 2
                    } else {
                        v.append(s[i])
                        i += 1
                    }
                }
                i += 1
                out.append(.text(String(v)))
            } else if c == "{" {
                out.append(.open)
                i += 1
            } else if c == "}" {
                out.append(.close)
                i += 1
            } else if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                while i < s.count, s[i] != "\n" { i += 1 }
            } else if c.properties.isWhitespace {
                i += 1
            } else {
                var v = String.UnicodeScalarView()
                while i < s.count, !s[i].properties.isWhitespace, s[i] != "{", s[i] != "}", s[i] != "\"" {
                    v.append(s[i])
                    i += 1
                }
                out.append(.text(String(v)))
            }
        }
        return out
    }

    static func entries(_ t: [Token], _ i: inout Int, nested: Bool) throws -> [VDFEntry] {
        var result: [VDFEntry] = []
        while i < t.count {
            switch t[i] {
            case .close:
                guard nested else { throw VDFError.unexpectedToken("}") }
                i += 1
                return result
            case .open:
                throw VDFError.unexpectedToken("{")
            case .text(let key):
                i += 1
                guard i < t.count else { throw VDFError.unexpectedEnd }
                switch t[i] {
                case .text(let value):
                    result.append(VDFEntry(key: key, value: .string(value)))
                    i += 1
                case .open:
                    i += 1
                    result.append(VDFEntry(key: key, value: .object(try entries(t, &i, nested: true))))
                case .close:
                    throw VDFError.unexpectedToken("}")
                }
            }
        }
        if nested { throw VDFError.unexpectedEnd }
        return result
    }
}
