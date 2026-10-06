import AppKit
import SceneKit
import simd

/// SCNView em que o scroll (roda do mouse ou dois dedos no trackpad) faz zoom em direção ao ponto
/// sob o cursor, como no Bambu Studio. Girar (arrastar) e pinça continuam com o controle padrão.
final class ZoomSceneView: SCNView {
    /// Distância mínima/máxima entre a câmera e o alvo da órbita (mm).
    var zoomLimits: ClosedRange<Float> = 1...10_000

    /// Ajusta os limites a partir da distância do enquadramento inicial.
    func resetZoomLimits() {
        guard let cam = pointOfView else { return }
        let d = simd_length(cam.simdWorldPosition - SIMD3<Float>(defaultCameraController.target))
        zoomLimits = max(0.5, d * 0.02)...max(1, d * 8)
    }

    override func scrollWheel(with event: NSEvent) {
        guard allowsCameraControl, scene != nil, pointOfView != nil else {
            return super.scrollWheel(with: event)
        }
        // Direção física do dispositivo: rodar para baixo / dedos para baixo aproxima,
        // independentemente da "rolagem natural" do macOS.
        var dy = -event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { dy = -dy }
        guard dy != 0 else { return }
        // Roda do mouse manda "linhas" (≈1 por clique); trackpad e Magic Mouse mandam pixels.
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.006 : 0.12
        zoom(by: Float(exp(-dy * sensitivity)), at: convert(event.locationInWindow, from: nil))
    }

    /// factor < 1 aproxima, > 1 afasta. `point` em coordenadas desta view.
    func zoom(by factor: Float, at point: CGPoint) {
        guard let cam = pointOfView else { return }
        let ctrl = defaultCameraController
        let target = SIMD3<Float>(ctrl.target)
        let eye = cam.simdWorldPosition
        let dist = simd_length(target - eye)
        guard dist > 0 else { return }

        // Mantém a distância dentro dos limites.
        let newDist = min(max(dist * factor, zoomLimits.lowerBound), zoomLimits.upperBound)
        let f = newDist / dist
        guard abs(f - 1) > 1e-5 else { return }

        // Ponto de ancoragem: onde o raio do cursor cruza o plano do alvo (perpendicular à visão).
        // Mais barato que um hit test na malha, que pode ter milhões de triângulos.
        var anchor = target
        let near = SIMD3<Float>(unprojectPoint(SCNVector3(point.x, point.y, 0)))
        let far = SIMD3<Float>(unprojectPoint(SCNVector3(point.x, point.y, 1)))
        let ray = far - near
        let viewDir = (target - eye) / dist
        let denom = simd_dot(ray, viewDir)
        if simd_length(ray) > 0, abs(denom) > 1e-6 {
            let t = simd_dot(target - near, viewDir) / denom
            if t > 0 { anchor = near + ray * t }
        }

        // Escala câmera e alvo em torno da âncora: o ponto sob o cursor fica parado na tela.
        cam.simdWorldPosition = anchor + (eye - anchor) * f
        ctrl.target = SCNVector3(anchor + (target - anchor) * f)
    }
}
