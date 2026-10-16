import SwiftUI

/// Colors and sizes matched to Bartender's Top Shelf (John's reference screenshots in the WiP folder).
enum Look {
    static let cardGradient = LinearGradient(colors: [Color(white: 47 / 255), Color(white: 21 / 255)], startPoint: .top, endPoint: .bottom)
    static let dim = Color.white.opacity(0.6)
    static let faint = Color.white.opacity(0.1)
    static let green = Color(red: 0x30 / 255, green: 0xd1 / 255, blue: 0x58 / 255)
    static let orange = Color(red: 246 / 255, green: 93 / 255, blue: 46 / 255)
    static let blue = Color(red: 36 / 255, green: 169 / 255, blue: 1)
    static let button = Color(white: 25 / 255)
    static let title = Font.system(size: 13, weight: .semibold)
    static let small = Font.system(size: 11)
}

/// The black shape: flat top that flares out a little where it meets the top of the screen, round bottom corners.
struct NotchShape: Shape {
    var flare: CGFloat
    var radius: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, radius) }
        set { flare = newValue.first; radius = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, f = flare, rad = min(radius, (w - 2 * f) / 2, h)
        var p = Path()
        p.move(to: .zero)
        p.addQuadCurve(to: CGPoint(x: f, y: f), control: CGPoint(x: f, y: 0))
        p.addLine(to: CGPoint(x: f, y: h - rad))
        p.addArc(tangent1End: CGPoint(x: f, y: h), tangent2End: CGPoint(x: f + rad, y: h), radius: rad)
        p.addLine(to: CGPoint(x: w - f - rad, y: h))
        p.addArc(tangent1End: CGPoint(x: w - f, y: h), tangent2End: CGPoint(x: w - f, y: h - rad), radius: rad)
        p.addLine(to: CGPoint(x: w - f, y: f))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - f, y: 0))
        p.closeSubpath()
        return p
    }
}

struct ShelfView: View {
    @Bindable var model: ShelfModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargeted = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let size = model.isOpen ? model.openSize : model.collapsedSize
        let closedFlare = model.hasBanners ? ShelfModel.flare : 0
        ZStack(alignment: .top) {
            if model.isOpen { openContent } else { closedContent }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color.black)
        .clipShape(NotchShape(flare: model.isOpen ? 0 : closedFlare, radius: model.isOpen ? 25 : (model.hasBanners ? 14 : 10)))
        .foregroundStyle(.white)
        // Files dragged onto the notch open the Files page and stay on the shelf.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadFileURLs(providers) { model.files.add($0); model.open(.files) }
            return true
        }
        .onChange(of: dropTargeted) { _, over in if over && !model.isOpen { model.open(.files) } }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: model.isOpen)
        .environment(\.colorScheme, .dark)
    }

    // MARK: closed

    /// Beside the notch: Claude Code activity (the dotted square and the number working or waiting) wins over music
    /// (album art and bars). Each sits 11.5 pt in from the outer edge, as in Bartender.
    private var closedContent: some View {
        HStack(spacing: 0) {
            if model.hasBanners {
                leftItem.frame(width: 14, height: 14).padding(.leading, ShelfModel.flare + 11.5)
                Spacer(minLength: 0)   // the camera notch itself
                rightItem.frame(width: 14, height: 14).padding(.trailing, ShelfModel.flare + 11.5)
            } else {
                Spacer()
            }
        }
        .frame(height: model.geometry.notchHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.open(.tray) }
    }

    @ViewBuilder private var leftItem: some View {
        if let state = model.agents.activeState {
            DottedSquare(moving: state == .working && !reduceMotion)
                .accessibilityLabel(state == .attention ? "A Claude Code session needs you" : "Claude Code is working")
        } else if model.showsMusic {
            Artwork(image: model.music.artwork, size: 14)
                .accessibilityLabel("Playing \(model.music.title ?? "")")
        }
    }

    @ViewBuilder private var rightItem: some View {
        if model.agents.activeState != nil {
            Text("\(model.agents.activeCount)")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Look.orange).fixedSize()
                .accessibilityLabel("\(model.agents.activeCount) Claude Code sessions busy")
        } else if model.showsMusic {
            PlayingBars(animate: !reduceMotion).accessibilityHidden(true)
        }
    }

    // MARK: open

    private var openContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Page.allCases, id: \.self) { p in
                    RoundButton(symbol: p.symbol, label: p.rawValue, selected: model.page == p) { model.page = p }
                }
                Color.clear.contentShape(Rectangle()).onTapGesture { model.close() }   // the strip around the notch closes the shelf
                if model.page == .clipboard { search.frame(width: 150) }
                RoundButton(symbol: "gearshape.fill", label: "Settings", selected: false) { model.showMenu?() }
            }
            .frame(height: 30)
            .padding(.horizontal, 10)
            .padding(.top, 10.5)
            page.padding(.horizontal, 10).padding(.top, 15.5).padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var search: some View {
        TextField("Search clipboard", text: $model.clipboard.query)
            .textFieldStyle(.plain).font(.system(size: 12))
            .padding(.horizontal, 10).frame(height: 30)
            .background(Look.button, in: Capsule())
            .focused($searchFocused)
            .onAppear { searchFocused = !model.openedByHover }
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .tray: TrayPage(model: model)
        case .files: FilesPage(model: model)
        case .clipboard: ClipboardPage(model: model)
        case .agents: AgentsPage(model: model)
        }
    }
}

extension Page {
    var symbol: String {
        switch self {
        case .tray: "square.grid.2x2.fill"
        case .files: "folder.fill"
        case .clipboard: "doc.on.doc.fill"
        case .agents: "sparkle"
        }
    }
}

/// A round 30 pt button: blue when it is the page shown.
struct RoundButton: View {
    let symbol: String
    let label: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(selected ? Look.blue : Look.button))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Claude Code's "working" sign: a 14 pt square of 16 small orange dots with a light running from the corners
/// along the edges. Still and fully lit while a session waits for John.
struct DottedSquare: View {
    let moving: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !moving)) { tl in
            Canvas { g, size in
                let t = moving ? tl.date.timeIntervalSinceReferenceDate : 0
                let dot: CGFloat = 1.6, step = (size.width - dot) / 4
                for i in 0...4 { for j in 0...4 where i == 0 || i == 4 || j == 0 || j == 4 {
                    let fromCorner = Double((i == 0 || i == 4) ? min(j, 4 - j) : min(i, 4 - i))   // 0 at a corner, 2 mid-edge
                    let light = moving ? 0.3 + 0.7 * (0.5 + 0.5 * cos(2 * .pi * (t / 1.2 - fromCorner / 3))) : 1
                    let r = CGRect(x: CGFloat(i) * step, y: CGFloat(j) * step, width: dot, height: dot)
                    g.fill(Path(roundedRect: r, cornerRadius: 0.5), with: .color(Look.orange.opacity(light)))
                } }
            }
        }
    }
}

/// Three bars that bounce while music plays (still when Reduce Motion is on).
struct PlayingBars: View {
    let animate: Bool
    @State private var up = false
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.85))
                    .frame(width: 2, height: up || !animate ? 12 : 4)
                    .animation(animate ? .easeInOut(duration: 0.8).repeatForever().delay(Double(i) * 0.2) : nil, value: up)
            }
        }
        .frame(height: 12)
        .onAppear { up = true }
    }
}
