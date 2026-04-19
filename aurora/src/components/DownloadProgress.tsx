import React from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { palette } from '@/theme/colors';
import { radius, spacing } from '@/theme/spacing';
import { type } from '@/theme/typography';

interface DownloadProgressProps {
  progress: number;
  modelLabel?: string;
}

export function DownloadProgress({ progress, modelLabel = 'Gemma 4 E4B' }: DownloadProgressProps) {
  const pct = Math.max(0, Math.min(100, Math.round(progress * 100)));
  return (
    <View style={styles.wrap}>
      <Text style={styles.label}>Preparing {modelLabel}</Text>
      <View style={styles.track}>
        <View style={[styles.fill, { width: `${pct}%` }]} />
      </View>
      <Text style={styles.meta}>
        {pct}% — model is downloading once, then runs on this device.
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: {
    width: '100%',
    paddingHorizontal: spacing.lg,
    paddingVertical: spacing.lg,
    borderRadius: radius.lg,
    backgroundColor: palette.glass,
    borderWidth: 1,
    borderColor: palette.glassBorder,
    gap: spacing.md,
  },
  label: { ...type.caption, color: palette.paperSoft },
  track: {
    height: 6,
    borderRadius: 3,
    backgroundColor: 'rgba(245, 235, 220, 0.16)',
    overflow: 'hidden',
  },
  fill: {
    height: 6,
    borderRadius: 3,
    backgroundColor: palette.peach,
  },
  meta: { ...type.meta, color: palette.paperFaint },
});
