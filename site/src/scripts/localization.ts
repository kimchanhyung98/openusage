import { createTranslator, parseStrings, type PreviewLocale, type TranslationTable } from '../data/preview-locale';
import { previewTranslations } from '../data/preview-translations';

const sources = import.meta.glob('../../../Sources/OpenUsage/Resources/Localization/{ko,ja}.lproj/*.strings', {
  query: '?raw', import: 'default', eager: true,
});
const tables: Record<string, TranslationTable> = {};
for (const [path, source] of Object.entries(sources)) {
  const [, locale, table] = path.match(/\/(ko|ja)\.lproj\/(\w+)\.strings$/)!;
  tables[`${locale}:${table}`] = parseStrings(source as string);
}
const translators = new Map<string, (text: string) => string>();
const order = ['Common', 'Errors', 'Accounts', 'Customize', 'Dashboard', 'Metrics', 'Settings'];
function translator(locale: PreviewLocale, context: string): (text: string) => string {
  const key = `${locale}:${context}`;
  if (!translators.has(key)) {
    const table = Object.assign({}, ...order.map((name) => tables[`${locale}:${name}`]), tables[key]);
    if (locale !== 'en') for (const [source, values] of Object.entries(previewTranslations)) table[source] = values[locale];
    translators.set(key, createTranslator(table, locale));
  }
  return translators.get(key)!;
}

interface SourceValue { source: string; rendered: string }
const textSources = new WeakMap<Text, SourceValue>();
const attributeSources = new WeakMap<Element, Map<string, SourceValue>>();
let currentLocale: PreviewLocale = 'en';

function sourceValue(previous: SourceValue | undefined, value: string): SourceValue {
  return previous?.rendered === value ? previous : { source: value, rendered: value };
}

function contextFor(element: Element): string {
  if (element.closest('[data-scr="settings"]')) return 'Settings';
  if (element.closest('[data-tour-sheet]')) return 'Accounts';
  if (element.closest('[data-scr^="metrics:"], [data-scr="customize"]')) return 'Customize';
  return 'Dashboard';
}

/** 영어 원문을 보존하여 언어 전환과 설정 재표시 이후에도 같은 DOM 번역. */
export function localizePreview(root: HTMLElement): void {
  root.lang = currentLocale;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let node: Node | null;
  while ((node = walker.nextNode())) {
    const text = node as Text;
    const element = text.parentElement!;
    if (element.closest('[data-pick="language"], [data-picker="language"], script, style, code')) continue;
    const value = sourceValue(textSources.get(text), text.data);
    value.rendered = translator(currentLocale, contextFor(element))(value.source);
    if (text.data !== value.rendered) text.data = value.rendered;
    textSources.set(text, value);
  }
  for (const element of [root, ...root.querySelectorAll<HTMLElement>('[aria-label], [title], [placeholder]')]) {
    const values = attributeSources.get(element) ?? new Map<string, SourceValue>();
    for (const attribute of ['aria-label', 'title', 'placeholder']) {
      const content = element.getAttribute(attribute);
      if (!content) continue;
      const value = sourceValue(values.get(attribute), content);
      value.rendered = translator(currentLocale, contextFor(element))(value.source);
      if (content !== value.rendered) element.setAttribute(attribute, value.rendered);
      values.set(attribute, value);
    }
    attributeSources.set(element, values);
  }
}

export function applyPreviewLanguage(language: string): void {
  currentLocale = language === '한국어' ? 'ko' : language === '日本語' ? 'ja' : 'en';
  document.querySelectorAll<HTMLElement>('[data-tour-mock] [data-picker="language"] [data-picker-value]').forEach((label) => {
    label.textContent = language;
    label.lang = currentLocale;
  });
  document.querySelectorAll<HTMLElement>('[data-tour-mock] [data-pick="language"]').forEach((option) => {
    option.setAttribute('aria-checked', String(option.dataset.value === language));
  });
  document.querySelectorAll<HTMLElement>('[data-mock], [data-tour-mock], [data-tour-sheet], [data-preview-label]').forEach(localizePreview);
}
