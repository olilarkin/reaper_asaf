// SwiftUI editors for the ASAF CLAP plug-ins.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

struct ParamVM: Identifiable {
    let id: Int
    let ident: String
    let name: String
    let group: String
    let range: ClosedRange<Double>
    let stepped: Bool
    let readOnly: Bool
    let labels: [String]
    var isToggle: Bool { stepped && range.upperBound - range.lowerBound <= 1 && (labels.isEmpty || labels == ["Off", "On"]) }
    /// A named choice ("Binaural", "Stereo", ...) rather than a plain number.
    var isChoice: Bool { !labels.isEmpty && !isToggle && labels.contains { Double($0) == nil } }
}

final class UnitModel: ObservableObject {
    let bridge: ASAFUnitBridge
    let params: [ParamVM]
    @Published var values: [Double]
    @Published var puckRGB: Int
    private var timer: Timer?
    private var editing = Set<Int>()

    init(bridge: ASAFUnitBridge) {
        self.bridge = bridge
        params = bridge.parameters.enumerated().map { i, p in
            ParamVM(id: i, ident: p.ident, name: p.name, group: p.group,
                    range: p.minValue...max(p.maxValue, p.minValue + 1e-9), stepped: p.stepped, readOnly: p.readOnly, labels: p.labels)
        }
        values = (0..<bridge.parameters.count).map { bridge.value(at: $0) }
        puckRGB = bridge.puckRGB
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    deinit { timer?.invalidate() }

    private func refresh() {
        var fresh = values
        var changed = false
        for i in fresh.indices where !editing.contains(i) {
            let v = bridge.value(at: i)
            if v != fresh[i] { fresh[i] = v; changed = true }
        }
        if changed { values = fresh }
        let rgb = bridge.puckRGB
        if rgb != puckRGB { puckRGB = rgb }
    }

    var puckColor: Color {
        Color(red: Double((puckRGB >> 16) & 0xff) / 255, green: Double((puckRGB >> 8) & 0xff) / 255, blue: Double(puckRGB & 0xff) / 255)
    }

    func index(_ ident: String) -> Int? { let i = bridge.index(of: ident); return i >= 0 ? i : nil }
    func value(_ ident: String) -> Double { index(ident).map { values[$0] } ?? 0 }

    func begin(_ i: Int) { if editing.insert(i).inserted { bridge.beginGesture(i) } }
    func end(_ i: Int) { if editing.remove(i) != nil { bridge.endGesture(i) } }
    func set(_ i: Int, _ v: Double) {
        let p = params[i]
        let c = min(p.range.upperBound, max(p.range.lowerBound, p.stepped ? v.rounded() : v))
        values[i] = c
        bridge.setValue(c, at: i)
    }
    /// One-shot change (toggle, menu): wraps the value in a gesture so hosts record it.
    func commit(_ i: Int, _ v: Double) { bridge.beginGesture(i); set(i, v); bridge.endGesture(i) }
}

// MARK: - Generic parameter rows

struct ParamRow: View {
    @ObservedObject var model: UnitModel
    let p: ParamVM
    var label: String? = nil
    var unit: String = ""

