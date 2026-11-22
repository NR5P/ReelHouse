package com.reelhouse.android.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

// Brand accent colors only - kept as named, theme-aware properties (not plain constants) so
// every existing call site (Text(color = ReelHouseGold), NavigationBar(containerColor =
// ReelHousePanel), etc.) picks up the right light/dark value automatically with no changes.
// Everything that isn't a deliberate brand accent (backgrounds, primary/secondary text) should
// prefer MaterialTheme.colorScheme's own semantics instead of reaching for one of these.

// "Movie palace": gold marquee bulbs and red velvet curtains on plum-black. Errors (Red) are a
// brighter orange-red so they never read as the curtain accent.
private val GoldDark = Color(0xFFFFC24B)
private val GoldLight = Color(0xFFA8650A)
private val GoldDimDark = Color(0xFFC98A1E)
private val GoldDimLight = Color(0xFF7A4A06)
private val CurtainDark = Color(0xFFE23D3D)
private val CurtainLight = Color(0xFFB3202A)
private val AmberDark = Color(0xFFFF9A3C)
private val AmberLight = Color(0xFFA34A00)
private val RedDark = Color(0xFFFF5A36)
private val RedLight = Color(0xFFC2410C)
private val BackgroundDark = Color(0xFF0E0A12)
private val BackgroundLight = Color(0xFFFBF7F1)
private val PanelDark = Color(0xFF171020)
private val PanelLight = Color(0xFFF3ECE2)
private val CardDark = Color(0xFF1F1629)
private val CardLight = Color(0xFFFFFFFF)
private val TextDark = Color(0xFFF4E9DA)
private val TextLight = Color(0xFF24161F)
private val TextDimDark = Color(0xFFA99A8E)
private val TextDimLight = Color(0xFF6E5E62)

val ReelHouseGold: Color @Composable get() = if (isSystemInDarkTheme()) GoldDark else GoldLight
val ReelHouseGoldDim: Color @Composable get() = if (isSystemInDarkTheme()) GoldDimDark else GoldDimLight
val ReelHouseCurtain: Color @Composable get() = if (isSystemInDarkTheme()) CurtainDark else CurtainLight
val ReelHouseAmber: Color @Composable get() = if (isSystemInDarkTheme()) AmberDark else AmberLight
val ReelHouseRed: Color @Composable get() = if (isSystemInDarkTheme()) RedDark else RedLight
val ReelHouseBackground: Color @Composable get() = if (isSystemInDarkTheme()) BackgroundDark else BackgroundLight
val ReelHousePanel: Color @Composable get() = if (isSystemInDarkTheme()) PanelDark else PanelLight
val ReelHouseCard: Color @Composable get() = if (isSystemInDarkTheme()) CardDark else CardLight
val ReelHouseText: Color @Composable get() = if (isSystemInDarkTheme()) TextDark else TextLight
val ReelHouseTextDim: Color @Composable get() = if (isSystemInDarkTheme()) TextDimDark else TextDimLight

private val darkColors = darkColorScheme(
    primary = GoldDark,
    onPrimary = BackgroundDark,
    primaryContainer = Color(0xFF3D2A10),
    onPrimaryContainer = GoldDark,
    secondary = CurtainDark,
    onSecondary = BackgroundDark,
    secondaryContainer = Color(0xFF3F1418),
    onSecondaryContainer = CurtainDark,
    tertiary = AmberDark,
    background = BackgroundDark,
    onBackground = TextDark,
    surface = PanelDark,
    onSurface = TextDark,
    surfaceVariant = CardDark,
    onSurfaceVariant = TextDimDark,
    error = RedDark,
    onError = BackgroundDark,
    outline = Color(0xFF5A3F55),
)

private val lightColors = lightColorScheme(
    primary = GoldLight,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFFFE6B8),
    onPrimaryContainer = GoldDimLight,
    secondary = CurtainLight,
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFFFD9D6),
    onSecondaryContainer = CurtainLight,
    tertiary = AmberLight,
    background = BackgroundLight,
    onBackground = TextLight,
    surface = PanelLight,
    onSurface = TextLight,
    surfaceVariant = CardLight,
    onSurfaceVariant = TextDimLight,
    error = RedLight,
    onError = Color.White,
    outline = GoldDimLight,
)

// Monospace was previously applied to every text style, which is where the app's "terminal"
// look mostly came from. Kept narrowly (SettingsScreen's diagnostics log, file
// paths) at those specific call sites instead of globally - everything else now falls back to
// the Material 3 default (Roboto/system font).
private val typography = Typography()

@Composable
fun ReelHouseTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    // Off: ReelHouse's marquee gold and curtain red are the brand, and Material You's wallpaper
    // palette would replace them with whatever the phone's wallpaper happens to be.
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        darkTheme -> darkColors
        else -> lightColors
    }
    MaterialTheme(
        colorScheme = colorScheme,
        typography = typography,
        content = content,
    )
}
