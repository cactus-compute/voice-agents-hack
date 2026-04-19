import React from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { palette } from '@/theme/colors';
import { radius, spacing } from '@/theme/spacing';
import { type } from '@/theme/typography';
import type { Message, SessionPhase } from '@/state/types';

interface TranscriptCardProps {
  phase: SessionPhase;
  lastUser?: Message;
  lastAssistant?: Message;
  partialAssistant: string;
}

/**
 * Voice-first transcript surface.
 *
 * Instead of a chat scrollback, we render only the most recent exchange,
 * front-and-center. The UI's job here is to confirm what was heard and
 * reflect what's being said, not to be a chat log. Anyone who wants
 * scrollback can open the Settings sheet (out of scope for v1).
 */
export function TranscriptCard({
  phase,
  lastUser,
  lastAssistant,
  partialAssistant,
}: TranscriptCardProps) {
  const showThinking = phase === 'thinking' && !partialAssistant;
  const assistantText = partialAssistant || lastAssistant?.content || '';

  return (
    <View style={styles.card}>
      {lastUser?.content ? (
        <View style={styles.row}>
          <Text style={styles.label}>You</Text>
          <Text style={styles.userText} numberOfLines={3}>
            {lastUser.content}
          </Text>
        </View>
      ) : null}

      {assistantText ? (
        <View style={styles.row}>
          <Text style={styles.label}>Aurora</Text>
          <Text style={styles.assistantText}>{assistantText}</Text>
        </View>
      ) : null}

      {showThinking ? (
        <View style={styles.row}>
          <Text style={styles.label}>Aurora</Text>
          <Text style={styles.placeholder}>Listening to what you said…</Text>
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    width: '100%',
    paddingHorizontal: spacing.lg,
    paddingVertical: spacing.lg,
    borderRadius: radius.lg,
    backgroundColor: palette.glass,
    borderWidth: 1,
    borderColor: palette.glassBorder,
    gap: spacing.md,
  },
  row: { gap: spacing.xs },
  label: {
    ...type.caption,
    color: palette.paperFaint,
  },
  userText: {
    ...type.body,
    color: palette.paper,
  },
  assistantText: {
    ...type.prompt,
    color: palette.paper,
  },
  placeholder: {
    ...type.body,
    color: palette.paperFaint,
    fontStyle: 'italic',
  },
});
