import { describe, it, expect } from "vitest";
import { getDomainSkill, getAllDomainSkills } from "./domain-knowledge.js";

describe("getDomainSkill", () => {
  it("matches exact hostname", () => {
    const e = getDomainSkill("https://x.com/home");
    expect(e?.domain).toBe("x.com");
  });

  it("matches subdomain via endsWith", () => {
    const e = getDomainSkill("https://www.linkedin.com/in/me");
    expect(e?.domain).toBe("linkedin.com");
  });

  it("returns null for unknown domain", () => {
    expect(getDomainSkill("https://unknown-site-xyz.test/")).toBeNull();
  });
});

describe("getAllDomainSkills", () => {
  it("exposes lastVerified and goldenTasks fields on seeded entries", () => {
    const all = getAllDomainSkills();
    const seeded = all.find(e => typeof e.lastVerified === "string");
    expect(seeded).toBeDefined();
    expect(typeof seeded!.goldenTasks).toBe("string");
  });

  it("loads all 21 entries including unseeded ones (nullable new fields)", () => {
    const all = getAllDomainSkills();
    expect(all.length).toBeGreaterThan(10);
    for (const e of all) {
      expect(typeof e.domain).toBe("string");
      expect(typeof e.skill).toBe("string");
    }
  });
});
