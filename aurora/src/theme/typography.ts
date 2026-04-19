import { Platform, TextStyle } from 'react-native';

const serif = Platform.select({
  ios: 'Georgia',
  android: 'serif',
  default: 'Georgia',
})!;

const sans = Platform.select({
  ios: 'System',
  android: 'sans-serif',
  default: 'System',
})!;

const sansLight = Platform.select({
  ios: 'System',
  android: 'sans-serif-light',
  default: 'System',
})!;

export const type = {
  hero: {
    fontFamily: serif,
    fontSize: 38,
    lineHeight: 46,
    letterSpacing: -0.5,
    fontWeight: '400',
  } satisfies TextStyle,

  title: {
    fontFamily: serif,
    fontSize: 26,
    lineHeight: 34,
    letterSpacing: -0.2,
    fontWeight: '400',
  } satisfies TextStyle,

  prompt: {
    fontFamily: sansLight,
    fontSize: 22,
    lineHeight: 30,
    letterSpacing: 0.1,
    fontWeight: '300',
  } satisfies TextStyle,

  body: {
    fontFamily: sans,
    fontSize: 17,
    lineHeight: 26,
    letterSpacing: 0.1,
    fontWeight: '400',
  } satisfies TextStyle,

  caption: {
    fontFamily: sans,
    fontSize: 13,
    lineHeight: 18,
    letterSpacing: 0.4,
    fontWeight: '500',
    textTransform: 'uppercase' as const,
  } satisfies TextStyle,

  meta: {
    fontFamily: sans,
    fontSize: 12,
    lineHeight: 16,
    letterSpacing: 0.2,
    fontWeight: '400',
  } satisfies TextStyle,
};
