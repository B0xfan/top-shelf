import SwiftUI

/// Colors and sizes from the approved mockup (mockup.html).
enum Look {
    static let card = Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255)
    static let dim = Color.white.opacity(0.6)
    static let faint = Color.white.opacity(0.1)
    static let green = Color(red: 0x30 / 255, green: 0xd1 / 255, blue: 0x58 / 255)
    static let orange = Color(red: 1, green: 0x9f / 255, blue: 0x0a / 255)
    static let blue = Color(red: 0x0a / 255, green: 0x84 / 255, blue: 1)
    static let title = Font.system(size: 13, weight: .semibold)
    static let small = Font.system(size: 11)
}

struct ShelfView: View {
    @Bindable var model: ShelfModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargeted = false

    var body: some View {
        let size = model.isOpen ? model.openSize : model.collapsedSize
        VStack(spacing: 0) {
            notchRow
            if model.isOpen {
                page.padding(.horizontal, 16).padding(.top, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                pageDots.padding(.bottom, 6)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: model.isOpen ? 22 : 10, bottomTrailingRadius: model.isOpen ? 22 : 10))
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

    /// The strip level with the notch: activity banners while closed, a close target while open.
    private var notchRow: some View {
        HStack(spacing: 8) {
            if !model.isOpen && model.hasBanners {
                leftBanner.frame(width: ShelfModel.bannerWidth - 10, alignment: .leading)
                Spacer(minLength: 0)
                rightBanner.frame(width: ShelfModel.bannerWidth - 10, alignment: .trailing)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: model.geometry.notchHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.isOpen ? model.close() : model.open(.tray) }
    }

    @ViewBuilder private var leftBanner: some View {
        if model.music.isPlaying && model.music.hasTrack {
            HStack(spacing: 6) {
                Artwork(image: model.music.artwork, size: 20)
                PlayingBars(animate: !reduceMotion)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playing \(model.music.title ?? "")")
        }
    }

    @ViewBuilder private var rightBanner: some View {
        HStack(spacing: 6) {
            if let e = model.calendar.soon {
                Text(e.title).lineLimit(1)
                Text(e.start.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())).fixedSize()
            }
            if model.agents.needsAttention {
                Circle().fill(Look.orange).frame(width: 8, height: 8).accessibilityLabel("A Claude Code session needs you")
            }
        }
        .font(Look.small)
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .tray: TrayPage(model: model)
        case .files: FilesPage(model: model)
        case .clipboard: ClipboardPage(model: model)
        case .agents: AgentsPage(model: model)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(Page.allCases, id: \.self) { p in
                Button { model.page = p } label: {
                    HStack(spacing: 5) {
                        Circle().frame(width: 5, height: 5)
                        Text(p.rawValue).font(Look.small)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .foregroundStyle(model.page == p ? Color.white : Look.dim)
                    .background(model.page == p ? Look.faint : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.page == p ? .isSelected : [])
            }
        }
    }
}

/// Three green bars that bounce while music plays (still when Reduce Motion is on).
struct PlayingBars: View {
    let animate: Bool
    @State private var up = false
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 1).fill(Look.green)
                    .frame(width: 2, height: up || !animate ? 12 : 3)
                    .animation(animate ? .easeInOut(duration: 0.8).repeatForever().delay(Double(i) * 0.2) : nil, value: up)
            }
        }
        .frame(height: 12)
        .onAppear { up = true }
    }
}