    var body: some View {
        let v = model.values[p.id]
        HStack(spacing: 8) {
            Text(label ?? p.name).lineLimit(1).frame(width: 150, alignment: .leading)
            if p.readOnly {
                ProgressView(value: min(max(v, p.range.lowerBound), p.range.upperBound) - p.range.lowerBound, total: p.range.upperBound - p.range.lowerBound)
                Text(text(v)).monospacedDigit().lineLimit(1).frame(width: 96, alignment: .trailing)
            } else if p.isToggle {
                Toggle("", isOn: Binding(get: { v >= 0.5 }, set: { model.commit(p.id, $0 ? p.range.upperBound : p.range.lowerBound) })).labelsHidden()
                Spacer()
            } else if p.isChoice {
                Picker("", selection: Binding(get: { Int((v - p.range.lowerBound).rounded()) }, set: { model.commit(p.id, p.range.lowerBound + Double($0)) })) {
                    ForEach(Array(p.labels.enumerated()), id: \.offset) { i, name in Text(name).tag(i) }
                }
                .labelsHidden()
                Spacer(minLength: 0)
            } else if !p.stepped && p.range.lowerBound < 0 && p.range.upperBound > 0 {
                BipolarSlider(value: v, range: p.range, onChange: { model.set(p.id, $0) },
                              onEditing: { if $0 { model.begin(p.id) } else { model.end(p.id) } })
                Text(text(v)).monospacedDigit().frame(width: 64, alignment: .trailing)
            } else {
                Slider(value: Binding(get: { v }, set: { model.set(p.id, $0) }), in: p.range) { editing in
                    if editing { model.begin(p.id) } else { model.end(p.id) }
                }
                Text(text(v)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
        }
        .font(.callout)
    }

    private func text(_ v: Double) -> String {
        let k = Int((v - p.range.lowerBound).rounded())
        if p.stepped, k >= 0, k < p.labels.count { return p.labels[k] + unit }
        return (p.stepped ? String(Int(v.rounded())) : String(format: abs(p.range.upperBound) >= 50 ? "%.0f" : "%.2f", v)) + unit
    }
}

/// A slider whose filled track grows from zero (wherever that sits in the range) towards the thumb, so
/// values either side of zero read as left/right or up/down.
struct BipolarSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let onChange: (Double) -> Void
    let onEditing: (Bool) -> Void
    @State private var dragging = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = 20, w = max(1, geo.size.width - knob)
            let span = range.upperBound - range.lowerBound
            let x = { (v: Double) -> CGFloat in knob / 2 + w * CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span) }
            let zero = x(0), pos = x(value), mid = geo.size.height / 2
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.primary.opacity(0.14)).frame(width: geo.size.width, height: 4).offset(y: mid - 2)
                Capsule().fill(Color.accentColor).frame(width: max(0, abs(pos - zero)), height: 4).offset(x: min(pos, zero), y: mid - 2)
                Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1, height: 10).offset(x: zero - 0.5, y: mid - 5)
                Circle().fill(scheme == .dark ? Color(white: 0.58) : Color.white) // opaque, like the system slider's knob
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: knob, height: knob).offset(x: pos - knob / 2, y: mid - knob / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging { dragging = true; onEditing(true) }
                    let t = Double(min(max((g.location.x - knob / 2) / w, 0), 1))
                    onChange(range.lowerBound + t * span)
                }
                .onEnded { _ in dragging = false; onEditing(false) })
        }
        .frame(height: 22)
    }
}

struct ParamList: View {
    @ObservedObject var model: UnitModel
    var exclude: Set<String> = []

    var body: some View {
        let shown = model.params.filter { !exclude.contains($0.ident) }
        var order: [String] = []
        var groups: [String: [ParamVM]] = [:]
        for p in shown {
            if groups[p.group] == nil { order.append(p.group) }
            groups[p.group, default: []].append(p)
        }
        return LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(order, id: \.self) { g in
                if g.isEmpty {
                    ForEach(groups[g] ?? []) { ParamRow(model: model, p: $0) }
                } else {
                    DisclosureGroup(g) {
                        VStack(alignment: .leading, spacing: 6) { ForEach(groups[g] ?? []) { ParamRow(model: model, p: $0) } }.padding(.top, 4)
                    }
                    .font(.callout.weight(.medium))
                }
            }
        }
    }
}

struct Header: View {
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            Text(subtitle).font(.caption).foregroundColor(.secondary)
        }
    }
}

struct GenericEditor: View {
    @ObservedObject var model: UnitModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Header(title: model.bridge.unitName, subtitle: "Apple Spatial Audio Format")
            if model.params.isEmpty {
                Text("This version of Apple's \(model.bridge.unitName) isn't recognised, so its controls aren't available. Audio still passes through it.")
                    .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                ScrollView { ParamList(model: model).padding(.trailing, 6) }
            }
        }
        .padding(14)
    }
}

