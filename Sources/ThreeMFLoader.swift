import Foundation
import simd

typealias RGBA = UInt32   // 0xRRGGBBAA

/// Malha final já em coordenadas do mundo (mm, Z para cima), agrupada por cor.
struct SceneMesh {
    var positions: [SIMD3<Float>] = []
    var groups: [RGBA: [UInt32]] = [:]
    var triangleCount: Int { groups.values.reduce(0) { $0 + $1.count } / 3 }
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard var lo = positions.first else { return nil }
        var hi = lo
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }
}

struct PlateInfo {
    let id: Int                    // plater_id (1, 2, 3…)
    let name: String               // nome dado no fatiador (pode ser vazio)
}

struct LoadedModel {
    var mesh: SceneMesh
    var bed: CGRect?               // área de impressão do plate exibido (mm, coordenadas do mundo)
    var plateThumbnail: Data?      // Metadata/plate_N.png, se existir
    var objectCount: Int
    var application: String?
    var plate: Int                 // plate exibido
    var plates: [PlateInfo]        // todos os plates do arquivo (vazio = sem informação de plates)
}

enum ThreeMFError: LocalizedError {
    case noModel, empty
    var errorDescription: String? {
        switch self {
        case .noModel: return "Não encontrei o modelo 3D dentro do arquivo 3MF."
        case .empty: return "O arquivo não contém nenhum objeto."
        }
    }
}

// MARK: - Estruturas intermediárias

private struct Component {
    var path: String
    var objectId: Int
    var transform: simd_double4x4
}

private final class MeshData {
    var vertices: [SIMD3<Float>] = []
    var triangles: [SIMD3<UInt32>] = []
    var triColor: [RGBA]? = nil                 // cor por material (3MF genérico)
    var paintOffsets: [UInt32]? = nil           // intervalo em paintBytes por triângulo
    var paintBytes: [UInt8] = []
}

private final class ObjectDef {
    let id: Int
    var mesh: MeshData?
    var components: [Component] = []
    var color: RGBA?
    init(id: Int) { self.id = id }
}

private final class ModelFile {
    var objects: [Int: ObjectDef] = [:]
    var buildItems: [(objectId: Int, transform: simd_double4x4)] = []
    var application: String?
}

/// Configuração por objeto vinda do fatiador (Bambu/Orca ou PrusaSlicer).
private struct SlicerObjectInfo {
    var extruder: Int?
    var partExtruders: [Int?] = []                                    // Bambu: por componente
    var partVisible: [Bool] = []                                      // Bambu: só "normal_part" é peça
    var volumeRanges: [VolumeRange] = []                              // Prusa: faixas de triângulos
}

/// Volume do PrusaSlicer: faixa de triângulos da malha do objeto.
/// Só "ModelPart" é desenhado; volumes negativos, modificadores e bloqueadores de suporte não.
private struct VolumeRange {
    var first: Int, last: Int
    var extruder: Int?
    var visible = true
}

// MARK: - Loader

/// Um loader por arquivo: a leitura do ZIP e o parse dos modelos ficam em cache,
/// então trocar de plate não relê o arquivo inteiro. Não é thread-safe — use sempre na mesma fila.
final class ThreeMFLoader {
    private let zip: ZipArchive
    private var files: [String: ModelFile] = [:]
    private var filamentColors: [RGBA] = []
    private var slicerObjects: [Int: SlicerObjectInfo] = [:]
    private var plates: [(info: PlateInfo, instances: Set<PlateKey>, thumbnail: String?)] = []
    private var bed: CGRect?
    private var rootPath = ""
    private var prepared = false
    private var mesh = SceneMesh()

    static let defaultColor: RGBA = 0xC9CDD4FF

    init(url: URL) throws {
        zip = try ZipArchive(url: url)
    }

    static func load(url: URL, plate: Int = 1) throws -> LoadedModel {
        try ThreeMFLoader(url: url).load(plate: plate)
    }

    private func prepare() throws {
        guard !prepared else { return }
        rootPath = normalize(findRootModelPath())
        guard let rootData = try zip.read(rootPath) else { throw ThreeMFError.noModel }
        files[rootPath] = parseModel(rootData, path: rootPath)
        loadFilamentColors()
        try loadSlicerConfig()
        bed = loadBed()
        prepared = true
    }

