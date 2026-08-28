import SwiftUI
import KaijuKit

struct AppearanceView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.theme) private var theme

    private var appearance: AppearanceConfiguration { settings.settings.appearance }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.sectionSpacing) {
                themesCard
                accentCard
                layoutCard
                presenceCard
            }
            .padding(theme.contentPadding)
        }
    }

    private var themesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Theme",
                              subtitle: "Surfaces stay native in both light and dark. What changes is the accent and a faint tint over the canvas.",
                              systemImage: "paintpalette")

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 152), spacing: 12)], spacing: 12) {
                    ForEach(ThemeIdentifier.allCases) { identifier in
                        themeSwatch(identifier)
                    }
                }

                Divider()

                Picker("Appearance", selection: $settings.settings.appearance.colorScheme) {
                    ForEach(ColorSchemePreference.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func themeSwatch(_ identifier: ThemeIdentifier) -> some View {
        let isSelected = appearance.theme == identifier && appearance.accentHexOverride == nil
        return Button {
            settings.settings.appearance.theme = identifier
            settings.settings.appearance.accentHexOverride = nil
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Circle().fill(Color(hex: identifier.accentHex) ?? .accentColor)
                        .frame(width: 16, height: 16)
                    Circle().fill(Color(hex: identifier.secondaryAccentHex) ?? .accentColor)
                        .frame(width: 16, height: 16)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: identifier.accentHex) ?? .accentColor)
                    }
                }
                Text(identifier.displayName).font(.system(size: 12, weight: .semibold))
                Text(identifier.blurb)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.kaijuSeparator.opacity(0.18))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? (Color(hex: identifier.accentHex) ?? .accentColor)
                                             : Color.kaijuSeparator.opacity(0.5),
                                  lineWidth: isSelected ? 1.5 : 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var accentCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Accent colour",
                              subtitle: "Overrides the theme's own accent.",
                              systemImage: "eyedropper")

                HStack(spacing: 9) {
                    ForEach(AccentSwatch.allCases) { swatch in
                        Button {
                            settings.settings.appearance.accentHexOverride = swatch.rawValue
                        } label: {
                            Circle()
                                .fill(swatch.color)
                                .frame(width: 24, height: 24)
                                .overlay {
                                    if appearance.accentHexOverride == swatch.rawValue {
                                        Circle().strokeBorder(.white, lineWidth: 2)
                                            .padding(2)
                                    }
                                }
                                .overlay {
                                    Circle().strokeBorder(Color.kaijuSeparator.opacity(0.5),
                                                          lineWidth: 0.5)
                                }
                        }
                        .buttonStyle(.plain)
                        .help(swatch.name)
                    }
                    Spacer()
                    if appearance.accentHexOverride != nil {
                        Button("Use theme colour") {
                            settings.settings.appearance.accentHexOverride = nil
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                }
            }
        }
    }

    private var layoutCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Layout & motion", systemImage: "square.resize")

                SettingRow(title: "Density",
                           detail: "Compact tightens padding throughout — useful on a laptop screen.",
                           systemImage: "arrow.up.and.down.text.horizontal") {
                    Picker("", selection: $settings.settings.appearance.density) {
                        ForEach(LayoutDensity.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                SettingRow(title: "Animation",
                           detail: "None removes every transition, including the pulsing recording dot.",
                           systemImage: "wand.and.rays") {
                    Picker("", selection: $settings.settings.appearance.animationIntensity) {
                        ForEach(AnimationIntensity.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }
        }
    }

    private var presenceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Where Kaiju lives", systemImage: "menubar.rectangle")

                SettingRow(title: "Show in the Dock",
                           detail: "Turn this off and Kaiju becomes a menu-bar-only app. It keeps buffering either way.",
                           systemImage: "dock.rectangle") {
                    Toggle("", isOn: $settings.settings.appearance.showDockIcon)
                        .toggleStyle(.switch).labelsHidden()
                }

                SettingRow(title: "Menu bar icon",
                           detail: "The buffer state can ride along next to the icon.",
                           systemImage: "menubar.arrow.up.rectangle") {
                    Picker("", selection: $settings.settings.appearance.menuBarIconStyle) {
                        ForEach(AppearanceConfiguration.MenuBarIconStyle.allCases) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }
        }
    }
}
