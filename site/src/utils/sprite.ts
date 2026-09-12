// 앱 리소스 SVG를 인라인 sprite <symbol>로 변환.
// 출처는 앱이 쓰는 파일 그 자체 — 사본을 두지 않아 마크가 앱과 어긋날 수 없음.
// fill 속성은 none만 남기고 제거해 currentColor로 통일.
// openusage.svg(앱 아이콘 글리프)는 상표 결정 전까지 sprite에 넣지 않음(providers.ts에 없음).
import { providers } from '../data/providers';

const files = import.meta.glob('../../../Sources/OpenUsage/Resources/ProviderIcons/*.svg', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const wanted = new Set<string>(providers.map((p) => p.id));

export interface SpriteSymbol {
  id: string;
  viewBox: string;
  body: string;
}

export function providerSymbols(): SpriteSymbol[] {
  return Object.entries(files)
    .map(([path, svg]) => {
      const id = path.split('/').pop()!.replace(/\.svg$/, '');
      const viewBox = svg.match(/viewBox="([^"]+)"/)?.[1] ?? '0 0 24 24';
      const body = svg
        .replace(/^[\s\S]*?<svg[^>]*>/, '')
        .replace(/<\/svg>\s*$/, '')
        .replace(/\sfill="(?!none")[^"]*"/g, '')
        .trim();
      return { id, viewBox, body };
    })
    .filter((s) => wanted.has(s.id))
    .sort((a, b) => a.id.localeCompare(b.id));
}
