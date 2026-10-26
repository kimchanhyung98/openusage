export type PreviewLocale = 'en' | 'ko' | 'ja';
export type TranslationTable = Record<string, string>;

export function parseStrings(source: string): TranslationTable {
  return Object.fromEntries(Array.from(source.matchAll(/("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");/g),
    (match) => [JSON.parse(match[1]), JSON.parse(match[2])]));
}

const placeholder = /%(?:(\d+)\$)?(@|lld|d|s|%)/g;
const escapePattern = (text: string): string => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export function createTranslator(table: TranslationTable, locale: PreviewLocale): (text: string) => string {
  const templates = Object.entries(table).filter(([key]) => key.includes('%') && key !== '%@ %@').map(([key, value]) => {
    let start = 0;
    let pattern = '^';
    for (const match of key.matchAll(placeholder)) {
      pattern += escapePattern(key.slice(start, match.index));
      pattern += match[2] === '%' ? '%' : ['d', 'lld'].includes(match[2]) ? '(\\d+)' : '(.+?)';
      start = match.index + match[0].length;
    }
    pattern += escapePattern(key.slice(start)) + '$';
    const numericArguments = key.match(/%(?:\d+\$)?(?:lld|d)/g)?.length ?? 0;
    return { pattern: new RegExp(pattern), value,
      weight: (key.startsWith('%') ? 0 : 1000) + key.replace(placeholder, '').length + numericArguments / 10 };
  }).sort((a, b) => b.weight - a.weight);

  const translate = (text: string, depth = 0): string => {
    if (locale === 'en' || depth > 8) return text;
    if (Object.hasOwn(table, text) && !text.includes('%@')) return table[text];
    const parts = text.split(/( · | \/ )/);
    if (parts.length > 1) return parts.map((part) => translate(part, depth + 1)).join('');
    const date = text.match(/^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{1,2})(?: at (.+))?$/);
    if (date) {
      const month = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'].indexOf(date[1]) + 1;
      const day = locale === 'ko' ? `${month}월 ${date[2]}일` : `${month}月${date[2]}日`;
      return date[3] ? `${day} ${translate(date[3], depth + 1)}` : day;
    }
    for (const template of templates) {
      const match = text.match(template.pattern);
      if (!match) continue;
      let argument = 0;
      return template.value.replace(placeholder, (_, position: string | undefined, kind: string) => {
        if (kind === '%') return '%';
        const index = position ? Number(position) : ++argument;
        return translate(match[index] ?? '', depth + 1);
      });
    }
    return text;
  };
  return (text) => {
    const trimmed = text.trim();
    return trimmed ? text.replace(trimmed, translate(trimmed)) : text;
  };
}
