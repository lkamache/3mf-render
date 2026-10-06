import AppKit
import SceneKit
import simd

/// Constrói a cena SceneKit a partir do modelo carregado.
/// Coordenadas: 3MF usa Z para cima; SceneKit usa Y para cima → (x, y, z) ↦ (x, z, -y).
enum SceneBuilder {
    struct Result {
        let scene: SCNScene
        let camera: SCNNode
        let target: SCNVector3
        let boundsMin: SIMD3<Float>
        let boundsMax: SIMD3<Float>

        /// Volta a câmera para o enquadramento inicial.
        func resetCamera() { SceneBuilder.frame(camera: camera, min: boundsMin, max: boundsMax) }
    }

    /// Normal por face calculada no fragment shader: sombreamento facetado (como nos fatiadores)
    /// sem precisar duplicar vértices — importante para malhas com milhões de triângulos.
    private static let flatShading = """
    #pragma body
    float3 fdx = dfdx(_surface.position);
    float3 fdy = dfdy(_surface.position);
    _surface.normal = normalize(cross(fdy, fdx));
    """

    static func build(_ model: LoadedModel) -> Result {
        let scene = SCNScene()
        let root = scene.rootNode

        // --- Geometria do modelo
        let pos = model.mesh.positions.map { SIMD3<Float>($0.x, $0.z, -$0.y) }
        let vdata = pos.withUnsafeBufferPointer { Data(buffer: $0) }
        let source = SCNGeometrySource(data: vdata, semantic: .vertex, vectorCount: pos.count,
                                       usesFloatComponents: true, componentsPerVector: 3,
                                       bytesPerComponent: 4, dataOffset: 0,
                                       dataStride: MemoryLayout<SIMD3<Float>>.stride)
        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        for (rgba, idx) in model.mesh.groups.sorted(by: { $0.key < $1.key }) where !idx.isEmpty {
            let data = idx.withUnsafeBufferPointer { Data(buffer: $0) }
            elements.append(SCNGeometryElement(data: data, primitiveType: .triangles,
                                               primitiveCount: idx.count / 3, bytesPerIndex: 4))
            materials.append(material(for: rgba))
        }
        if !elements.isEmpty {
            let geometry = SCNGeometry(sources: [source], elements: elements)
            geometry.materials = materials
            root.addChildNode(SCNNode(geometry: geometry))
        }

        // --- Limites do modelo (plate vazio: enquadra a mesa)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for p in pos { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        if pos.isEmpty {
            let b = model.bed ?? CGRect(x: 0, y: 0, width: 256, height: 256)
            lo = SIMD3(Float(b.minX), 0, -Float(b.maxY))
            hi = SIMD3(Float(b.maxX), 1, -Float(b.minY))
        }
        let center = (lo + hi) * 0.5

        // --- Plate
        addBed(to: root, bed: model.bed, modelMin: lo, modelMax: hi)

        // --- Luzes
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 380
        ambient.light!.color = NSColor(white: 1, alpha: 1)
        root.addChildNode(ambient)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light!.type = .directional
        sun.light!.intensity = 650
        sun.eulerAngles = SCNVector3(-1.0, -0.6, 0)
        root.addChildNode(sun)

        // --- Câmera (com luz "de cabeça" para o modelo sempre ficar legível)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera!.fieldOfView = 30
        cam.camera!.automaticallyAdjustsZRange = true
        let head = SCNLight()
        head.type = .directional
        head.intensity = 420
        let headNode = SCNNode()
        headNode.light = head
        headNode.eulerAngles = SCNVector3(-0.25, 0.3, 0)
        cam.addChildNode(headNode)
        root.addChildNode(cam)

        let target = SCNVector3(center.x, center.y, center.z)
        frame(camera: cam, min: lo, max: hi)

