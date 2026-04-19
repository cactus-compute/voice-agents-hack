import { existsSync, readFileSync, readdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

export type SkillCategory = 'core' | 'productivity' | 'marketing' | 'life';

export interface SkillMeta {
  name: string;
  description: string;
  category: SkillCategory;
  path: string;
}

const VALID_CATEGORIES: readonly SkillCategory[] = ['core', 'productivity', 'marketing', 'life'];

function parseFrontmatter(content: string): { description?: string; category?: SkillCategory } | null {
  const m = content.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!m) return null;
  const out: { description?: string; category?: SkillCategory } = {};
  for (const line of m[1].split(/\r?\n/)) {
    const mm = line.match(/^(\w+):\s*(.*)$/);
    if (!mm) continue;
    if (mm[1] === 'description') out.description = mm[2].trim();
    if (mm[1] === 'category' && (VALID_CATEGORIES as readonly string[]).includes(mm[2].trim())) {
      out.category = mm[2].trim() as SkillCategory;
    }
  }
  return out;
}

/** Resolve the bundled `skills/` directory relative to the CLI dist. */
export function getSkillsSource(): string {
  return join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'skills');
}

export function discoverBundledSkills(sourceDir = getSkillsSource()): SkillMeta[] {
  if (!existsSync(sourceDir)) return [];
  const out: SkillMeta[] = [];
  for (const entry of readdirSync(sourceDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const md = join(sourceDir, entry.name, 'SKILL.md');
    if (!existsSync(md)) continue;
    const meta = parseFrontmatter(readFileSync(md, 'utf-8'));
    if (!meta) continue;
    out.push({
      name: entry.name,
      description: meta.description || '',
      category: meta.category ?? 'productivity',
      path: join(sourceDir, entry.name),
    });
  }
  return out;
}
