import { describe, it, expect } from 'vitest';
import { discoverBundledSkills } from './skills-discovery.js';

describe('discoverBundledSkills', () => {
  it('finds at least 3 bundled skills with SKILL.md and frontmatter', () => {
    const skills = discoverBundledSkills();
    expect(skills.length).toBeGreaterThanOrEqual(3);
    expect(skills.every(s => s.name && s.description && s.category)).toBe(true);
  });

  it('includes hanzi-browse (core) and linkedin-prospector', () => {
    const skills = discoverBundledSkills();
    const names = skills.map(s => s.name);
    expect(names).toContain('hanzi-browse');
    expect(names).toContain('linkedin-prospector');
  });
});
