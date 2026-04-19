import React, { useEffect, useMemo } from 'react';
import { StyleSheet, View, ViewStyle } from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';
import Svg, { Circle, Defs, RadialGradient, Stop } from 'react-native-svg';
import Animated, {
  cancelAnimation,
  Easing,
  useAnimatedStyle,
  useSharedValue,
  withRepeat,
  withTiming,
} from 'react-native-reanimated';

import { gradients, palette } from '@/theme/colors';
import type { SessionPhase } from '@/state/types';

const AnimatedView = Animated.createAnimatedComponent(View);

interface BreathingOrbProps {
  phase: SessionPhase;
  /** -160 (silence) … 0 (loudest). Used to shimmer during listening. */
  meterDb?: number;
  size?: number;
}

/**
 * The orb is the protagonist of the screen. Every other element exists
 * to support it. Its color, scale, and motion encode the model's state
 * so the user knows where they are in the loop without reading anything.
 *
 *   idle      — slow breath, deep blue, nearly still
 *   listening — warm rose/peach, scales with mic level
 *   thinking  — minty teal, slow rotation, no scale change
 *   speaking  — cream/peach, gentle pulse on each syllable hint
 *   error     — muted, slightly desaturated red
 */
export function BreathingOrb({ phase, meterDb = -160, size = 240 }: BreathingOrbProps) {
  const breath = useSharedValue(0);
  const reactive = useSharedValue(0);

  const colors = useMemo<readonly [string, string, ...string[]]>(() => {
    switch (phase) {
      case 'listening':
        return gradients.orbListening;
      case 'thinking':
        return gradients.orbThinking;
      case 'speaking':
        return gradients.orbSpeaking;
      case 'error':
        return ['#7A3A3F', '#3A1F22'] as const;
      default:
        return gradients.orbIdle;
    }
  }, [phase]);

  useEffect(() => {
    cancelAnimation(breath);
    const duration = phase === 'thinking' ? 2400 : 5200;
    breath.value = 0;
    breath.value = withRepeat(
      withTiming(1, { duration, easing: Easing.inOut(Easing.sin) }),
      -1,
      true
    );
  }, [phase, breath]);

  // Map dB (-160..0) to 0..1, with a soft floor so silence still reads.
  useEffect(() => {
    const norm = phase === 'listening'
      ? Math.max(0, Math.min(1, (meterDb + 60) / 60))
      : 0;
    reactive.value = withTiming(norm, { duration: 120 });
  }, [meterDb, phase, reactive]);

  const orbStyle = useAnimatedStyle(() => {
    const breatheScale = 0.94 + breath.value * 0.06;
    const reactScale = 1 + reactive.value * 0.08;
    return {
      transform: [{ scale: breatheScale * reactScale }],
    };
  });

  const haloStyle = useAnimatedStyle(() => {
    const opacity = 0.18 + breath.value * 0.18 + reactive.value * 0.2;
    const scale = 1.1 + breath.value * 0.06 + reactive.value * 0.1;
    return { opacity, transform: [{ scale }] };
  });

  const ring2Style = useAnimatedStyle(() => {
    const opacity = 0.08 + breath.value * 0.1;
    const scale = 1.28 + breath.value * 0.08;
    return { opacity, transform: [{ scale }] };
  });

  const containerStyle: ViewStyle = {
    width: size,
    height: size,
    alignItems: 'center',
    justifyContent: 'center',
  };

  return (
    <View style={containerStyle}>
      <AnimatedView style={[StyleSheet.absoluteFill, styles.center, ring2Style]}>
        <SoftRing size={size * 1.25} color={colors[0]} />
      </AnimatedView>
      <AnimatedView style={[StyleSheet.absoluteFill, styles.center, haloStyle]}>
        <SoftRing size={size * 1.06} color={colors[colors.length - 1]} />
      </AnimatedView>
      <AnimatedView style={[styles.center, orbStyle, { width: size, height: size }]}>
        <LinearGradient
          colors={colors}
          start={{ x: 0.2, y: 0.1 }}
          end={{ x: 0.8, y: 0.95 }}
          style={[styles.orb, { width: size, height: size, borderRadius: size / 2 }]}
        />
        <View
          style={[
            styles.specular,
            {
              width: size * 0.42,
              height: size * 0.42,
              borderRadius: (size * 0.42) / 2,
              top: size * 0.14,
              left: size * 0.18,
            },
          ]}
        />
      </AnimatedView>
    </View>
  );
}

function SoftRing({ size, color }: { size: number; color: string }) {
  return (
    <Svg width={size} height={size}>
      <Defs>
        <RadialGradient id="halo" cx="50%" cy="50%" r="50%">
          <Stop offset="0%" stopColor={color} stopOpacity={0.55} />
          <Stop offset="60%" stopColor={color} stopOpacity={0.18} />
          <Stop offset="100%" stopColor={color} stopOpacity={0} />
        </RadialGradient>
      </Defs>
      <Circle cx={size / 2} cy={size / 2} r={size / 2} fill="url(#halo)" />
    </Svg>
  );
}

const styles = StyleSheet.create({
  center: { alignItems: 'center', justifyContent: 'center' },
  orb: {
    shadowColor: palette.peach,
    shadowOpacity: 0.5,
    shadowRadius: 40,
    shadowOffset: { width: 0, height: 0 },
    elevation: 12,
  },
  specular: {
    position: 'absolute',
    backgroundColor: 'rgba(245, 235, 220, 0.35)',
  },
});
