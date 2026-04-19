import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { palette } from '@/theme/colors';
import { spacing } from '@/theme/spacing';
import { type } from '@/theme/typography';

interface HeaderProps {
  subtitle?: string;
  onReset?: () => void;
}

export function Header({ subtitle, onReset }: HeaderProps) {
  return (
    <View style={styles.row}>
      <View>
        <Text style={styles.brand}>Aurora</Text>
        {subtitle ? <Text style={styles.subtitle}>{subtitle}</Text> : null}
      </View>
      {onReset ? (
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Start a new session"
          onPress={onReset}
          style={({ pressed }) => [styles.reset, pressed && { opacity: 0.6 }]}
        >
          <Text style={styles.resetLabel}>New session</Text>
        </Pressable>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'flex-end',
    paddingHorizontal: spacing.lg,
    paddingTop: spacing.md,
  },
  brand: {
    ...type.title,
    color: palette.paper,
  },
  subtitle: {
    ...type.meta,
    color: palette.paperFaint,
    marginTop: 2,
  },
  reset: {
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
  },
  resetLabel: {
    ...type.caption,
    color: palette.paperSoft,
  },
});