    /// Carrega o plate pedido (numeração do fatiador, começando em 1).
    /// Se o número não existir, usa o plate mais próximo.
    func load(plate requested: Int) throws -> LoadedModel {
        try prepare()
        guard let root = files[rootPath] else { throw ThreeMFError.noModel }
        mesh = SceneMesh()

        var plateIndex: Int?
        if !plates.isEmpty {
            plateIndex = plates.firstIndex { $0.info.id == requested }
                ?? (requested < plates[0].info.id ? 0 : plates.count - 1)
        }
        let selectedPlate = plateIndex.map { plates[$0] }

        var occurrence: [Int: Int] = [:]
        var selected = 0
        for item in root.buildItems {
            let inst = occurrence[item.objectId, default: 0]
            occurrence[item.objectId] = inst + 1
            if let p = selectedPlate, !p.instances.contains(PlateKey(objectId: item.objectId, instance: inst)) {
                continue
            }
            selected += 1
            let info = slicerObjects[item.objectId]
            try instantiate(file: root, path: rootPath, objectId: item.objectId,
                            transform: item.transform, extruder: info?.extruder,
                            topInfo: info, depth: 0)
        }
        // Um plate vazio é válido quando o arquivo tem vários; um arquivo sem nada, não.
        if selectedPlate == nil, mesh.positions.isEmpty { throw ThreeMFError.empty }

        let plateId = selectedPlate?.info.id ?? 1
        let thumbPath = selectedPlate?.thumbnail ?? "Metadata/plate_\(plateId).png"
        let thumb = zip.contains(thumbPath) ? try? zip.read(thumbPath) : nil

        var plateBed = bed
        if let b = bed, let i = plateIndex {
            let o = Self.plateOrigin(index: i, count: plates.count, bedSize: b.size)
            plateBed = b.offsetBy(dx: o.x, dy: o.y)
        }
        return LoadedModel(mesh: mesh, bed: plateBed, plateThumbnail: thumb ?? nil,
                           objectCount: selected, application: root.application,
                           plate: plateId, plates: plates.map(\.info))
    }

    /// Posição do plate na cena do Bambu Studio/OrcaSlicer (PartPlateList::compute_origin):
    /// grade com espaço de 1/5 do tamanho da mesa entre plates; linhas seguintes em Y negativo.
    static func plateOrigin(index i: Int, count: Int, bedSize: CGSize) -> CGPoint {
        let v = Float(count).squareRoot()
        let r = v.rounded()
        let cols = max(1, Int(v > r ? r + 1 : r))
        let gap: CGFloat = 1.2
        return CGPoint(x: CGFloat(i % cols) * bedSize.width * gap,
                       y: -CGFloat(i / cols) * bedSize.height * gap)
    }

    // MARK: Caminhos

    private func normalize(_ p: String) -> String {
        var s = p
        while s.hasPrefix("/") { s.removeFirst() }
        return s
    }

    private func findRootModelPath() -> String {
        if let rels = try? zip.read("_rels/.rels") {
            var target: String?
            scanXML(rels) { tag in
                if tag.nameIs("Relationship"), let t = tag.string("Target"),
                   let type = tag.string("Type"), type.hasSuffix("/3dmodel") {
                    target = t
                }
            }
            if let t = target, zip.contains(t) { return normalize(t) }
        }
        if zip.contains("3D/3dmodel.model") { return "3D/3dmodel.model" }
        return zip.entries.keys.first { $0.lowercased().hasSuffix(".model") } ?? "3D/3dmodel.model"
    }

    private func modelFile(_ path: String) throws -> ModelFile? {
        let key = normalize(path)
        if let f = files[key] { return f }
        guard let data = try zip.read(key) else { return nil }
        let f = parseModel(data, path: key)
        files[key] = f
        return f
    }

    // MARK: Parser do .model

