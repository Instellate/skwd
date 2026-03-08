pragma Singleton
import QtQuick

// Singleton design tokens for the entire shell UI.
// Font families, sizes, radii, spacing, animation durations, borders, and opacity levels.
QtObject {
    id: style

    // Font families
    readonly property string fontFamily: "Roboto Condensed"
    readonly property string fontFamilyHeading: "Roboto"
    readonly property string fontFamilyMono: "monospace"
    readonly property string fontFamilyCode: "Roboto Mono"
    readonly property string fontFamilyIcons: "Material Design Icons Desktop"
    readonly property string fontFamilyNerdIcons: "Symbols Nerd Font"


    // Font sizes (px)
    readonly property int fontTiny: 9
    readonly property int fontCaption: 11
    readonly property int fontBody: 12
    readonly property int fontBodyLarge: 13
    readonly property int fontSubtitle: 14
    readonly property int fontTitle: 16
    readonly property int fontTitleLarge: 18
    readonly property int fontHeadline: 24
    readonly property int fontDisplay: 32
    readonly property int fontDisplayLarge: 36
    readonly property int fontClock: 200
    readonly property int fontClockDate: 120


    // Border radii
    readonly property int radiusTiny: 2
    readonly property int radiusSmall: 4
    readonly property int radiusMedium: 8
    readonly property int radiusLarge: 12
    readonly property int radiusXLarge: 16
    readonly property int radiusRound: 20
    readonly property int radiusCircle: 40


    // Spacing scale
    readonly property int spacingTiny: 2
    readonly property int spacingSmall: 4
    readonly property int spacingMedium: 8
    readonly property int spacingLarge: 12
    readonly property int spacingXLarge: 16
    readonly property int spacingXXLarge: 20


    // Animation durations (ms)
    readonly property int animFast: 150
    readonly property int animNormal: 200
    readonly property int animMedium: 300
    readonly property int animSlow: 400


    // Border widths
    readonly property int borderThin: 1
    readonly property int borderMedium: 2
    readonly property int borderThick: 3


    // Opacity levels
    readonly property real opacityDim: 0.35
    readonly property real opacityMuted: 0.5
    readonly property real opacitySubtle: 0.6
}
