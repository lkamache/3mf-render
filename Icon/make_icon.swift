// Gera o ícone do app: swift Icon/make_icon.swift <saida.png>
// Desenha um cubo isométrico "impresso" (com linhas de camada) sobre uma mesa com grade.
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// --- Fundo: quadrado arredondado no grid padrão do macOS (824 px em 1024, raio ~185)
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(bgPath); ctx.setFillColor(rgb(30, 34, 44)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bgPath); ctx.clip()
let bgGrad = CGGradient(colorsSpace: nil, colors: [rgb(58, 66, 86), rgb(22, 25, 34)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: bgRect.maxY), end: CGPoint(x: 0, y: bgRect.minY), options: [])
// brilho suave no topo
let glow = CGGradient(colorsSpace: nil, colors: [rgb(120, 170, 255, 0.28), rgb(120, 170, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 760), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 760), endRadius: 460, options: [])

// --- Projeção isométrica (y para cima no CoreGraphics)
let c30 = cos(CGFloat.pi / 6), s30: CGFloat = 0.5
let unit: CGFloat = 228
let origin = CGPoint(x: 512, y: 420)
func iso(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
    CGPoint(x: origin.x + (x - y) * c30 * unit, y: origin.y + (z - (x + y) * s30) * unit)
}
func poly(_ pts: [CGPoint]) -> CGPath {
    let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p
}

// --- Mesa (plate) com espessura e grade
let h: CGFloat = 0.95, t: CGFloat = 0.08
let top = [iso(-h, -h, 0), iso(h, -h, 0), iso(h, h, 0), iso(-h, h, 0)]
ctx.addPath(poly([iso(h, -h, 0), iso(h, h, 0), iso(h, h, -t), iso(h, -h, -t)]))
ctx.setFillColor(rgb(52, 56, 66)); ctx.fillPath()
ctx.addPath(poly([iso(-h, h, 0), iso(h, h, 0), iso(h, h, -t), iso(-h, h, -t)]))
ctx.setFillColor(rgb(40, 43, 51)); ctx.fillPath()

ctx.saveGState()
ctx.addPath(poly(top)); ctx.clip()
let plateGrad = CGGradient(colorsSpace: nil, colors: [rgb(104, 110, 124), rgb(78, 83, 96)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(plateGrad, start: iso(-h, -h, 0), end: iso(h, h, 0), options: [])
ctx.setStrokeColor(rgb(150, 156, 170, 0.55)); ctx.setLineWidth(2.5)
let n = 8
for i in 1..<n {
    let v = -h + 2 * h * CGFloat(i) / CGFloat(n)
    ctx.move(to: iso(v, -h, 0)); ctx.addLine(to: iso(v, h, 0))
    ctx.move(to: iso(-h, v, 0)); ctx.addLine(to: iso(h, v, 0))
}
ctx.strokePath()
ctx.restoreGState()

// --- Sombra do cubo na mesa
let a: CGFloat = 0.5, H: CGFloat = 1.0
ctx.saveGState()
ctx.addPath(poly(top)); ctx.clip()
let sc = iso(0.12, 0.12, 0)
ctx.translateBy(x: sc.x, y: sc.y); ctx.scaleBy(x: 1, y: 0.58)
let shadow = CGGradient(colorsSpace: nil, colors: [rgb(0, 0, 0, 0.55), rgb(0, 0, 0, 0)] as CFArray, locations: [0.35, 1])!
ctx.drawRadialGradient(shadow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: unit * 1.05, options: [])
ctx.restoreGState()

// --- Cubo "impresso" (verde filamento), faces visíveis: topo, +x, +y
let green = (top: rgb(122, 230, 120), right: rgb(64, 180, 78), left: rgb(40, 134, 60))
let faceRight = [iso(a, -a, 0), iso(a, a, 0), iso(a, a, H), iso(a, -a, H)]
let faceLeft = [iso(-a, a, 0), iso(a, a, 0), iso(a, a, H), iso(-a, a, H)]
let faceTop = [iso(-a, -a, H), iso(a, -a, H), iso(a, a, H), iso(-a, a, H)]

ctx.addPath(poly(faceRight)); ctx.setFillColor(green.right); ctx.fillPath()
ctx.addPath(poly(faceLeft)); ctx.setFillColor(green.left); ctx.fillPath()

// linhas de camada nas laterais
let layers = 14
ctx.setLineWidth(3)
for i in 1..<layers {
    let z = H * CGFloat(i) / CGFloat(layers)
    ctx.setStrokeColor(rgb(0, 60, 20, 0.28))
    ctx.move(to: iso(a, -a, z)); ctx.addLine(to: iso(a, a, z))
    ctx.move(to: iso(-a, a, z)); ctx.addLine(to: iso(a, a, z))
    ctx.strokePath()
}

// topo com leve gradiente
ctx.saveGState()
ctx.addPath(poly(faceTop)); ctx.clip()
let topGrad = CGGradient(colorsSpace: nil, colors: [rgb(160, 245, 150), green.top] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(topGrad, start: iso(-a, -a, H), end: iso(a, a, H), options: [])
ctx.restoreGState()

// arestas destacadas
ctx.setLineJoin(.round)
ctx.setStrokeColor(rgb(200, 255, 190, 0.85)); ctx.setLineWidth(4)
ctx.move(to: iso(-a, a, H)); ctx.addLine(to: iso(a, a, H)); ctx.addLine(to: iso(a, -a, H))
ctx.move(to: iso(a, a, H)); ctx.addLine(to: iso(a, a, 0))
ctx.strokePath()

ctx.restoreGState()

// borda sutil do ícone
ctx.addPath(bgPath); ctx.setStrokeColor(rgb(255, 255, 255, 0.10)); ctx.setLineWidth(3); ctx.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("OK: \(out)")