// MARK: - ASAF Object

/// Top-down view with one draggable puck: azimuth (positive = left) and distance.
struct ObjectStage: View {
    @ObservedObject var model: UnitModel
    @Binding var radius: Double
    let az: Int, el: Int, dist: Int

    var body: some View {
        GeometryReader { geo in
            let side: CGFloat = min(geo.size.width, geo.size.height)
            let centre = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let reach: CGFloat = side / 2 - 20                 // stage radius in points
            let scale: CGFloat = reach / CGFloat(radius)       // points per metre
            let a: Double = model.values[az] * Double.pi / 180
            let e: Double = model.values[el] * Double.pi / 180
            let h: Double = model.values[dist] * cos(e)
            let px: Double = -sin(a) * h, py: Double = cos(a) * h
            let ph: Double = (px * px + py * py).squareRoot()
            let onStage = ph <= radius
            let sx: Double = onStage ? px : px / ph * radius, sy: Double = onStage ? py : py / ph * radius
            ZStack {
                Canvas { ctx, _ in
                    let step: Double = radius <= 2 ? 0.5 : (radius <= 5 ? 1.0 : 2.0)
                    var r: Double = step
                    while r <= radius + 1e-9 {
                        let whole = abs(r.rounded() - r) < 1e-9
                        let rr: CGFloat = CGFloat(r) * scale
                        ctx.stroke(Path(ellipseIn: CGRect(x: centre.x - rr, y: centre.y - rr, width: 2 * rr, height: 2 * rr)),
                                   with: .color(.secondary.opacity(whole ? 0.45 : 0.2)), lineWidth: 1)
                        r += step
                    }
                    var axes = Path()
                    axes.move(to: CGPoint(x: centre.x - reach, y: centre.y)); axes.addLine(to: CGPoint(x: centre.x + reach, y: centre.y))
                    axes.move(to: CGPoint(x: centre.x, y: centre.y - reach)); axes.addLine(to: CGPoint(x: centre.x, y: centre.y + reach))
                    ctx.stroke(axes, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                    let marks: [(String, CGFloat, CGFloat)] = [("Front", 0, -1), ("Back", 0, 1), ("L", -1, 0), ("R", 1, 0)]
                    for (label, dx, dy) in marks {
                        ctx.draw(Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary),
                                 at: CGPoint(x: centre.x + dx * (reach + 11), y: centre.y + dy * (reach + 10)))
                    }
                    var head = Path(ellipseIn: CGRect(x: centre.x - 7, y: centre.y - 7, width: 14, height: 14))
                    head.move(to: CGPoint(x: centre.x - 4, y: centre.y - 6)); head.addLine(to: CGPoint(x: centre.x, y: centre.y - 12)); head.addLine(to: CGPoint(x: centre.x + 4, y: centre.y - 6))
                    ctx.stroke(head, with: .color(.primary.opacity(0.7)), lineWidth: 1.5)
                }
                let size: CGFloat = CGFloat(24 + 8 * model.values[el] / 90)
                Circle().fill(model.puckColor.opacity(onStage ? 0.95 : 0.5))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.8), lineWidth: 2))
                    .frame(width: size, height: size)
                    .position(x: centre.x + CGFloat(sx) * scale, y: centre.y - CGFloat(sy) * scale)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    model.begin(az); model.begin(dist)
                    let x: Double = Double((g.location.x - centre.x) / scale), y: Double = Double((centre.y - g.location.y) / scale)
                    let hd: Double = (x * x + y * y).squareRoot()
                    if hd > 1e-6 { model.set(az, atan2(-x, y) * 180 / Double.pi) }
                    model.set(dist, hd / max(0.05, cos(model.values[el] * Double.pi / 180)))
                }
                .onEnded { _ in model.end(az); model.end(dist) })
        }
    }
}

struct ObjectEditor: View {
    @ObservedObject var model: UnitModel
    @State private var radius = 2.0
    @State private var showAll = false

