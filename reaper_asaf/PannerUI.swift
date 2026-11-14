// ASAF panner window: a top-down view of every ASAF Object in the project.
import SwiftUI
import AppKit

struct PanObject: Identifiable, Equatable {
    var id: Int
    var name: String
    var index: Int
    var azimuth: Double     // degrees, + = left
    var elevation: Double   // degrees, + = up
    var distance: Double    // metres
    var enabled: Bool
    var color: Color

    /// Position on the horizontal plane in metres: x = right, y = front.
    var plan: CGPoint {
        let az: Double = azimuth * Double.pi / 180, el: Double = elevation * Double.pi / 180
        let h: Double = distance * cos(el)
        return CGPoint(x: CGFloat(-sin(az) * h), y: CGFloat(cos(az) * h))
    }
}

// Used when a track has no colour of its own. Same colours as asaf::paletteColor() in asaf_clap/unit.mm.
private let palette: [Color] = [0xF09632, 0x40C8BE, 0xF0648C, 0xF0CD3C, 0x78DCAA, 0xAA78E6, 0x5ABEF0, 0xEB554B, 0x6EC85A, 0x6E78E6].map {
    Color(red: Double(($0 >> 16) & 0xff) / 255, green: Double(($0 >> 8) & 0xff) / 255, blue: Double($0 & 0xff) / 255)
}

final class PannerModel: ObservableObject {
    @Published var objects: [PanObject] = []
    @Published var selection: Int?
    @Published var viewRadius: Double = 2      // metres shown from centre to edge
    let bridge: ASAFPannerBridge
    private var timer: Timer?
    private var editing: Int?                  // object being dragged: don't overwrite it from the host

    init(bridge: ASAFPannerBridge) {
        self.bridge = bridge
        refresh()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    deinit { timer?.invalidate() }

    func refresh() {
        var fresh = bridge.snapshot().map { s in
            PanObject(id: s.ident, name: s.name, index: s.objectIndex, azimuth: s.azimuth, elevation: s.elevation,
                      distance: s.distance, enabled: s.enabled,
                      color: s.hasColor ? Color(red: s.red, green: s.green, blue: s.blue) : palette[abs(s.objectIndex) % palette.count])
        }
        if let e = editing, let i = fresh.firstIndex(where: { $0.id == e }), let mine = objects.first(where: { $0.id == e }) {
            fresh[i].azimuth = mine.azimuth; fresh[i].elevation = mine.elevation; fresh[i].distance = mine.distance
        }
        if fresh != objects { objects = fresh }
        if let s = selection, !fresh.contains(where: { $0.id == s }) { selection = nil }
    }

    var selected: PanObject? { objects.first { $0.id == selection } }

    func begin(_ id: Int) {
        guard editing != id else { return }
        editing = id
        if selection != id { selection = id; bridge.selectTrack(id) }
        bridge.beginEdit(id)
    }

    func set(_ id: Int, azimuth: Double? = nil, elevation: Double? = nil, distance: Double? = nil) {
        guard let i = objects.firstIndex(where: { $0.id == id }) else { return }
        var o = objects[i]
        if let a = azimuth { o.azimuth = min(180, max(-180, a)) }
        if let e = elevation { o.elevation = min(90, max(-90, e)) }
        if let d = distance { o.distance = min(10, max(0, d)) }
        objects[i] = o
        bridge.setAzimuth(o.azimuth, elevation: o.elevation, distance: o.distance, forObject: id)
    }

    /// Move an object to a point on the horizontal plane (metres), keeping its elevation.
    func move(_ id: Int, toPlan p: CGPoint) {
        guard let o = objects.first(where: { $0.id == id }) else { return }
        let x = Double(p.x), y = Double(p.y)
        let h: Double = (x * x + y * y).squareRoot()
        let az: Double = h < 1e-6 ? o.azimuth : atan2(-x, y) * 180 / Double.pi
        let c: Double = max(0.05, cos(o.elevation * Double.pi / 180))
        set(id, azimuth: az, distance: h / c)
    }

    func end(_ id: Int) {
        guard editing == id else { return }
        editing = nil
        bridge.endEdit(id)
    }
}

/// Top-down view: listener at the centre facing up, rings every metre (or half metre when zoomed in).
struct StageView: View {
    @ObservedObject var model: PannerModel

