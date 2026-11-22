package com.reelhouse.android.ui.theme

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocalMovies
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// The wordmark: a film reel and REELHOUSE in heavy, wide-tracked caps, lit like a marquee -
// gold running into curtain red, with a soft gold glow.
@Composable
fun ReelHouseWordmark(modifier: Modifier = Modifier, style: TextStyle = MaterialTheme.typography.titleLarge) {
    val gold = ReelHouseGold
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Default.LocalMovies, contentDescription = null, tint = ReelHouseCurtain, modifier = Modifier.size(style.fontSize.value.dp + 4.dp))
        Text(
            "REELHOUSE",
            style = style.copy(
                brush = Brush.horizontalGradient(listOf(gold, ReelHouseAmber, ReelHouseCurtain)),
                fontWeight = FontWeight.Black,
                letterSpacing = 3.sp,
                shadow = Shadow(color = gold.copy(alpha = 0.45f), blurRadius = 14f),
            ),
        )
    }
}