    private func parseModel(_ data: Data, path: String) -> ModelFile {
        let file = ModelFile()
        var current: ObjectDef?
        var materials: [Int: [RGBA]] = [:]
        var currentGroup: Int?
        var groupColors: [RGBA] = []
        var inBuild = false

        scanXML(data) { tag in
            let b = tag.base
            if tag.isClosing {
                if tag.nameIs("object"), let o = current {
                    file.objects[o.id] = o
                    current = nil
                } else if tag.nameIs("basematerials") || tag.nameIs("colorgroup") {
                    if let g = currentGroup { materials[g] = groupColors }
                    currentGroup = nil
                } else if tag.nameIs("build") {
                    inBuild = false
                }
                return
            }

            // Caminho quente: vértices e triângulos.
            if tag.nameIs("vertex"), let m = current?.mesh {
                let x = tag.float("x") ?? 0, y = tag.float("y") ?? 0, z = tag.float("z") ?? 0
                m.vertices.append(SIMD3(Float(x), Float(y), Float(z)))
                return
            }
            if tag.nameIs("triangle"), let o = current, let m = o.mesh {
                let t = SIMD3<UInt32>(UInt32(truncatingIfNeeded: tag.int("v1") ?? 0),
                                      UInt32(truncatingIfNeeded: tag.int("v2") ?? 0),
                                      UInt32(truncatingIfNeeded: tag.int("v3") ?? 0))
                let idx = m.triangles.count
                m.triangles.append(t)

                // Cor por material (pid/p1) — 3MF genérico.
                if let pid = tag.int("pid"), let group = materials[pid] {
                    let p1 = tag.int("p1") ?? 0
                    if m.triColor == nil { m.triColor = Array(repeating: 0, count: idx) }
                    m.triColor!.append(p1 < group.count ? group[p1] : 0)
                } else if m.triColor != nil {
                    m.triColor!.append(0)
                }

                // Pintura multicolor (Bambu/Orca: paint_color, Prusa: mmu_segmentation).
                if let r = tag.valueRange("paint_color") ?? tag.valueRange("mmu_segmentation"), !r.isEmpty {
                    if m.paintOffsets == nil { m.paintOffsets = Array(repeating: 0, count: idx + 1) }
                    m.paintBytes.append(contentsOf: UnsafeBufferPointer(start: b + r.lowerBound, count: r.count))
                    m.paintOffsets!.append(UInt32(m.paintBytes.count))
                } else if m.paintOffsets != nil {
                    m.paintOffsets!.append(UInt32(m.paintBytes.count))
                }
                return
            }

            if tag.nameIs("object") {
                let o = ObjectDef(id: tag.int("id") ?? -1)
                if let pid = tag.int("pid"), let g = materials[pid] {
                    let pi = tag.int("pindex") ?? 0
                    if pi < g.count { o.color = g[pi] }
                }
                current = o
                if tag.isSelfClosing { file.objects[o.id] = o; current = nil }
            } else if tag.nameIs("mesh") {
                current?.mesh = MeshData()
            } else if tag.nameIs("component") {
                let comp = Component(path: tag.string("path") ?? path,
                                     objectId: tag.int("objectid") ?? -1,
                                     transform: parseTransform(tag.doubles("transform")))
                current?.components.append(comp)
            } else if tag.nameIs("build") {
                inBuild = true
            } else if tag.nameIs("item"), inBuild {
                file.buildItems.append((tag.int("objectid") ?? -1, parseTransform(tag.doubles("transform"))))
            } else if tag.nameIs("basematerials") || tag.nameIs("colorgroup") {
                currentGroup = tag.int("id")
                groupColors = []
            } else if tag.nameIs("base") {
                groupColors.append(parseColor(tag.string("displaycolor")) ?? Self.defaultColor)
            } else if tag.nameIs("color"), currentGroup != nil {
                groupColors.append(parseColor(tag.string("color")) ?? Self.defaultColor)
            }
        }
        file.application = applicationName(data)
        return file
    }

    private func applicationName(_ data: Data) -> String? {
        // Metadados de texto ficam no início do arquivo; basta olhar os primeiros KB.
        let head = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        guard let r = head.range(of: "name=\"Application\">") else { return nil }
        let rest = head[r.upperBound...]
        guard let end = rest.firstIndex(of: "<") else { return nil }
        return String(rest[..<end])
    }

    // MARK: Configuração do fatiador

    private struct PlateKey: Hashable { let objectId: Int; let instance: Int }