        scene.background.contents = backgroundImage()
        return Result(scene: scene, camera: cam, target: target, boundsMin: lo, boundsMax: hi)
    }

    /// Enquadra o modelo visto da frente-esquerda e de cima (mesmo ângulo das miniaturas do Bambu Studio),
    /// afastando a câmera só o necessário para que os 8 cantos da caixa delimitadora caibam na imagem.
    static func frame(camera cam: SCNNode, min lo: SIMD3<Float>, max hi: SIMD3<Float>) {
        let center = (lo + hi) * 0.5
        let dir = simd_normalize(SIMD3<Float>(-1, 1.1, 1))           // da câmera para fora do alvo
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), dir))
        let up = simd_cross(dir, right)
        let t = tan(Float(cam.camera?.fieldOfView ?? 30) * .pi / 360)  // campo vertical; imagem quadrada
        var dist: Float = 1
        for i in 0..<8 {
            let c = SIMD3<Float>(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
            let p = c - center
            let depthOffset = simd_dot(p, dir)
            dist = max(dist, abs(simd_dot(p, right)) / t + depthOffset, abs(simd_dot(p, up)) / t + depthOffset)
        }
        cam.simdPosition = center + dir * dist * 1.12
        cam.simdLook(at: center, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
    }

    private static func material(for rgba: RGBA) -> SCNMaterial {
        var r = CGFloat((rgba >> 24) & 0xFF) / 255
        var g = CGFloat((rgba >> 16) & 0xFF) / 255
        var b = CGFloat((rgba >> 8) & 0xFF) / 255
        // Clareia levemente cores muito escuras para que a forma continue visível.
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if lum < 0.12 { let k = 0.12 - lum; r += k; g += k; b += k }
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        m.specular.contents = NSColor(white: 0.22, alpha: 1)
        m.shininess = 0.35
        m.isDoubleSided = true
        m.shaderModifiers = [.surface: flatShading]
        return m
    }

    private static func addBed(to root: SCNNode, bed: CGRect?, modelMin lo: SIMD3<Float>, modelMax hi: SIMD3<Float>) {
        // Em coordenadas de cena: x = x, z = -y(3MF).
        var rect: CGRect
        if let bed {
            rect = bed
        } else {
            // Sem informação de mesa: usa um retângulo em volta do modelo.
            let pad: Float = max(hi.x - lo.x, hi.z - lo.z) * 0.25 + 10
            rect = CGRect(x: CGFloat(lo.x - pad), y: CGFloat(-hi.z - pad),
                          width: CGFloat(hi.x - lo.x + 2 * pad), height: CGFloat(hi.z - lo.z + 2 * pad))
        }
        let w = Float(rect.width), d = Float(rect.height)
        let cx = Float(rect.midX), cy = Float(rect.midY)
        let thickness: Float = 1.2

        let box = SCNBox(width: CGFloat(w), height: CGFloat(thickness), length: CGFloat(d), chamferRadius: 2)
        let mat = SCNMaterial()
        mat.lightingModel = .lambert
        mat.diffuse.contents = NSColor(srgbRed: 0.33, green: 0.34, blue: 0.37, alpha: 1)
        box.materials = [mat]
        let plate = SCNNode(geometry: box)
        plate.simdPosition = SIMD3(cx, -thickness / 2 - 0.02, -cy)
        root.addChildNode(plate)

        // Grade de 10 mm
        var verts: [SIMD3<Float>] = []
        let y: Float = 0.01
        let step: Float = 10
        var x = Float(rect.minX)
        while x <= Float(rect.maxX) + 0.001 {
            verts.append(SIMD3(x, y, -Float(rect.minY))); verts.append(SIMD3(x, y, -Float(rect.maxY)))
            x += step
        }
        var yy = Float(rect.minY)
        while yy <= Float(rect.maxY) + 0.001 {
            verts.append(SIMD3(Float(rect.minX), y, -yy)); verts.append(SIMD3(Float(rect.maxX), y, -yy))
            yy += step
        }
        let src = SCNGeometrySource(vertices: verts.map { SCNVector3($0.x, $0.y, $0.z) })
        let idx = (0..<UInt32(verts.count)).map { $0 }
        let el = SCNGeometryElement(indices: idx, primitiveType: .line)
        let grid = SCNGeometry(sources: [src], elements: [el])
        let gm = SCNMaterial()
        gm.lightingModel = .constant
        gm.diffuse.contents = NSColor(white: 0.52, alpha: 1)
        grid.materials = [gm]
        root.addChildNode(SCNNode(geometry: grid))
    }

    private static func backgroundImage() -> NSImage {
        let size = NSSize(width: 8, height: 256)
        let img = NSImage(size: size)
        img.lockFocus()
        NSGradient(starting: NSColor(srgbRed: 0.86, green: 0.87, blue: 0.90, alpha: 1),
                   ending: NSColor(srgbRed: 0.62, green: 0.64, blue: 0.68, alpha: 1))?
            .draw(in: NSRect(origin: .zero, size: size), angle: -90)
        img.unlockFocus()
        return img
    }

    /// Renderiza a cena fora da tela (usado pelo modo de linha de comando).
    static func snapshot(_ result: Result, size: CGSize) -> NSImage {
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = result.scene
        renderer.pointOfView = result.camera
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }
}
