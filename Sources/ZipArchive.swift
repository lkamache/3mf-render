import Foundation
import Compression

/// Leitor ZIP mínimo (suficiente para pacotes 3MF): stored + deflate, com suporte a Zip64.
final class ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    enum ZipError: LocalizedError {
        case notZip, corrupt(String), unsupported(UInt16)
        var errorDescription: String? {
            switch self {
            case .notZip: return "O arquivo não é um pacote 3MF (ZIP) válido."
            case .corrupt(let s): return "Arquivo ZIP corrompido: \(s)"
            case .unsupported(let m): return "Método de compressão ZIP não suportado (\(m))."
            }
        }
    }

    private let data: Data
    private(set) var entries: [String: Entry] = [:]
    private var lowercased: [String: String] = [:]

    init(url: URL) throws {
        // Lê o arquivo inteiro de uma vez em vez de mapeá-lo na memória: com mmap, uma falha de
        // leitura (ex.: compartilhamento de rede/SMB que oscila) vira SIGBUS e derruba o app;
        // com leitura normal ela vira um erro tratável, exibido na janela.
        data = try Data(contentsOf: url)
        try readCentralDirectory()
    }

    private func u16(_ o: Int) -> Int { Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 }
    private func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
    private func u64(_ o: Int) -> Int { u32(o) | u32(o + 4) << 32 }

    private func readCentralDirectory() throws {
        let n = data.count
        guard n >= 22 else { throw ZipError.notZip }
        // Procura o End Of Central Directory (EOCD) de trás para frente.
        var eocd = -1
        var i = n - 22
        let limit = max(0, n - 22 - 65_535)
        while i >= limit {
            if u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }

        var count = u16(eocd + 10)
        var cdOffset = u32(eocd + 16)
        // Zip64 EOCD locator
        if eocd >= 20, u32(eocd - 20) == 0x0706_4b50 {
            let z64 = u64(eocd - 20 + 8)
            if z64 + 56 <= n, u32(z64) == 0x0606_4b50 {
                count = u64(z64 + 32)
                cdOffset = u64(z64 + 48)
            }
        }

        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= n, u32(p) == 0x0201_4b50 else { throw ZipError.corrupt("diretório central") }
            let method = UInt16(u16(p + 10))
            var csize = u32(p + 20)
            var usize = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            var offset = u32(p + 42)
            let nameStart = data.startIndex + p + 46
            let name = String(decoding: data[nameStart..<nameStart + nameLen], as: UTF8.self)

            // Campo extra Zip64
            var e = p + 46 + nameLen
            let eEnd = e + extraLen
            while e + 4 <= eEnd {
                let id = u16(e), sz = u16(e + 2)
                if id == 0x0001 {
                    var q = e + 4
                    if usize == 0xFFFF_FFFF { usize = u64(q); q += 8 }
                    if csize == 0xFFFF_FFFF { csize = u64(q); q += 8 }
                    if offset == 0xFFFF_FFFF { offset = u64(q); q += 8 }
                }
                e += 4 + sz
            }

            let entry = Entry(name: name, method: method, compressedSize: csize,
                              uncompressedSize: usize, localHeaderOffset: offset)
            entries[name] = entry
            lowercased[name.lowercased()] = name
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    /// Normaliza caminhos no estilo "/3D/3dmodel.model" e procura sem diferenciar maiúsculas.
    func entry(named path: String) -> Entry? {
        var name = path
        while name.hasPrefix("/") { name.removeFirst() }
        if let e = entries[name] { return e }
        if let real = lowercased[name.lowercased()] { return entries[real] }
        if let decoded = name.removingPercentEncoding, decoded != name {
            return entry(named: decoded)
        }
        return nil
    }

    func contains(_ path: String) -> Bool { entry(named: path) != nil }

    func read(_ path: String) throws -> Data? {
        guard let e = entry(named: path) else { return nil }
        let lh = e.localHeaderOffset
        guard lh + 30 <= data.count, u32(lh) == 0x0403_4b50 else { throw ZipError.corrupt("cabeçalho local de \(e.name)") }
        let start = lh + 30 + u16(lh + 26) + u16(lh + 28)
        guard start + e.compressedSize <= data.count else { throw ZipError.corrupt("tamanho de \(e.name)") }
        let src = data.subdata(in: data.startIndex + start ..< data.startIndex + start + e.compressedSize)

        switch e.method {
        case 0:
            return src
        case 8:
            if e.uncompressedSize == 0 { return Data() }
            var out = Data(count: e.uncompressedSize)
            let written = out.withUnsafeMutableBytes { dst in
                src.withUnsafeBytes { s in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, e.uncompressedSize,
                                              s.bindMemory(to: UInt8.self).baseAddress!, e.compressedSize,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            guard written == e.uncompressedSize else { throw ZipError.corrupt("falha ao descompactar \(e.name)") }
            return out
        default:
            throw ZipError.unsupported(e.method)
        }
    }
}
