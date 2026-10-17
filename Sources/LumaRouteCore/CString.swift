/// Decodes only the bytes before the first NUL within an initialized C buffer.
/// Preserve signed CChar bit patterns and repair invalid UTF-8 as String does.
enum CString {
    static func decodeUTF8(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) }
        return String(decoding:bytes,as:UTF8.self)
    }
}
