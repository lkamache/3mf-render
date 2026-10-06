import Foundation

/// Scanner de XML muito simples e rápido, feito para arquivos 3MF com centenas de MB.
/// Entrega apenas tags de abertura/fechamento com acesso preguiçoso aos atributos.
struct XMLTag {
    let base: UnsafePointer<UInt8>
    let nameStart: Int, nameEnd: Int     // nome local (sem prefixo de namespace)
    let attrStart: Int, attrEnd: Int
    let isClosing: Bool
    let isSelfClosing: Bool

    @inline(__always)
    func nameIs(_ s: StaticString) -> Bool {
        let len = s.utf8CodeUnitCount
        guard nameEnd - nameStart == len else { return false }
        return memcmp(base + nameStart, s.utf8Start, len) == 0
    }

    var name: String {
        String(decoding: UnsafeBufferPointer(start: base + nameStart, count: nameEnd - nameStart), as: UTF8.self)
    }

    /// Localiza o valor de um atributo (aceita prefixo de namespace, ex.: "p:path" casa com "path").
    @inline(__always)
    func valueRange(_ key: StaticString) -> Range<Int>? {
        let k = key.utf8Start
        let klen = key.utf8CodeUnitCount
        var i = attrStart
        while i < attrEnd {
            // pula espaços
            while i < attrEnd, isSpace(base[i]) { i += 1 }
            let ns = i
            while i < attrEnd, base[i] != 61 /* = */, !isSpace(base[i]), base[i] != 47, base[i] != 62 { i += 1 }
            let ne = i
            while i < attrEnd, base[i] != 34, base[i] != 39 { i += 1 }  // até a aspa
            guard i < attrEnd else { return nil }
            let quote = base[i]
            i += 1
            let vs = i
            while i < attrEnd, base[i] != quote { i += 1 }
            let ve = i
            i += 1
            // compara nome local
            var ls = ns
            var j = ns
            while j < ne { if base[j] == 58 /* : */ { ls = j + 1 }; j += 1 }
            if ne - ls == klen, memcmp(base + ls, k, klen) == 0 { return vs..<ve }
        }
        return nil
    }

    func string(_ key: StaticString) -> String? {
        guard let r = valueRange(key) else { return nil }
        return decodeEntities(String(decoding: UnsafeBufferPointer(start: base + r.lowerBound, count: r.count), as: UTF8.self))
    }

    @inline(__always)
    func int(_ key: StaticString) -> Int? {
        guard let r = valueRange(key) else { return nil }
        var i = r.lowerBound
        var neg = false
        if i < r.upperBound, base[i] == 45 { neg = true; i += 1 }
        var v = 0
        var any = false
        while i < r.upperBound, base[i] >= 48, base[i] <= 57 { v = v * 10 + Int(base[i] - 48); i += 1; any = true }
        return any ? (neg ? -v : v) : nil
    }

    @inline(__always)
    func float(_ key: StaticString) -> Double? {
        guard let r = valueRange(key) else { return nil }
        var i = r.lowerBound
        return parseDouble(base, &i, r.upperBound)
    }

    func doubles(_ key: StaticString) -> [Double]? {
        guard let r = valueRange(key) else { return nil }
        return parseDoubleList(base, r.lowerBound, r.upperBound)
    }
}

@inline(__always) func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

@inline(__always)
func parseDouble(_ p: UnsafePointer<UInt8>, _ i: inout Int, _ end: Int) -> Double? {
    while i < end, isSpace(p[i]) { i += 1 }
    var neg = false
    if i < end, p[i] == 45 { neg = true; i += 1 } else if i < end, p[i] == 43 { i += 1 }
    var mant: Double = 0
    var any = false
    while i < end, p[i] >= 48, p[i] <= 57 { mant = mant * 10 + Double(p[i] - 48); i += 1; any = true }
    if i < end, p[i] == 46 {
        i += 1
        var scale: Double = 0.1
        while i < end, p[i] >= 48, p[i] <= 57 { mant += Double(p[i] - 48) * scale; scale *= 0.1; i += 1; any = true }
    }
    guard any else { return nil }
    if i < end, p[i] == 101 || p[i] == 69 {
        i += 1
        var eneg = false
        if i < end, p[i] == 45 { eneg = true; i += 1 } else if i < end, p[i] == 43 { i += 1 }
        var e = 0
        while i < end, p[i] >= 48, p[i] <= 57 { e = e * 10 + Int(p[i] - 48); i += 1 }
        mant *= pow(10, Double(eneg ? -e : e))
    }
    return neg ? -mant : mant
}

func parseDoubleList(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> [Double] {
    var out: [Double] = []
    var i = start
    while i < end {
        if let v = parseDouble(p, &i, end) { out.append(v) } else { i += 1 }
    }
    return out
}

func parseDoubleList(_ s: String) -> [Double] {
    var s = s
    return s.withUTF8 { b in parseDoubleList(b.baseAddress!, 0, b.count) }
}

func decodeEntities(_ s: String) -> String {
    guard s.contains("&") else { return s }
    return s.replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&amp;", with: "&")
}

/// Percorre todas as tags do documento chamando `handler`.
func scanXML(_ data: Data, _ handler: (XMLTag) throws -> Void) rethrows {
    try data.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        let n = raw.count
        var i = 0
        while i < n {
            // procura '<'
            guard let lt = memchr(base + i, 60, n - i) else { return }
            i = UnsafePointer<UInt8>(lt.assumingMemoryBound(to: UInt8.self)) - base + 1
            guard i < n else { return }
            let c = base[i]
            if c == 63 { // <? ... ?>
                while i + 1 < n, !(base[i] == 63 && base[i + 1] == 62) { i += 1 }
                i += 2; continue
            }
            if c == 33 { // <!-- --> ou <![CDATA[ ]]> ou <!DOCTYPE>
                if i + 2 < n, base[i + 1] == 45, base[i + 2] == 45 {
                    i += 3
                    while i + 2 < n, !(base[i] == 45 && base[i + 1] == 45 && base[i + 2] == 62) { i += 1 }
                    i += 3
                } else if i + 7 < n, base[i + 1] == 91 {
                    while i + 2 < n, !(base[i] == 93 && base[i + 1] == 93 && base[i + 2] == 62) { i += 1 }
                    i += 3
                } else {
                    while i < n, base[i] != 62 { i += 1 }
                    i += 1
                }
                continue
            }
            let closing = c == 47
            if closing { i += 1 }
            var ns = i
            while i < n, !isSpace(base[i]), base[i] != 62, base[i] != 47 {
                if base[i] == 58 { ns = i + 1 }
                i += 1
            }
            let ne = i
            let as_ = i
            // fim da tag, respeitando aspas
            var quote: UInt8 = 0
            while i < n {
                let ch = base[i]
                if quote != 0 { if ch == quote { quote = 0 } }
                else if ch == 34 || ch == 39 { quote = ch }
                else if ch == 62 { break }
                i += 1
            }
            guard i < n else { return }
            let selfClosing = i > as_ && base[i - 1] == 47
            let ae = selfClosing ? i - 1 : i
            i += 1
            try handler(XMLTag(base: base, nameStart: ns, nameEnd: ne, attrStart: as_, attrEnd: ae,
                               isClosing: closing, isSelfClosing: selfClosing))
        }
    }
}
