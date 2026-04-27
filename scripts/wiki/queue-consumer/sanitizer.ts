// Memory Engine — Sanitizer for secrets before LLM extraction + DB write
// Source: Design D30
// Patterns: Anthropic+OpenAI, GitHub PAT, AWS access keys, HTTP Bearer, Slack, GitHub fine-grained, GitLab PAT

const SECRET_PATTERNS: Array<{ name: string; pattern: RegExp }> = [
  { name: 'anthropic-openai', pattern: /sk-[a-zA-Z0-9_-]{20,}/g },
  { name: 'github-pat-classic', pattern: /pat_[a-zA-Z0-9_-]{20,}/g },
  { name: 'aws-access-key', pattern: /AKIA[A-Z0-9]{16}/g },
  { name: 'http-bearer', pattern: /Bearer [A-Za-z0-9_\-.=]{20,}/g },
  { name: 'slack-bot', pattern: /xoxb-[a-zA-Z0-9_-]{20,}/g },
  { name: 'github-pat-fine', pattern: /ghp_[a-zA-Z0-9]{36,}/g },
  { name: 'gitlab-pat', pattern: /glpat-[a-zA-Z0-9_-]{20,}/g },
];

export interface SanitizeResult {
  text: string;
  hits: Array<{ pattern: string; count: number }>;
}

export function sanitize(input: string): SanitizeResult {
  let text = input;
  const hits: SanitizeResult['hits'] = [];
  for (const { name, pattern } of SECRET_PATTERNS) {
    const matches = text.match(pattern);
    if (matches && matches.length > 0) {
      hits.push({ pattern: name, count: matches.length });
      text = text.replace(pattern, '[REDACTED]');
    }
  }
  return { text, hits };
}

// Convenience: just get sanitized text (drop hits info)
export function sanitizeText(input: string): string {
  return sanitize(input).text;
}
