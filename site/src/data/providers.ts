// 앱 기본 순서(ProviderCatalog): Claude, Codex, Cursor, 이후 표시 이름 알파벳순.
export const providers = [
  { id: 'claude', name: 'Claude' },
  { id: 'codex', name: 'Codex' },
  { id: 'cursor', name: 'Cursor' },
  { id: 'antigravity', name: 'Antigravity' },
  { id: 'copilot', name: 'Copilot' },
  { id: 'devin', name: 'Devin' },
  { id: 'grok', name: 'Grok' },
  { id: 'kimi', name: 'Kimi' },
  { id: 'kiro', name: 'Kiro' },
  { id: 'opencode', name: 'OpenCode' },
  { id: 'openrouter', name: 'OpenRouter' },
  { id: 'zai', name: 'Z.ai' },
] as const;