    var body: some View {
        if let az = model.index("azimuth"), let el = model.index("elevation"), let dist = model.index("r") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("ASAF Object").font(.title3.weight(.semibold))
                    if let i = model.index("index") { Text("#\(Int(model.values[i]) + 1)").font(.title3).foregroundColor(.secondary) }
                    Spacer()
                    Picker("", selection: $radius) { Text("1 m").tag(1.0); Text("2 m").tag(2.0); Text("5 m").tag(5.0); Text("10 m").tag(10.0) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                }
                ObjectStage(model: model, radius: $radius, az: az, el: el, dist: dist).frame(minHeight: 230)
                ParamRow(model: model, p: model.params[az], unit: "°")
                ParamRow(model: model, p: model.params[el], unit: "°")
                ParamRow(model: model, p: model.params[dist], unit: " m")
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(["index", "playbackEnabled", "size", "width", "height", "headlock", "reverb", "reverbMix"], id: \.self) { ident in
                            if let i = model.index(ident) { ParamRow(model: model, p: model.params[i]) }
                        }
                        DisclosureGroup("All parameters", isExpanded: $showAll) {
                            ParamList(model: model, exclude: ["azimuth", "elevation", "r", "index", "playbackEnabled", "size", "width", "height", "headlock", "reverb", "reverbMix"])
                                .padding(.top, 4)
                        }
                        .font(.callout.weight(.medium))
                    }
                    .padding(.trailing, 6)
                }
            }
            .padding(14)
        } else {
            GenericEditor(model: model)
        }
    }
}

// MARK: - ASAF Export

struct ExportEditor: View {
    @ObservedObject var model: UnitModel
    @State private var createAPAC = true
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Header(title: "ASAF Export", subtitle: "Apple Spatial Audio Format")
            if model.params.isEmpty {
                Text("This version of Apple's ASAF Export isn't recognised, so its controls aren't available.").foregroundColor(.secondary)
            } else {
                if let i = model.index("bounceArmed") { ParamRow(model: model, p: model.params[i], label: "Bounce armed") }
                if let i = model.index("autoDisarm") { ParamRow(model: model, p: model.params[i], label: "Disarm after bounce") }
                Text("While armed, the 8 outputs carry ASAF metadata. Bounce them after the object channels (48 kHz, 1024-sample blocks).")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                ForEach([("loudness", "Loudness"), ("loudnessAverage", "Average"), ("loudnessPeak", "Peak")], id: \.0) { ident, label in
                    if let i = model.index(ident) { ParamRow(model: model, p: model.params[i], label: label, unit: " LKFS") }
                }
                Divider()
                HStack {
                    Button(busy ? "Converting…" : "Convert Bounced File…") { chooseAndConvert() }.disabled(busy)
                    Toggle("Also create APAC (.mp4)", isOn: $createAPAC)
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func chooseAndConvert() {
        let panel = NSOpenPanel()
        panel.title = "Select the bounced file to convert"
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; status = "Converting \(url.lastPathComponent)…"
        let apac = createAPAC
        DispatchQueue.main.async {
            let message = model.bridge.convertFile(url.path, createAPAC: apac)
            busy = false
            status = message ?? "Converted \(url.lastPathComponent) to ASAF BWF" + (apac ? " and APAC." : ".")
        }
    }
}

// MARK: - Entry point

struct RootView: View {
    @ObservedObject var model: UnitModel
    var body: some View {
        Group {
            switch model.bridge.kind {
            case "Objt": ObjectEditor(model: model)
            case "Expt": ExportEditor(model: model)
            default: GenericEditor(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@objc(ASAFClapUIFactory) public final class ASAFClapUIFactory: NSObject {
    @objc public static func makeView(bridge: ASAFUnitBridge) -> NSView {
        let host = NSHostingView(rootView: RootView(model: UnitModel(bridge: bridge)))
        host.autoresizingMask = [.width, .height]
        return host
    }
}
