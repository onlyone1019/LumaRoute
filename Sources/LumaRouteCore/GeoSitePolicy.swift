import Foundation

/// Replaces the two reviewed categories while preserving every other protobuf field.
/// The rule data retains its MIT / CC BY-SA notices in Resources/Licenses.
public struct GeoSitePolicy {
    public static let approvedSHA256 = "b680dbefd475c3c6ff64db3eebfc679f13c9439d1abb85831898793bea18d0cb"
    private struct Document: Decodable { var format: String; var groups: [String:[Rule]] }
    private struct Rule: Decodable { var type: String; var value: String }
    private let entries: [String:[UInt8]]
    private static let maximumSize = 64*1024*1024

    public init(data: Data) throws {
        guard CoreUpdates.digest(data) == Self.approvedSHA256 else {
            throw LumaError.message("GEO 许可规则缺失或校验失败，当前数据库未改变")
        }
        let document = try JSONDecoder().decode(Document.self,from:data)
        guard document.format == "lumaroute-geosite-policy-v1",Set(document.groups.keys) == ["BILIINTL","SHAREPOINT"] else { throw Self.invalid() }
        var encoded: [String:[UInt8]] = [:]
        for (code,rules) in document.groups {
            var entry = Self.message(1,Array(code.utf8))
            for rule in rules {
                let type: UInt8
                switch rule.type { case "Domain": type = 2; case "Full": type = 3; default: throw Self.invalid() }
                entry += Self.message(2,[8,type]+Self.message(2,Array(rule.value.utf8)))
            }
            encoded[code] = Self.message(1,entry)
        }
        entries = encoded
    }
    public static func load(from url: URL) throws -> GeoSitePolicy {
        guard let size = try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size > 0,size < 64*1024 else {
            throw LumaError.message("缺少已审核的 GEO 许可规则，请重新安装当前版本")
        }
        return try GeoSitePolicy(data:Data(contentsOf:url))
    }
    public func protect(_ payloads: [String:Data]) throws -> [String:Data] {
        guard Set(payloads.keys) == Set(GeoDataUpdates.names),let site = payloads["GeoSite.dat"] else { throw Self.invalid() }
        var result = payloads
        result["GeoSite.dat"] = try applying(to:site)
        return result
    }
    public func applying(to data: Data) throws -> Data {
        guard !data.isEmpty,data.count <= Self.maximumSize else { throw Self.invalid() }
        let bytes = Array(data)
        var cursor = 0,output: [UInt8] = [],seen = Set<String>()
        output.reserveCapacity(bytes.count+2048)
        while cursor < bytes.count {
            let field = try Self.field(bytes,&cursor,end:bytes.count)
            if field.number == 1 {
                guard let entry = field.payload,seen.count < 100_000 else { throw Self.invalid() }
                let code = try Self.code(bytes,in:entry)
                guard seen.insert(code).inserted else { throw Self.invalid() }
                if let replacement = entries[code] { output += replacement }
                else { output.append(contentsOf:bytes[field.encoded]) }
            } else { output.append(contentsOf:bytes[field.encoded]) }
        }
        guard !seen.isEmpty else { throw Self.invalid() }
        for code in entries.keys.sorted() where !seen.contains(code) { output += entries[code]! }
        guard output.count <= Self.maximumSize else { throw Self.invalid() }
        return Data(output)
    }
    private struct Field { var number: UInt64; var encoded: Range<Int>; var payload: Range<Int>? }
    private static func code(_ bytes: [UInt8],in range: Range<Int>) throws -> String {
        var cursor = range.lowerBound,code: String?
        while cursor < range.upperBound {
            let part = try field(bytes,&cursor,end:range.upperBound)
            if part.number == 1 {
                guard code == nil,let value = part.payload,!value.isEmpty,value.count <= 256,
                      let name = String(bytes:bytes[value],encoding:.utf8),!name.isEmpty else { throw invalid() }
                code = name.uppercased()
            }
        }
        guard let code else { throw invalid() }
        return code
    }
    private static func field(_ bytes: [UInt8],_ cursor: inout Int,end: Int) throws -> Field {
        let start = cursor,key = try integer(bytes,&cursor,end:end),number = key >> 3
        guard number > 0,number < 1 << 29 else { throw invalid() }
        var payload: Range<Int>?
        switch key & 7 {
        case 0: _ = try integer(bytes,&cursor,end:end)
        case 1: guard end-cursor >= 8 else { throw invalid() }; cursor += 8
        case 2:
            let length = try integer(bytes,&cursor,end:end)
            guard length <= UInt64(end-cursor) else { throw invalid() }
            payload = cursor..<cursor+Int(length); cursor += Int(length)
        case 5: guard end-cursor >= 4 else { throw invalid() }; cursor += 4
        default: throw invalid()
        }
        return Field(number:number,encoded:start..<cursor,payload:payload)
    }
    private static func integer(_ bytes: [UInt8],_ cursor: inout Int,end: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from:0,through:63,by:7) {
            guard cursor < end else { throw invalid() }
            let byte = bytes[cursor]; cursor += 1
            guard shift < 63 || byte <= 1 else { throw invalid() }
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
        }
        throw invalid()
    }
    private static func message(_ number: UInt64,_ bytes: [UInt8]) -> [UInt8] {
        func varint(_ input: UInt64) -> [UInt8] {
            var number = input,output: [UInt8] = []
            while number >= 128 { output.append(UInt8(number & 0x7f)|0x80); number >>= 7 }
            output.append(UInt8(number)); return output
        }
        return varint(number << 3 | 2)+varint(UInt64(bytes.count))+bytes
    }
    private static func invalid() -> LumaError { .message("GEO 数据或许可分类无效，未应用更新") }
}
