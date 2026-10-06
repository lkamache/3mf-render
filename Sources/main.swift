import AppKit
import SceneKit
import UniformTypeIdentifiers

// MARK: - Modo linha de comando: 3MFRender --render entrada.3mf saida.png [tamanho] [plate]

let args = CommandLine.arguments
if args.count >= 4, args[1] == "--render" {
    do {
        let t0 = Date()
        let plate = args.count >= 6 ? Int(args[5]) ?? 1 : 1
        let model = try ThreeMFLoader.load(url: URL(fileURLWithPath: args[2]), plate: plate)
        let t1 = Date()
        let built = SceneBuilder.build(model)
        let side = args.count >= 5 ? Double(args[4]) ?? 800 : 800
        let image = SceneBuilder.snapshot(built, size: CGSize(width: side, height: side))
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { exit(2) }
        try png.write(to: URL(fileURLWithPath: args[3]))
        print(String(format: "%@: plate %d de %d, %d objeto(s), %d triângulos, parse %.2fs, total %.2fs",
                     args[2], model.plate, max(1, model.plates.count), model.objectCount, model.mesh.triangleCount,
                     t1.timeIntervalSince(t0), Date().timeIntervalSince(t0)))
        exit(0)
    } catch {
        FileHandle.standardError.write("\(args[2]): erro: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - Área de soltar arquivos

final class DropView: NSView {
    var onDrop: ((URL) -> Void)?
    private var highlighted = false { didSet { updateBorder() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func url(from info: NSDraggingInfo) -> URL? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]
        return urls?.first { $0.pathExtension.lowercased() == "3mf" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard url(from: sender) != nil else { return [] }
        highlighted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard let u = url(from: sender) else { return false }
        onDrop?(u)
        return true
    }

    private func updateBorder() {
        layer?.borderWidth = highlighted ? 3 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}

// MARK: - Controlador da janela

final class ViewerController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let dropView = DropView(frame: NSRect(x: 0, y: 0, width: 420, height: 420))
    private let sceneView = ZoomSceneView()
    private let imageView = NSImageView()
    private let hint = NSTextField(labelWithString: "Arraste um arquivo .3mf aqui")
    private let spinner = NSProgressIndicator()
    private let modeSwitch = NSSegmentedControl(labels: ["3D", "Fatiador"], trackingMode: .selectOne,
                                                target: nil, action: nil)
    private let platePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var generation = 0
    private var current: SceneBuilder.Result?
    /// Toda leitura de arquivo acontece nesta fila serial (o loader não é thread-safe).
    private let queue = DispatchQueue(label: "3mf-loader", qos: .userInitiated)
    private var loader: ThreeMFLoader?
    private(set) var plates: [PlateInfo] = []
    private(set) var currentPlate = 1
    /// Plate pedido mais recentemente (pode ainda estar carregando) — permite cliques seguidos.
    private var requestedPlate = 1
    private var rightDownLocation: NSPoint?
    private var eventMonitor: Any?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "3MF Render"
        window.minSize = NSSize(width: 240, height: 240)
        window.contentView = dropView
        window.delegate = self
        // Sempre abre no tamanho padrão (420×420, 1:1) e centralizado, ignorando o último tamanho usado.
        window.isRestorable = false
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame MainWindow")
        window.center()

        dropView.onDrop = { [weak self] in self?.open($0) }

        // Clique com o botão direito (sem arrastar) pula para o próximo plate.
        // Um monitor local pega o clique tanto na vista 3D quanto na imagem do fatiador.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseUp]) { [weak self] event in
            self?.handleRightClick(event)
            return event
        }

        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.allowsCameraControl = true
        sceneView.antialiasingMode = .multisampling4X
        sceneView.backgroundColor = NSColor(srgbRed: 0.78, green: 0.79, blue: 0.82, alpha: 1)
        sceneView.isHidden = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isEditable = false
        imageView.unregisterDraggedTypes()
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor(srgbRed: 0.78, green: 0.79, blue: 0.82, alpha: 1).cgColor
        imageView.isHidden = true

        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .systemFont(ofSize: 15, weight: .medium)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.maximumNumberOfLines = 0
        hint.lineBreakMode = .byWordWrapping

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false

        modeSwitch.translatesAutoresizingMaskIntoConstraints = false
        modeSwitch.selectedSegment = 0
        modeSwitch.controlSize = .small
        modeSwitch.target = self
        modeSwitch.action = #selector(modeChanged)
        modeSwitch.isHidden = true
        modeSwitch.toolTip = "3D: renderização própria · Fatiador: imagem do plate salva pelo Bambu Studio"

        platePopup.translatesAutoresizingMaskIntoConstraints = false
        platePopup.controlSize = .small
        platePopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        platePopup.target = self
        platePopup.action = #selector(plateChosen)
        platePopup.isHidden = true
        platePopup.toolTip = "Escolher o plate (⌘[ e ⌘] alternam; clique direito pula para o próximo)"

        for v in [sceneView, imageView, hint, spinner, modeSwitch, platePopup] as [NSView] { dropView.addSubview(v) }
        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: dropView.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: dropView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: dropView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: dropView.bottomAnchor),
            hint.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: dropView.centerYAnchor, constant: 22),
            hint.widthAnchor.constraint(lessThanOrEqualTo: dropView.widthAnchor, constant: -32),
            spinner.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: dropView.centerYAnchor, constant: -16),
            modeSwitch.trailingAnchor.constraint(equalTo: dropView.trailingAnchor, constant: -10),
            modeSwitch.bottomAnchor.constraint(equalTo: dropView.bottomAnchor, constant: -10),
            platePopup.leadingAnchor.constraint(equalTo: dropView.leadingAnchor, constant: 10),
            platePopup.centerYAnchor.constraint(equalTo: modeSwitch.centerYAnchor),
            platePopup.trailingAnchor.constraint(lessThanOrEqualTo: modeSwitch.leadingAnchor, constant: -8),
        ])
    }

    func open(_ url: URL) {
        window.title = url.lastPathComponent
        window.representedURL = url
        hint.stringValue = ""
        hint.isHidden = false
        loader = nil
        plates = []
        requestedPlate = 1
        platePopup.isHidden = true
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        load(plate: 1) { try ThreeMFLoader(url: url) }
    }

    /// Mostra outro plate do arquivo aberto, reaproveitando o que já foi lido.
    func selectPlate(_ id: Int) {
        guard let loader, id != requestedPlate, plates.contains(where: { $0.id == id }) else { return }
        requestedPlate = id
        load(plate: id) { loader }
    }

    /// Passo relativo na lista de plates (−1 anterior, +1 próximo).
    func stepPlate(_ delta: Int, wrap: Bool = false) {
        guard let i = plates.firstIndex(where: { $0.id == requestedPlate }) else { return }
        var j = i + delta
        if wrap { j = (j % plates.count + plates.count) % plates.count }
        if plates.indices.contains(j) { selectPlate(plates[j].id) }
    }

    private func handleRightClick(_ event: NSEvent) {
        guard event.window === window else { return }
        let p = event.locationInWindow
        if event.type == .rightMouseDown {
            rightDownLocation = dropView.frame.contains(dropView.superview?.convert(p, from: nil) ?? p) ? p : nil
        } else if let start = rightDownLocation {
            rightDownLocation = nil
            // Soltou quase no mesmo lugar: é um clique, não um arraste de câmera.
            if hypot(p.x - start.x, p.y - start.y) < 5, plates.count > 1 {
                stepPlate(+1, wrap: true)   // depois do último, volta ao primeiro
            }
        }
    }

    private func load(plate: Int, loader makeLoader: @escaping () throws -> ThreeMFLoader) {
        generation += 1
        let gen = generation
        window.subtitle = "Carregando…"
        spinner.startAnimation(nil)

        queue.async { [weak self] in
            let result: Result<(ThreeMFLoader, LoadedModel, SceneBuilder.Result), Error> = Result {
                let loader = try makeLoader()
                let model = try loader.load(plate: plate)
                return (loader, model, SceneBuilder.build(model))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.spinner.stopAnimation(nil)
                switch result {
                case .success(let (loader, model, built)):
                    self.loader = loader
                    self.show(model, built)
                case .failure(let error):
                    self.showError(error)
                }
            }
        }
    }

    @objc private func plateChosen() {
        selectPlate(platePopup.selectedTag())
    }

    private func updatePlatePopup() {
        platePopup.removeAllItems()
        for p in plates {
            let title = p.name.isEmpty ? "Plate \(p.id)" : "Plate \(p.id) – \(p.name)"
            platePopup.addItem(withTitle: title)
            platePopup.lastItem?.tag = p.id
        }
        platePopup.selectItem(withTag: currentPlate)
        platePopup.isHidden = plates.count < 2
    }

    private func show(_ model: LoadedModel, _ built: SceneBuilder.Result) {
        current = built
        plates = model.plates
        currentPlate = model.plate
        requestedPlate = model.plate
        updatePlatePopup()
        sceneView.scene = built.scene
        sceneView.pointOfView = built.camera
        let ctrl = sceneView.defaultCameraController
        ctrl.interactionMode = .orbitTurntable
        ctrl.target = built.target
        ctrl.worldUp = SCNVector3(0, 1, 0)
        ctrl.inertiaEnabled = true
        sceneView.resetZoomLimits()

        let tris = model.mesh.triangleCount
        let triText = tris >= 1_000_000 ? String(format: "%.1f mi", Double(tris) / 1e6)
                    : tris >= 1000 ? "\(tris / 1000) mil" : "\(tris)"
        let plateText = plates.count > 1 ? "Plate \(model.plate) de \(plates.count)" : "Plate \(model.plate)"
        window.subtitle = model.objectCount == 0 ? "\(plateText) · vazio"
            : "\(plateText) · \(model.objectCount) objeto(s) · \(triText) triângulos"

        hint.isHidden = true
        if let data = model.plateThumbnail, let img = NSImage(data: data) {
            imageView.image = img
            modeSwitch.isHidden = false
        } else {
            imageView.image = nil
            modeSwitch.isHidden = true
            modeSwitch.selectedSegment = 0
        }
        applyMode()
    }

    private func showError(_ error: Error) {
        current = nil
        sceneView.isHidden = true
        imageView.isHidden = true
        modeSwitch.isHidden = true
        platePopup.isHidden = plates.count < 2
        window.subtitle = "Erro"
        hint.stringValue = "⚠️ \(error.localizedDescription)\n\nArraste outro arquivo .3mf"
        hint.isHidden = false
    }

    @objc private func modeChanged() { applyMode() }

    private func applyMode() {
        guard current != nil else { return }
        let thumb = modeSwitch.selectedSegment == 1 && imageView.image != nil
        sceneView.isHidden = thumb
        imageView.isHidden = !thumb
    }

    @objc func resetView(_ sender: Any?) {
        guard let built = current else { return }
        built.resetCamera()
        sceneView.pointOfView = built.camera
        sceneView.defaultCameraController.target = built.target
        sceneView.resetZoomLimits()
    }

    @objc func saveImage(_ sender: Any?) {
        guard let built = current else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ((window.representedURL?.deletingPathExtension().lastPathComponent) ?? "plate") + "_plate\(currentPlate).png"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            let image: NSImage
            if self.modeSwitch.selectedSegment == 1, let img = self.imageView.image {
                image = img
            } else {
                let cam = self.sceneView.pointOfView ?? built.camera
                let r = SceneBuilder.Result(scene: built.scene, camera: cam, target: built.target,
                                            boundsMin: built.boundsMin, boundsMax: built.boundsMax)
                image = SceneBuilder.snapshot(r, size: CGSize(width: 1024, height: 1024))
            }
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
        }
    }

    func showWelcome() {
        hint.stringValue = "Arraste um arquivo .3mf aqui"
        hint.isHidden = false
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var viewer: ViewerController!
    private var pendingURL: URL?

    func applicationWillFinishLaunching(_ notification: Notification) {
        buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewer = ViewerController()
        viewer.showWelcome()
        viewer.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let u = pendingURL { viewer.open(u); pendingURL = nil }
        else if CommandLine.arguments.count >= 2, CommandLine.arguments[1].lowercased().hasSuffix(".3mf") {
            viewer.open(URL(fileURLWithPath: CommandLine.arguments[1]))
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let u = urls.first(where: { $0.pathExtension.lowercased() == "3mf" }) else { return }
        if let viewer { viewer.open(u); viewer.window.makeKeyAndOrderFront(nil) } else { pendingURL = u }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "3mf") ?? .data]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: viewer.window) { [weak self] resp in
            if resp == .OK, let u = panel.url { self?.viewer.open(u) }
        }
    }

    @objc func resetView(_ sender: Any?) { viewer.resetView(sender) }

    @objc func showAbout(_ sender: Any?) {
        // Versão, build e copyright vêm do Info.plist; os créditos mostram o desenvolvedor.
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSAttributedString(string: "Desenvolvido por Leonardo Kamache", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func previousPlate(_ sender: Any?) { viewer.stepPlate(-1) }
    @objc func nextPlate(_ sender: Any?) { viewer.stepPlate(+1) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let viewer else { return false }
        let ids = viewer.plates.map(\.id)
        switch item.action {
        case #selector(previousPlate(_:)): return ids.first.map { viewer.currentPlate > $0 } ?? false
        case #selector(nextPlate(_:)): return ids.last.map { viewer.currentPlate < $0 } ?? false
        default: return true
        }
    }
    @objc func saveImage(_ sender: Any?) { viewer.saveImage(sender) }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Sobre o 3MF Render", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ocultar 3MF Render", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Encerrar 3MF Render", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "Arquivo")
        fileMenu.addItem(withTitle: "Abrir…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Salvar Imagem…", action: #selector(saveImage(_:)), keyEquivalent: "s")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Fechar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "Visualizar")
        viewMenu.addItem(withTitle: "Redefinir Câmera", action: #selector(resetView(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Plate Anterior", action: #selector(previousPlate(_:)), keyEquivalent: "[")
        viewMenu.addItem(withTitle: "Próximo Plate", action: #selector(nextPlate(_:)), keyEquivalent: "]")
        viewItem.submenu = viewMenu

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
