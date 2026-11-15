import AppKit
import SwiftUI

/// A row of picture tiles with a caption under each, like the appearance choice in System Settings.
struct TilePicker<Value: Hashable, Preview: View>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    @ViewBuilder let preview: (Value) -> Preview

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    VStack(spacing: 4) {
                        preview(option)
                            .clipShape(.rect(cornerRadius: 5))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(.separator, lineWidth: 0.5)
                            }
                            // Gap between picture and ring so a dark preview doesn't swallow it.
                            // Outer radius = inner radius + padding.
                            .padding(3)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.accentColor, lineWidth: 3)
                                    .opacity(isSelected ? 1 : 0)
                            }
                        Text(title(option))
                            .font(.callout)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.snappy(duration: 0.15), value: selection)
        // Without this VoiceOver reads every tile as the row's label instead of its own title.
        .accessibilityRepresentation {
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(title(option)).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }
}

/// A miniature Archipel window in a fixed light or dark look, for the appearance tiles.
/// System shows both halves, the way macOS draws its own Auto tile.
struct AppearancePreview: View {
    let appearance: AppSettings.Appearance

    var body: some View {
        switch appearance {
        case .light: MiniWindow(isDark: false)
        case .dark: MiniWindow(isDark: true)
        case .system:
            ZStack {
                MiniWindow(isDark: false)
                MiniWindow(isDark: true)
                    .mask(alignment: .trailing) {
                        Rectangle().frame(width: Self.size.width / 2)
                    }
            }
        }
    }

    static let size = CGSize(width: 76, height: 50)

    private struct MiniWindow: View {
        let isDark: Bool

        var body: some View {
            let wallpaper = isDark
                ? [Color(red: 0.16, green: 0.20, blue: 0.36), Color(red: 0.08, green: 0.09, blue: 0.18)]
                : [Color(red: 0.62, green: 0.78, blue: 0.98), Color(red: 0.86, green: 0.82, blue: 0.97)]
            let window = isDark ? Color(white: 0.17) : Color(white: 0.99)
            let sidebar = isDark ? Color(white: 0.24) : Color(white: 0.91)
            let line = isDark ? Color(white: 0.38) : Color(white: 0.80)

            ZStack(alignment: .topLeading) {
                LinearGradient(colors: wallpaper, startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 2) {
                            Circle().fill(.red)
                            Circle().fill(.yellow)
                            Circle().fill(.green)
                        }
                        .frame(height: 3.5)
                        .padding(.bottom, 2)
                        RoundedRectangle(cornerRadius: 1).fill(Color.accentColor).frame(width: 14, height: 3)
                        RoundedRectangle(cornerRadius: 1).fill(line).frame(width: 11, height: 3)
                        RoundedRectangle(cornerRadius: 1).fill(line).frame(width: 13, height: 3)
                        Spacer(minLength: 0)
                    }
                    .padding(4)
                    .frame(width: 24, alignment: .leading)
                    .frame(maxHeight: .infinity)
                    .background(sidebar)
                    VStack(alignment: .leading, spacing: 3) {
                        RoundedRectangle(cornerRadius: 1).fill(line).frame(width: 26, height: 3)
                        RoundedRectangle(cornerRadius: 1).fill(line).frame(width: 18, height: 3)
                        RoundedRectangle(cornerRadius: 1).fill(line).frame(width: 22, height: 3)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 13)
                    .padding(.leading, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(window)
                }
                .clipShape(.rect(cornerRadius: 3))
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                .padding(.top, 9)
                .padding(.leading, 10)
                // Runs off the bottom right edge, like a window bigger than the tile.
                .frame(width: size.width + 6, height: size.height + 6, alignment: .topLeading)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }

        private var size: CGSize { AppearancePreview.size }
    }
}

/// How the Claude usage reads at the bottom of the window in each style, with made-up numbers.
struct UsageDisplayPreview: View {
    let display: AppSettings.UsageDisplay
    let fill: AppSettings.UsageBarFill

    var body: some View {
        HStack(spacing: 5) {
            Text("Claude")
                .foregroundStyle(.secondary)
            switch display {
            case .numbers:
                HStack(spacing: 3) {
                    Text("5h").foregroundStyle(.tertiary)
                    Text("42%").foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Text("7d").foregroundStyle(.tertiary)
                    Text("18%").foregroundStyle(.secondary)
                }
            case .bars:
                VStack(spacing: 2) {
                    UsageBar(usedPercent: 42, fill: fill, height: 4)
                    UsageBar(usedPercent: 18, fill: fill, height: 3)
                }
                .frame(width: 44)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
        .frame(width: 124, height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

extension NSImage {
    /// The Finder icon of an app or folder at menu size. A copy, because the workspace may hand out
    /// a shared instance and resizing that would shrink it everywhere.
    static func menuIcon(forFile path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path).copy() as! NSImage
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

/// A sliver of the sidebar at each density: a project header and its worktrees drawn as bars, so
/// the tiles compare how much fits rather than what the rows say.
struct SidebarDensityPreview: View {
    let density: AppSettings.SidebarDensity

    var body: some View {
        VStack(alignment: .leading, spacing: rowGap) {
            project(selectedRow: true)
            project(selectedRow: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.top, 5)
        .frame(width: AppearancePreview.size.width, height: AppearancePreview.size.height, alignment: .topLeading)
        .background(.background.secondary)
        .clipped()
    }

    private func project(selectedRow: Bool) -> some View {
        VStack(alignment: .leading, spacing: rowGap) {
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 5, height: 5)
                bar(width: 22, height: 3, style: .primary)
            }
            .padding(.top, headerGap)
            row(width: 28, isSelected: selectedRow)
            row(width: 20, isSelected: false)
        }
    }

    private func row(width: CGFloat, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 3) {
            Circle().fill(.tertiary).frame(width: 3, height: 3).padding(.top, 0.5)
            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 4) {
                    bar(width: width, height: 2.5, style: .secondary)
                    if density == .compact {
                        Spacer(minLength: 0)
                        bar(width: 8, height: 2, style: .tertiary)
                    }
                }
                if density != .compact {
                    bar(width: width * 0.7, height: 2, style: .tertiary)
                }
            }
        }
        .padding(.vertical, rowPadding)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 2))
    }

    private func bar(width: CGFloat, height: CGFloat, style: some ShapeStyle) -> some View {
        Capsule().fill(style).frame(width: width, height: height)
    }

    private var rowGap: CGFloat { density == .spacious ? 1.5 : 0.5 }
    private var rowPadding: CGFloat {
        switch density {
        case .compact: 1
        case .comfortable: 1.5
        case .spacious: 2.5
        }
    }
    private var headerGap: CGFloat {
        switch density {
        case .compact: 0
        case .comfortable: 1
        case .spacious: 3
        }
    }
}