    /// Lê extrusoras por objeto/parte e a lista de plates (Bambu/Orca) ou volumes (Prusa).
    private func loadSlicerConfig() throws {
        // Bambu Studio / OrcaSlicer
        if let data = try zip.read("Metadata/model_settings.config") {
            var curObject: Int?
            var inPart = false
            var inPlate = false
            var plateId: Int?
            var plateName = ""
            var plateThumb: String?
            var plateSet = Set<PlateKey>()
            var instObj: Int?, instIdx: Int?
            var inInstance = false

            scanXML(data) { tag in
                if tag.isClosing {
                    if tag.nameIs("object") { curObject = nil }
                    else if tag.nameIs("part") { inPart = false }
                    else if tag.nameIs("model_instance") {
                        if let o = instObj { plateSet.insert(PlateKey(objectId: o, instance: instIdx ?? 0)) }
                        inInstance = false
                    } else if tag.nameIs("plate") {
                        if let p = plateId {
                            plates.append((PlateInfo(id: p, name: plateName), plateSet, plateThumb))
                        }
                        inPlate = false
                    }
                    return
                }
                if tag.nameIs("object"), !inPlate {
                    curObject = tag.int("id")
                    if let id = curObject { slicerObjects[id] = SlicerObjectInfo() }
                } else if tag.nameIs("part"), let o = curObject {
                    inPart = true
                    slicerObjects[o]?.partExtruders.append(nil)
                    // negative_part, modifier_part, support_blocker/enforcer não aparecem no render do fatiador
                    slicerObjects[o]?.partVisible.append((tag.string("subtype") ?? "normal_part") == "normal_part")
                } else if tag.nameIs("plate") {
                    inPlate = true; plateId = nil; plateName = ""; plateThumb = nil; plateSet = []
                } else if tag.nameIs("model_instance") {
                    inInstance = true; instObj = nil; instIdx = nil
                } else if tag.nameIs("metadata") {
                    let key = tag.string("key"), value = tag.string("value")
                    if inPlate {
                        if key == "plater_id" { plateId = value.flatMap(Int.init) }
                        if key == "plater_name" { plateName = value ?? "" }
                        if key == "thumbnail_file", let v = value, !v.isEmpty { plateThumb = v }
                        if inInstance, key == "object_id" { instObj = value.flatMap(Int.init) }
                        if inInstance, key == "instance_id" { instIdx = value.flatMap(Int.init) }
                    } else if let o = curObject, key == "extruder", let v = value.flatMap(Int.init) {
                        if inPart, var info = slicerObjects[o], !info.partExtruders.isEmpty {
                            info.partExtruders[info.partExtruders.count - 1] = v
                            slicerObjects[o] = info
                        } else {
                            slicerObjects[o]?.extruder = v
                        }
                    }
                }
            }
            plates.sort { $0.info.id < $1.info.id }
            return
        }

        // PrusaSlicer
        if let data = try zip.read("Metadata/Slic3r_PE_model.config") {
            var curObject: Int?
            var inVolume = false
            scanXML(data) { tag in
                if tag.isClosing {
                    if tag.nameIs("object") { curObject = nil }
                    if tag.nameIs("volume") { inVolume = false }
                    return
                }
                if tag.nameIs("object") {
                    curObject = tag.int("id")
                    if let id = curObject { slicerObjects[id] = SlicerObjectInfo() }
                } else if tag.nameIs("volume"), let o = curObject {
                    inVolume = true
                    slicerObjects[o]?.volumeRanges.append(VolumeRange(first: tag.int("firstid") ?? 0,
                                                                      last: tag.int("lastid") ?? -1))
                } else if tag.nameIs("metadata"), let o = curObject, inVolume, tag.string("key") == "volume_type",
                          var info = slicerObjects[o], !info.volumeRanges.isEmpty {
                    info.volumeRanges[info.volumeRanges.count - 1].visible = tag.string("value") == "ModelPart"
                    slicerObjects[o] = info
                } else if tag.nameIs("metadata"), let o = curObject, tag.string("key") == "extruder",
                          let v = tag.string("value").flatMap(Int.init) {
                    if inVolume, var info = slicerObjects[o], !info.volumeRanges.isEmpty {
                        info.volumeRanges[info.volumeRanges.count - 1].extruder = v
                        slicerObjects[o] = info
                    } else {
                        slicerObjects[o]?.extruder = v
                    }
                }
            }
        }
    }

    private func loadFilamentColors() {
        if let data = try? zip.read("Metadata/project_settings.config"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let arr = json["filament_colour"] as? [String] {
                filamentColors = arr.map { parseColor($0) ?? Self.defaultColor }
            }
            return
        }
        if let data = try? zip.read("Metadata/Slic3r_PE.config") {
            let text = String(decoding: data, as: UTF8.self)
            let ext = iniValue(text, "extruder_colour")?.split(separator: ";").map { parseColor(String($0)) } ?? []
            let fil = iniValue(text, "filament_colour")?.split(separator: ";").map { parseColor(String($0)) } ?? []
            let n = max(ext.count, fil.count)
            filamentColors = (0..<n).map { i in
                (i < ext.count ? ext[i] : nil) ?? (i < fil.count ? fil[i] : nil) ?? Self.defaultColor
            }
        }
    }