    var body: some View {
        GeometryReader { geo in
            let side: CGFloat = min(geo.size.width, geo.size.height)
            let centre = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let reach: CGFloat = side / 2 - 22                          // stage radius in points
            let scale: CGFloat = reach / CGFloat(model.viewRadius)      // points per metre
            ZStack {
                Canvas { ctx, _ in
                    let radius: Double = model.viewRadius
                    let step: Double = radius <= 2 ? 0.5 : (radius <= 5 ? 1.0 : 2.0)
                    var r: Double = step
                    while r <= radius + 1e-9 {
                        let rr: CGFloat = CGFloat(r) * scale
                        let whole = abs(r.rounded() - r) < 1e-9
                        ctx.stroke(Path(ellipseIn: CGRect(x: centre.x - rr, y: centre.y - rr, width: 2 * rr, height: 2 * rr)),
                                   with: .color(.secondary.opacity(whole ? 0.45 : 0.2)), lineWidth: 1)
                        if whole {
                            ctx.draw(Text("\(Int(r)) m").font(.system(size: 9)).foregroundColor(.secondary),
                                     at: CGPoint(x: centre.x + rr * 0.707 + 10, y: centre.y + rr * 0.707 + 6))
                        }
                        r += step
                    }
                    var axes = Path()
                    axes.move(to: CGPoint(x: centre.x - reach, y: centre.y)); axes.addLine(to: CGPoint(x: centre.x + reach, y: centre.y))
                    axes.move(to: CGPoint(x: centre.x, y: centre.y - reach)); axes.addLine(to: CGPoint(x: centre.x, y: centre.y + reach))
                    ctx.stroke(axes, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                    let marks: [(String, CGFloat, CGFloat)] = [("Front", 0, -1), ("Back", 0, 1), ("L", -1, 0), ("R", 1, 0)]
                    for (label, dx, dy) in marks {
                        ctx.draw(Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary),
                                 at: CGPoint(x: centre.x + dx * (reach + 12), y: centre.y + dy * (reach + 11)))
                    }
                    // listener
                    var head = Path(ellipseIn: CGRect(x: centre.x - 7, y: centre.y - 7, width: 14, height: 14))
                    head.move(to: CGPoint(x: centre.x - 4, y: centre.y - 6)); head.addLine(to: CGPoint(x: centre.x, y: centre.y - 12)); head.addLine(to: CGPoint(x: centre.x + 4, y: centre.y - 6))
                    ctx.stroke(head, with: .color(.primary.opacity(0.7)), lineWidth: 1.5)
                }
                ForEach(model.objects) { o in
                    let p = o.plan
                    let clamped = clamp(p, to: CGFloat(model.viewRadius))
                    Puck(object: o, selected: model.selection == o.id, offstage: clamped != p)
                        .position(x: centre.x + clamped.x * scale, y: centre.y - clamped.y * scale)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("stage"))
                            .onChanged { g in
                                model.begin(o.id)
                                model.move(o.id, toPlan: CGPoint(x: (g.location.x - centre.x) / scale, y: (centre.y - g.location.y) / scale))
                            }
                            .onEnded { _ in model.end(o.id) })
                }
            }
            .coordinateSpace(name: "stage")
            .contentShape(Rectangle())
        }
    }

    private func clamp(_ p: CGPoint, to radius: CGFloat) -> CGPoint {
        let h: CGFloat = (p.x * p.x + p.y * p.y).squareRoot()
        return h <= radius ? p : CGPoint(x: p.x / h * radius, y: p.y / h * radius)
    }
}

struct Puck: View {
    let object: PanObject
    let selected: Bool
    let offstage: Bool

    var body: some View {
        // Higher objects are drawn larger, lower ones smaller.
        let size: CGFloat = CGFloat(22 + 8 * object.elevation / 90)
        ZStack {
            Circle().fill(object.color.opacity(object.enabled ? (offstage ? 0.45 : 0.9) : 0.25))
            Circle().strokeBorder(selected ? Color.primary : Color.black.opacity(0.35), lineWidth: selected ? 2.5 : 1)
            Text("\(object.index + 1)").font(.system(size: 10, weight: .semibold)).foregroundColor(.black.opacity(0.8))
        }
        .frame(width: size, height: size)
        .help("\(object.name)  az \(Int(object.azimuth.rounded()))°  el \(Int(object.elevation.rounded()))°  \(String(format: "%.2f", object.distance)) m")
    }
}

