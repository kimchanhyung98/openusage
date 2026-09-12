// 공개용 예시 사용량. 계정명·상태는 공통 예시 계정 목록에서 가져옴.
// 손으로 적는 것은 앱이 실제로 받는 입력(used/limit/경과율/시각)뿐.
// 심각도·pace 문구·헤드라인은 demo.ts의 paceView/boundedView가 앱 규칙대로 계산.
import type { Row } from './demo';
import { providerMetrics } from './metrics';
import { accountFamilies, type DemoAccount } from './accounts';

export interface QuickLink {
  label: string;
  href: string;
}

export interface Card {
  id: string;
  icon: string;
  /** 지표 id의 앞부분(ProviderAccountID.family). 마크 이름과 우연히 같아도 별개 축이라 따로 적음. */
  provider: string;
  /** Single Card 모드의 카드 제목 — family 이름 그대로. AppContainer.accountCardTitle. */
  title: string;
  /** ProviderPlanBadge. 배지가 아니라 .secondary 평문. 없으면 렌더하지 않음. */
  plan?: string;
  /** 등록 계정이 둘 이상이면 Single Card의 헤더 선택기 표시. */
  account?: string;
  accountID?: string;
  accountOptions?: DemoAccount[];
  always: Row[];
  onDemand: Row[];
  links: QuickLink[];
}

/** 예시 값이 없는 지표도 Customize에서 켤 수 있도록 No data 행 준비. */
export function completeCard(card: Card): Card {
  const metrics = providerMetrics[card.provider];
  const complete = (rows: Row[], descriptors: Array<{ title: string }>): Row[] => descriptors.map((metric) =>
    rows.find((row) => row.label === metric.title) ?? { kind: 'text', label: metric.title, values: ['No data'] });
  return {
    ...card,
    always: complete(card.always, metrics.alwaysVisible),
    onDemand: complete(card.onDemand, metrics.onDemand),
  };
}

// elapsed는 pace 투영(used / elapsed)의 입력이라 화면 문구를 되돌려 정한 값.
// 예: Session 3% 사용에 elapsed 0.0423 → 투영 71 → "~29% left at reset".
export const cards: Card[] = [
  {
    id: 'claude',
    icon: 'claude',
    provider: 'claude',
    title: 'Claude',
    plan: 'Max 20x',
    always: [
      // 여유 있게 소비 중 — 파랑.
      { kind: 'bounded', label: 'Session', used: 3, limit: 100, elapsed: 0.0423,
        resetAbsolute: 'Resets today at 18:20', resetRelative: 'Resets in 5h 12m' },
      // 76% 사용이지만 소비 속도가 완만해 한도 안 착지 — 절대 구간(80%) 미만이라 파랑.
      { kind: 'bounded', label: 'Weekly', used: 76, limit: 100, elapsed: 0.987,
        resetAbsolute: 'Resets today at 16:00', resetRelative: 'Resets in 2h 52m' },
      // 남은 양이 표시 정밀도에서 0 — Limit reached.
      { kind: 'bounded', label: 'Fable', used: 100, limit: 100, elapsed: 0.987,
        resetAbsolute: 'Resets today at 16:00', resetRelative: 'Resets in 2h 52m' },
    ],
    onDemand: [
      { kind: 'trend', label: 'Usage Trend', bars: [0.35, 0.52, 0.28, 0.71, 0.44, 0.88, 0.63] },
      { kind: 'text', label: 'Today', values: ['$4.08', '560K tokens'] },
      { kind: 'text', label: 'Yesterday', values: ['$12.50', '1.7M tokens'] },
    ],
    links: [
      { label: 'Status', href: 'https://status.claude.com/' },
      { label: 'Dashboard', href: 'https://claude.ai/settings/usage' },
    ],
  },
  {
    id: 'codex',
    icon: 'codex',
    provider: 'codex',
    title: 'Codex',
    plan: 'Pro 20x',
    always: [
      { kind: 'bounded', label: 'Session', used: 28, limit: 100, elapsed: 0.31,
        resetAbsolute: 'Resets today at 21:00', resetRelative: 'Resets in 6h 0m' },
      // 리셋 전에 한도 초과 예상 — 빨강 + 소진 예상 시각.
      { kind: 'bounded', label: 'Weekly', used: 97, limit: 100, elapsed: 0.9, runOutAt: 'today at 15:07',
        resetAbsolute: 'Resets Sep 15 at 10:23', resetRelative: 'Resets in 4d 17h' },
    ],
    onDemand: [
      { kind: 'trend', label: 'Usage Trend', bars: [0.61, 0.44, 0.79, 0.35, 0.92, 0.58, 0.7] },
      // 값이 아직 없는 forecast 행 — em dash + No data.
      { kind: 'bounded', label: 'Reset Watch', used: 0, limit: 100, elapsed: 0, noData: true },
      { kind: 'text', label: 'Rate Limit Resets', values: ['2 resets'] },
      { kind: 'text', label: 'Today', values: ['$2.31', '690K tokens'] },
      { kind: 'text', label: 'Yesterday', values: ['$3.44', '910K tokens'] },
    ],
    links: [
      { label: 'Status', href: 'https://status.openai.com/' },
      { label: 'Dashboard', href: 'https://platform.openai.com/usage' },
    ],
  },
  {
    id: 'antigravity',
    icon: 'antigravity',
    provider: 'antigravity',
    // 계정 family가 아니라 헤더에 선택 메뉴가 없음. plan 값도 없음.
    title: 'Antigravity',
    always: [
      // 아직 첫 메시지를 보내지 않은 session 창.
      { kind: 'bounded', label: 'Session', used: 0, limit: 100, elapsed: 0, notStarted: true },
      { kind: 'bounded', label: 'Weekly', used: 16, limit: 100, elapsed: 0.889,
        resetAbsolute: 'Resets tomorrow at 09:35', resetRelative: 'Resets in 19h 44m' },
    ],
    onDemand: [
      { kind: 'bounded', label: 'Claude', used: 41, limit: 100, elapsed: 0.62,
        resetAbsolute: 'Resets tomorrow at 09:35', resetRelative: 'Resets in 19h 44m' },
      { kind: 'bounded', label: 'Claude Weekly', used: 58, limit: 100, elapsed: 0.889,
        resetAbsolute: 'Resets tomorrow at 09:35', resetRelative: 'Resets in 19h 44m' },
    ],
    links: [],
  },
];

export function accountCardVariants(card: Card): Card[] {
  const family = accountFamilies.find((entry) => entry.id === card.provider);
  if (!family) return [card];
  return family.profiles.map((profile, index) => ({
    ...card,
    id: `${card.id}-${profile.id}`,
    accountID: profile.id,
    account: profile.name,
    accountOptions: family.profiles,
    always: index === 0 ? card.always : card.always.map((row, position) => row.kind === 'bounded'
      ? { ...row, used: [42, 35, 18][position % 3], elapsed: 0.65, runOutAt: undefined }
      : row),
    onDemand: index === 0 ? card.onDemand : card.onDemand.map((row) => row.kind === 'text' && row.label === 'Today'
      ? { ...row, values: ['$1.26', '120K tokens'] } : row),
  }));
}

/**
 * Customize에서 켰지만 아직 자료가 없는 provider의 카드.
 * 실제 한도·사용량을 꾸며 넣지 않고 모든 지표를 No data 텍스트로 준비.
 */
export function emptyCard(id: string, name: string): Card {
  return completeCard({
    id,
    icon: id,
    provider: id,
    title: name,
    always: [],
    onDemand: [],
    links: [],
  });
}