    private func iniValue(_ text: String, _ key: String) -> String? {
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            let body = l.hasPrefix(";") ? String(l.dropFirst()).trimmingCharacters(in: .whitespaces) : l
            if body.hasPrefix(key + " =") || body.hasPrefix(key + "=") {
                return body.split(separator: "=", maxSplits: 1).last.map {
                    $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
        }
        return nil
    }

    private func loadBed() -> CGRect? {
        var pts: [String] = []
        if let data = try? zip.read("Metadata/project_settings.config"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let area = json["printable_area"] as? [String] {
            pts = area
        } else if let data = try? zip.read("Metadata/Slic3r_PE.config"),
                  let v = iniValue(String(decoding: data, as: UTF8.self), "bed_shape") {
            pts = v.split(separator: ",").map(String.init)
        }
        let xy = pts.compactMap { p -> CGPoint? in
            let c = p.split(separator: "x").compactMap { Double($0) }
            return c.count == 2 ? CGPoint(x: c[0], y: c[1]) : nil
        }
        guard let first = xy.first else { return nil }
        var r = CGRect(origin: first, size: .zero)
        for p in xy { r = r.union(CGRect(origin: p, size: .zero)) }
        return r.width > 0 && r.height > 0 ? r : nil
    }

    // MARK: Instanciação

    private func color(forExtruder e: Int?) -> RGBA? {
        guard let e, e >= 1, e <= filamentColors.count else { return nil }
        return filamentColors[e - 1]
    }

    private func instantiate(file: ModelFile, path: String, objectId: Int, transform: simd_double4x4,
                             extruder: Int?, topInfo: SlicerObjectInfo?, depth: Int) throws {
        guard depth < 16, let obj = file.objects[objectId] else { return }

        if let m = obj.mesh, !m.triangles.isEmpty {
            let base = obj.color ?? color(forExtruder: extruder) ?? (filamentColors.first ?? Self.defaultColor)
            appendMesh(m, transform: transform, baseColor: base,
                       volumeRanges: depth == 0 ? (topInfo?.volumeRanges ?? []) : [],
                       objectExtruder: extruder)
        }

        for (i, comp) in obj.components.enumerated() {
            if depth == 0, let vis = topInfo?.partVisible, i < vis.count, !vis[i] { continue }
            var ext = extruder
            if depth == 0, let parts = topInfo?.partExtruders, i < parts.count, let pe = parts[i], pe > 0 {
                ext = pe
            }
            let compPath = normalize(comp.path)
            guard let f = compPath == path ? file : try modelFile(compPath) else { continue }
            try instantiate(file: f, path: compPath, objectId: comp.objectId,
                            transform: transform * comp.transform, extruder: ext,
                            topInfo: nil, depth: depth + 1)
        }
    }

    private func appendMesh(_ m: MeshData, transform t: simd_double4x4, baseColor: RGBA,
                            volumeRanges: [VolumeRange], objectExtruder: Int?) {
        let offset = UInt32(mesh.positions.count)
        let tf = simd_float4x4(
            SIMD4<Float>(t.columns.0), SIMD4<Float>(t.columns.1),
            SIMD4<Float>(t.columns.2), SIMD4<Float>(t.columns.3))
        let flip = simd_determinant(t) < 0

        for v in m.vertices {
            let w = tf * SIMD4<Float>(v, 1)
            mesh.positions.append(SIMD3(w.x, w.y, w.z))
        }
        let vcount = UInt32(m.vertices.count)

        // Cor base por triângulo (Prusa: volume → extrusora). nil = triângulo não é desenhado.
        var rangeIdx = 0
        func baseFor(_ i: Int) -> RGBA? {
            var col = baseColor
            if !volumeRanges.isEmpty {
                while rangeIdx < volumeRanges.count - 1, i > volumeRanges[rangeIdx].last { rangeIdx += 1 }
                let r = volumeRanges[rangeIdx]
                if i >= r.first, i <= r.last {
                    if !r.visible { return nil }
                    if let e = r.extruder, e > 0, let c = color(forExtruder: e) { col = c }
                }
            }
            if let tc = m.triColor, tc[i] != 0 { return tc[i] }
            return col
        }

        var painter = PaintDecoder()
        for (i, tri) in m.triangles.enumerated() {
            guard tri.x < vcount, tri.y < vcount, tri.z < vcount else { continue }
            let a = tri.x + offset
            var b = tri.y + offset, c = tri.z + offset
            if flip { swap(&b, &c) }
            guard let col = baseFor(i) else { continue }

            if let po = m.paintOffsets, po[i + 1] > po[i] {
                let bytes = m.paintBytes[Int(po[i])..<Int(po[i + 1])]
                painter.reset(bytes)
                decodePaint(&painter, a, b, c, base: col, depth: 0)
            } else {
                mesh.groups[col, default: []].append(contentsOf: [a, b, c])
            }
        }
    }

    // MARK: Pintura multicolor (formato TriangleSelector do PrusaSlicer/Bambu)

    private func decodePaint(_ r: inout PaintDecoder, _ a: UInt32, _ b: UInt32, _ c: UInt32, base: RGBA, depth: Int) {
        let split = r.read(2)
        if split == 0 || depth > 24 {
            var state = r.read(2)
            if state == 3 { state = r.read(4) + 3 }
            let col = state == 0 ? base : (color(forExtruder: state) ?? base)
            mesh.groups[col, default: []].append(contentsOf: [a, b, c])
            return
        }
        let special = r.read(2)
        let v = [a, b, c]
        let v0 = v[special % 3], v1 = v[(special + 1) % 3], v2 = v[(special + 2) % 3]

        func mid(_ p: UInt32, _ q: UInt32) -> UInt32 {
            mesh.positions.append((mesh.positions[Int(p)] + mesh.positions[Int(q)]) * 0.5)
            return UInt32(mesh.positions.count - 1)
        }

        var children: [(UInt32, UInt32, UInt32)]
        switch split {
        case 1:
            let m12 = mid(v1, v2)
            children = [(v0, v1, m12), (m12, v2, v0)]
        case 2:
            let m01 = mid(v0, v1), m02 = mid(v0, v2)
            children = [(v0, m01, m02), (m01, v1, m02), (v1, v2, m02)]
        default:
            let m01 = mid(v0, v1), m12 = mid(v1, v2), m20 = mid(v2, v0)
            children = [(v0, m01, m20), (m01, v1, m12), (m12, v2, m20), (m01, m12, m20)]
        }
        // Os filhos são serializados em ordem reversa.
        for ch in children.reversed() {
            decodePaint(&r, ch.0, ch.1, ch.2, base: base, depth: depth + 1)
        }
    }
}

/// Lê os bits de uma string hexadecimal de pintura, do último caractere para o primeiro,
/// cada nibble do bit menos significativo para o mais significativo.
private struct PaintDecoder {
    private var nibbles: [UInt8] = []
    private var pos = 0     // posição em bits

    mutating func reset(_ bytes: ArraySlice<UInt8>) {
        nibbles.removeAll(keepingCapacity: true)
        for ch in bytes.reversed() {
            switch ch {
            case 48...57: nibbles.append(ch - 48)
            case 65...70: nibbles.append(ch - 55)
            case 97...102: nibbles.append(ch - 87)
            default: continue
            }
        }
        pos = 0
    }

    mutating func read(_ bits: Int) -> Int {
        var v = 0
        for k in 0..<bits {
            let n = pos >> 2
            if n < nibbles.count, (nibbles[n] >> (pos & 3)) & 1 == 1 { v |= 1 << k }
            pos += 1
        }
        return v
    }
}

// MARK: - Utilitários

/// Converte a matriz 3x4 do 3MF (convenção de vetor-linha) em matriz 4x4 coluna.
private func parseTransform(_ v: [Double]?) -> simd_double4x4 {
    guard let m = v, m.count >= 12 else { return matrix_identity_double4x4 }
    return simd_double4x4(columns: (
        SIMD4(m[0], m[1], m[2], 0),
        SIMD4(m[3], m[4], m[5], 0),
        SIMD4(m[6], m[7], m[8], 0),
        SIMD4(m[9], m[10], m[11], 1)))
}

/// "#RRGGBB" ou "#RRGGBBAA" → 0xRRGGBBAA
func parseColor(_ s: String?) -> RGBA? {
    guard var h = s?.trimmingCharacters(in: .whitespaces), h.hasPrefix("#") else { return nil }
    h.removeFirst()
    guard let v = UInt32(h, radix: 16) else { return nil }
    switch h.count {
    case 6: return (v << 8) | 0xFF
    case 8: return v
    case 3:
        let r = (v >> 8) & 0xF, g = (v >> 4) & 0xF, b = v & 0xF
        return (r * 17) << 24 | (g * 17) << 16 | (b * 17) << 8 | 0xFF
    default: return nil
    }
}
