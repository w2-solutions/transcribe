import Foundation

/// A JSON-RPC request id: an integer or a string. `null` ids are rejected (§3.3).
public enum RPCID: Sendable, Hashable, Codable {
    case int(Int64)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int64.self) { self = .int(i) } else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }

    var json: JSONValue {
        switch self {
        case .int(let i): .int(i)
        case .string(let s): .string(s)
        }
    }

    init?(_ v: JSONValue) {
        switch v {
        case .int(let i): self = .int(i)
        case .string(let s): self = .string(s)
        default: return nil
        }
    }
}

public struct RPCError: Error, Sendable, Equatable {
    public var code: Int
    public var message: String
    public init(code: Int, message: String) { self.code = code; self.message = message }

    public static let parse = RPCError(code: -32700, message: "Parse error")
    public static let invalidRequest = RPCError(code: -32600, message: "Invalid Request")
    public static let methodNotFound = RPCError(code: -32601, message: "Method not found")
    public static let invalidParams = RPCError(code: -32602, message: "Invalid params")
    public static let internalError = RPCError(code: -32603, message: "Internal error")
}

/// One incoming JSON-RPC message, classified by its fields (§3.3). Batches (arrays) are not accepted.
public enum RPCMessage: Sendable {
    case request(id: RPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    /// A reply from the client to a server request; the server never sends any, so these are ignored.
    case response(id: RPCID)

    public static func parse(_ data: Data) -> Result<RPCMessage, RPCError> {
        guard let value = try? JSONValue.decode(data) else { return .failure(.parse) }
        guard case .object(let o) = value, o["jsonrpc"] == .string("2.0") else { return .failure(.invalidRequest) }
        if let method = o["method"] {
            guard case .string(let name) = method else { return .failure(.invalidRequest) }
            let params = o["params"]
            guard let rawID = o["id"] else { return .success(.notification(method: name, params: params)) }
            guard let id = RPCID(rawID) else { return .failure(.invalidRequest) }
            return .success(.request(id: id, method: name, params: params))
        }
        if let rawID = o["id"], let id = RPCID(rawID), o["result"] != nil || o["error"] != nil {
            return .success(.response(id: id))
        }
        return .failure(.invalidRequest)
    }
}

/// Encodes replies as one line of JSON (see `JSONValue.encoded`).
public enum RPCEncode {
    public static func result(_ id: RPCID, _ v: JSONValue) -> Data {
        JSONValue.object(["jsonrpc": "2.0", "id": id.json, "result": v]).encoded()
    }

    public static func error(_ id: RPCID?, _ e: RPCError) -> Data {
        JSONValue.object(["jsonrpc": "2.0", "id": id?.json ?? .null,
                          "error": .object(["code": .int(Int64(e.code)), "message": .string(e.message)])]).encoded()
    }
}