struct ObjectList: View {
    @ObservedObject var model: PannerModel

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { id in
            model.selection = id
            if let id { model.bridge.selectTrack(id) }
        })) {
            ForEach(model.objects) { o in
                HStack(spacing: 6) {
                    Circle().fill(o.color).frame(width: 9, height: 9)
                    Text("\(o.index + 1)").monospacedDigit().foregroundColor(.secondary).frame(width: 24, alignment: .trailing)
                    Text(o.name).lineLimit(1)
                    Spacer()
                    Text("\(Int(o.azimuth.rounded()))° / \(Int(o.elevation.rounded()))°").monospacedDigit().font(.caption).foregroundColor(.secondary)
                }
                .opacity(o.enabled ? 1 : 0.5)
                .tag(o.id)
            }
        }
        .listStyle(.inset)
    }
}

struct Inspector: View {
    @ObservedObject var model: PannerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let o = model.selected {
                Text(o.name).font(.headline).lineLimit(1)
                row("Azimuth", value: o.azimuth, range: -180...180, unit: "°") { model.set(o.id, azimuth: $0) }
                row("Elevation", value: o.elevation, range: -90...90, unit: "°") { model.set(o.id, elevation: $0) }
                row("Distance", value: o.distance, range: 0...10, unit: " m", digits: 2) { model.set(o.id, distance: $0) }
            } else {
                Text("Select an object").foregroundColor(.secondary)
            }
        }
        .padding(10)
    }

    private func row(_ title: String, value: Double, range: ClosedRange<Double>, unit: String, digits: Int = 0,
                     set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).frame(width: 64, alignment: .leading)
            let editing = { (on: Bool) in
                guard let id = model.selection else { return }
                if on { model.begin(id) } else { model.end(id) }
            }
            if range.lowerBound < 0 && range.upperBound > 0 {
                BipolarSlider(value: value, range: range, onChange: set, onEditing: editing)
            } else {
                Slider(value: Binding(get: { value }, set: { set($0) }), in: range, onEditingChanged: editing)
            }
            Text(String(format: "%.\(digits)f", value) + unit).monospacedDigit().frame(width: 62, alignment: .trailing)
        }
        .font(.callout)
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

struct PannerView: View {
    @ObservedObject var model: PannerModel

    var body: some View {
        if model.objects.isEmpty {
            VStack(spacing: 8) {
                Text("No ASAF Object plug-ins in this project").font(.headline)
                Text("Run the action “ASAF: Set up session”, or add ASAF Object to a track.").foregroundColor(.secondary)
                DockButton(bridge: model.bridge)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                ObjectList(model: model).frame(width: 230)
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        Text("Top view").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        DockButton(bridge: model.bridge)
                        Picker("Radius", selection: $model.viewRadius) {
                            Text("1 m").tag(1.0); Text("2 m").tag(2.0); Text("5 m").tag(5.0); Text("10 m").tag(10.0)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    }
                    .padding(.horizontal, 10).padding(.top, 8)
                    StageView(model: model).frame(minWidth: 260, minHeight: 260)
                    Divider()
                    Inspector(model: model)
                }
            }
        }
    }
}

/// Moves the panner in or out of REAPER's docker.
struct DockButton: View {
    let bridge: ASAFPannerBridge

    var body: some View {
        Button { bridge.toggleDock() } label: {
            Label(bridge.docked ? "Undock" : "Dock", systemImage: bridge.docked ? "macwindow.on.rectangle" : "dock.rectangle")
        }
        .controlSize(.small)
        .help(bridge.docked ? "Float the panner in its own window" : "Move the panner into REAPER's docker")
    }
}

/// Entry point for the Objective-C++ side.
@objc(ASAFPannerUIFactory) public final class ASAFPannerUIFactory: NSObject {
    @objc public static func makeView(bridge: ASAFPannerBridge) -> NSView {
        let host = NSHostingView(rootView: PannerView(model: PannerModel(bridge: bridge)))
        host.autoresizingMask = [.width, .height]
        return host
    }
}
