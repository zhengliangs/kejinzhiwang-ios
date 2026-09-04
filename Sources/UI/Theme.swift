import SwiftUI

// 配色。移植自安卓版 MainActivity.kt 的 XuebiDarkColors / XuebiLightColors，
// 色值一一对应。SwiftUI 没有 MaterialTheme 的语义槽位，这里用环境变量
// 挂一组具名颜色，页面里读同样的名字。

struct Palette {
    var primary: Color
    var onPrimary: Color
    var secondary: Color
    var background: Color
    var surface: Color
    var surfaceVariant: Color
    var onBackground: Color
    var onSurface: Color
    var onSurfaceVariant: Color
    var error: Color
    /// 轻提示胶囊：深色主题下要给亮底配深字，与安卓的 inverseSurface 同理
    var tipBackground: Color
    var tipForeground: Color

    static let dark = Palette(
        primary: Color(hex: 0x4FC3F7),
        onPrimary: Color(hex: 0x00252F),
        secondary: Color(hex: 0x81C784),
        background: Color(hex: 0x121212),
        surface: Color(hex: 0x1E1E1E),
        surfaceVariant: Color(hex: 0x2A2A2A),
        onBackground: Color(hex: 0xE6E6E6),
        onSurface: Color(hex: 0xE6E6E6),
        onSurfaceVariant: Color(hex: 0xB0B0B0),
        error: Color(hex: 0xEF5350),
        tipBackground: Color(hex: 0xE6E6E6),
        tipForeground: Color(hex: 0x1E1E1E)
    )

    static let light = Palette(
        // primary 压深一档：浅底上 4FC3F7 太淡，文字和图标会发飘
        primary: Color(hex: 0x0277BD),
        onPrimary: .white,
        secondary: Color(hex: 0x2E7D32),
        background: Color(hex: 0xF7F7F7),
        surface: .white,
        surfaceVariant: Color(hex: 0xE8E8E8),
        onBackground: Color(hex: 0x1A1A1A),
        onSurface: Color(hex: 0x1A1A1A),
        onSurfaceVariant: Color(hex: 0x5A5A5A),
        error: Color(hex: 0xC62828),
        tipBackground: Color(hex: 0x2A2A2A),
        tipForeground: Color(hex: 0xF0F0F0)
    )
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.dark
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// 模型里存的是 ARGB 整数（与安卓一致），转成 SwiftUI 的 Color
    init(argb: Int) {
        self.init(hex: UInt32(bitPattern: Int32(argb)) & 0x00FFFFFF)
    }
}

extension Int {
    /// SwiftUI 侧的分组色，来源是 AccountGroup.colorArgb
    var paletteColor: Color { Color(argb: self) }
}
