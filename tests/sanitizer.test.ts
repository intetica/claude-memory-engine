import { describe, it, expect } from 'vitest';
import { sanitize, sanitizeText } from '../scripts/wiki/queue-consumer/sanitizer.js';

// Test fixtures are built programmatically so they don't appear as literal
// secrets to scanners (GitHub Push Protection, gitleaks, etc.).
const fake = (prefix: string, len = 28) => prefix + 'F'.repeat(len);

describe('sanitizer', () => {
  it('redacts Anthropic / OpenAI keys', () => {
    const r = sanitize(`My key is ${fake('sk-')} here.`);
    expect(r.text).toContain('[REDACTED]');
    expect(r.text).not.toMatch(/sk-F+/);
    expect(r.hits.find((h) => h.pattern === 'anthropic-openai')?.count).toBe(1);
  });

  it('redacts GitHub PAT classic', () => {
    const r = sanitize(`token=${fake('pat_')}`);
    expect(r.text).not.toMatch(/pat_F+/);
    expect(r.hits.some((h) => h.pattern === 'github-pat-classic')).toBe(true);
  });

  it('redacts AWS access keys', () => {
    const r = sanitize('AWS_ACCESS_KEY_ID=' + 'AKIA' + 'F'.repeat(16));
    expect(r.text).not.toMatch(/AKIA[A-Z0-9]+/);
    expect(r.hits.some((h) => h.pattern === 'aws-access-key')).toBe(true);
  });

  it('redacts HTTP Bearer tokens', () => {
    const r = sanitize(`Authorization: Bearer ${'F'.repeat(28)}`);
    expect(r.text).not.toMatch(/Bearer F+/);
    expect(r.hits.some((h) => h.pattern === 'http-bearer')).toBe(true);
  });

  it('redacts Slack bot tokens', () => {
    const r = sanitize(`SLACK_BOT_TOKEN=${fake('xoxb-', 30)}`);
    expect(r.text).not.toMatch(/xoxb-F+/);
    expect(r.hits.some((h) => h.pattern === 'slack-bot')).toBe(true);
  });

  it('redacts GitHub fine-grained PAT', () => {
    const r = sanitize(`use ${fake('ghp_', 36)} for auth`);
    expect(r.text).not.toMatch(/ghp_F+/);
    expect(r.hits.some((h) => h.pattern === 'github-pat-fine')).toBe(true);
  });

  it('redacts GitLab PAT', () => {
    const r = sanitize(fake('glpat-', 22));
    expect(r.text).not.toMatch(/glpat-F+/);
    expect(r.hits.some((h) => h.pattern === 'gitlab-pat')).toBe(true);
  });

  it('redacts multiple secrets in one input and counts each', () => {
    const r = sanitize(`one ${fake('sk-')} and another ${fake('sk-')}`);
    expect(r.hits.find((h) => h.pattern === 'anthropic-openai')?.count).toBe(2);
    expect((r.text.match(/\[REDACTED\]/g) ?? []).length).toBe(2);
  });

  it('leaves clean text alone', () => {
    const clean = 'this is a perfectly normal sentence with no secrets';
    const r = sanitize(clean);
    expect(r.text).toBe(clean);
    expect(r.hits).toHaveLength(0);
  });

  it('sanitizeText drops hits and returns string', () => {
    const out = sanitizeText('AKIA' + 'F'.repeat(16) + ' leaked');
    expect(typeof out).toBe('string');
    expect(out).not.toMatch(/AKIA[A-Z0-9]+/);
  });
});
