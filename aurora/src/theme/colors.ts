/**
 * Aurora palette — dawn through dusk, named for the emotional register
 * each color is meant to evoke. Designed to feel like a quiet room with
 * one warm lamp on, not a clinical app.
 */

export const palette = {
  midnight: '#0B0F2C',
  twilight: '#1B1F4A',
  dusk: '#2E2C5A',
  rose: '#D9A2B8',
  peach: '#F2C6A0',
  cream: '#F5EBDC',
  sand: '#E8DCC4',

  glass: 'rgba(245, 235, 220, 0.08)',
  glassBorder: 'rgba(245, 235, 220, 0.16)',

  ink: '#0B0F2C',
  inkSoft: 'rgba(11, 15, 44, 0.72)',
  paper: '#F5EBDC',
  paperSoft: 'rgba(245, 235, 220, 0.78)',
  paperFaint: 'rgba(245, 235, 220, 0.52)',

  signal: '#7FD4C0',
  warning: '#F2A65A',
  danger: '#E76F77',
} as const;

export const gradients = {
  aurora: [palette.midnight, palette.twilight, palette.dusk, palette.rose, palette.peach] as const,
  orbIdle: ['#3B3B7A', '#1B1F4A'] as const,
  orbListening: ['#F2C6A0', '#D9A2B8', '#9A7BB8'] as const,
  orbThinking: ['#7FD4C0', '#5BA8B8', '#3B3B7A'] as const,
  orbSpeaking: ['#F5EBDC', '#F2C6A0', '#D9A2B8'] as const,
};
