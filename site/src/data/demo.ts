// 앱 재현 그래픽의 데모 입력값과 파생 규칙.
// 원칙 — 손으로 적는 것은 앱이 실제로 받는 입력뿐이고, 화면에 보이는 문자열은 전부 여기서 계산.
// 라벨을 직접 적으면 상태가 늘어날 때마다 어긋남.
import { providerMetrics } from './metrics';
import { providers } from './providers';
import { cards } from './dashboard';

// ---------- 포맷터. 전부 en_US 고정 — 앱이 로케일과 무관하게 en_US로 찍음 ----------

const EN = 'en-US';

/** 1000 이상은 K/M/B 축약, 소수 0~1자리. MetricFormatter .tray/.row 규칙. */
export function compact(v: number): string {
  return v.toLocaleString(EN, { notation: 'compact', compactDisplay: 'short', maximumFractionDigits: 1 });
}

/** 소수 2자리 통화. MetricFormatter .full 규칙. */
export function currency2(v: number): string {
  return v.toLocaleString(EN, { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/** 정수 달러. 1000 이상은 축약. MetricFormatter .tray 규칙. */
export function trayDollars(v: number): string {
  return Math.abs(v) >= 1000 ? `$${compact(v)}` : `$${Math.round(v).toLocaleString(EN)}`;
}

/** 소수 0~1자리 수. */
export function num1(v: number): string {
  return v.toLocaleString(EN, { maximumFractionDigits: 1 });
}

// ---------- 지표 행 ----------

export type Severity = 'normal' | 'warning' | 'critical' | 'neutral';

/** bounded 행. 앱이 받는 입력은 used/limit/기간 경과율뿐이고 심각도·페이스 문구는 파생. */
export interface BoundedRow {
  kind: 'bounded';
  label: string;
  used: number;
  limit: number;
  /** 리셋 주기 중 지난 비율 0~1. pace 눈금 위치이자 소진 투영의 입력. */
  elapsed: number;
  /** behind일 때 보여 줄 소진 예상 시각. 시각은 파생할 수 없어 입력. */
  runOutAt?: string;
  /** 리셋 문구 두 형태. Exact Time이 기본. 특수 상태에서는 없음. */
  resetAbsolute?: string;
  resetRelative?: string;
  /** 값이 없는 행 — 헤드라인 em dash, 오른쪽 "No data", 회색 빈 트랙. WidgetData.noDataHeadline. */
  noData?: boolean;
  /** 아직 시작하지 않은 session 창(isFreshSessionWindow) — 오른쪽이 리셋 시각 대신 "Not started", pace 없음. */
  notStarted?: boolean;
}

/** 텍스트 전용 행. combined spend tile은 값 여러 개를 " · "로 이음. */
export interface TextRow {
  kind: 'text';
  label: string;
  values: string[];
}

/** Usage Trend 스파크라인. 값은 일자별 상대 높이 0~1. */
export interface TrendRow {
  kind: 'trend';
  label: string;
  bars: number[];
}

export type Row = BoundedRow | TextRow | TrendRow;

/**
 * 기간 종료 시점 사용량 투영과 그로부터 나오는 심각도·문구. Support/Pace.swift + WidgetData.meterState.
 * 투영 = used / elapsed. 여유 10% 이상이면 ahead, 한도 안에 착지하면 onTrack, 넘기면 behind.
 * 색은 pace 판정이 절대 구간(80%·90%)보다 우선. 표시 mode와는 무관.
 */
export function paceView(r: BoundedRow): { severity: Severity; pace: string; flame?: 'critical' } {
  // meterState 순서상 noData(1단계)와 fresh session(4단계)이 pace(5단계)보다 먼저라 여기서도 먼저 끊음.
  if (r.noData) return { severity: 'neutral', pace: '' };
  if (r.notStarted) return { severity: 'normal', pace: '' };
  const projected = r.elapsed > 0 ? (r.used / r.elapsed) : r.used;
  const band: Severity = r.used / r.limit >= 0.9 ? 'critical' : r.used / r.limit >= 0.8 ? 'warning' : 'normal';
  const sparePct = Math.round(((r.limit - projected) / r.limit) * 100);

  if (r.used >= r.limit) return { severity: 'critical', pace: 'Limit reached', flame: 'critical' };
  if (projected > r.limit) {
    return { severity: 'critical', pace: r.runOutAt ? `Limit ${r.runOutAt}` : '', flame: 'critical' };
  }
  if (projected > r.limit * 0.9) return { severity: 'warning', pace: `~${sparePct}% spare` };
  return { severity: band, pace: `~${sparePct}% left at reset` };
}

/** bounded 행의 표시 상태를 mode에 따라 계산. 앱의 displayedValue/fraction/paceTick 규칙 그대로. */
export function boundedView(r: BoundedRow, mode: 'used' | 'left') {
  // 값이 없으면 mode와 무관하게 em dash + 빈 트랙. tick -1은 "눈금 없음".
  if (r.noData) return { headline: '—', fill: 0, tick: -1, opposite: '' };
  const shown = mode === 'left' ? Math.max(0, r.limit - r.used) : r.used;
  const pct = Math.round((shown / r.limit) * 100);
  if (r.notStarted) return { headline: `${pct}% ${mode === 'left' ? 'left' : 'used'}`, fill: pct, tick: -1, opposite: '' };
  return {
    headline: `${Math.round(shown)}% ${mode === 'left' ? 'left' : 'used'}`,
    /** 막대 채움 — mode에 따라 반전됨. 색은 반전되지 않음. */
    fill: pct,
    /** pace 눈금 — mode에 따라 미러링됨. */
    tick: Math.round((mode === 'left' ? 1 - r.elapsed : r.elapsed) * 100),
    /** 반대 mode 문구. 앱은 hover tooltip으로 보여 줌. */
    opposite: `${Math.round(mode === 'left' ? r.used : r.limit - r.used)}% ${mode === 'left' ? 'used' : 'left'}`,
  };
}

export const appVersion = '0.11.1';

export type { QuickLink, Card } from './dashboard';
export { cards } from './dashboard';

// ---------- Total Spend 카드 ----------

export const spendPeriods = [
  { id: 'today', segment: 'Today', full: 'Today' },
  { id: 'yesterday', segment: 'Yesterday', full: 'Yesterday' },
  { id: 'last30', segment: '30 Days', full: 'Last 30 Days' },
] as const;

export const spendMetrics = [
  { id: 'cost', title: 'Cost', empty: 'No cost data for this period' },
  { id: 'costPerMtok', title: 'Cost/MTok', empty: 'No cost-per-token data for this period' },
  { id: 'tokens', title: 'Tokens', empty: 'No token data for this period' },
] as const;

export type SpendPeriodId = (typeof spendPeriods)[number]['id'];
export type SpendMetricId = (typeof spendMetrics)[number]['id'];

export const spendProviders = [
  { id: 'claude', title: 'Claude' },
  { id: 'codex', title: 'Codex' },
  { id: 'cursor', title: 'Cursor' },
];

/**
 * 유일한 손입력. provider·기간별 usd와 token 수.
 * 어떤 기간에 항목이 없으면 그 기간에서 빠지는 것이지 0으로 두는 것이 아님 — 앱이 둘을 구분함.
 * Cursor는 로컬 로그에 토큰 수가 없어 usd만 있음. 지표별 포함 조건이 다른 것을 그대로 보여 줌.
 */
export const spendInput: Record<SpendPeriodId, Record<string, { usd: number; tokens: number }>> = {
  today: {
    claude: { usd: 4.08, tokens: 560_000 },
    codex: { usd: 2.31, tokens: 690_000 },
  },
  yesterday: {
    claude: { usd: 12.5, tokens: 1_720_000 },
    codex: { usd: 3.44, tokens: 910_000 },
    cursor: { usd: 0.7, tokens: 0 },
  },
  last30: {
    claude: { usd: 128.4, tokens: 17_830_000 },
    codex: { usd: 96.12, tokens: 19_330_000 },
    cursor: { usd: 21.0, tokens: 0 },
  },
};

export interface SpendSlice {
  id: string;
  title: string;
  amount: number;
  value: string;
  share: number;
}

export interface SpendView {
  slices: SpendSlice[];
  center: string;
  unit: string;
  empty?: string;
}

const MIN_SHARE = 0.025; // RingSectorShape.minimumSliceShare

/** 토큰 합계를 자릿수 낱말과 스케일 값 두 줄로. MetricFormatter 규칙. */
function tokenCenter(total: number): { center: string; unit: string } {
  const a = Math.abs(total);
  if (a >= 1e9) return { center: num1(total / 1e9), unit: 'billion' };
  if (a >= 1e6) return { center: num1(total / 1e6), unit: 'million' };
  if (a >= 1e3) return { center: num1(total / 1e3), unit: 'thousand' };
  return { center: num1(total), unit: 'tokens' };
}

/** 기간·지표 조합 하나의 표시 상태를 계산. 포함 조건·순위·합계 모두 앱 규칙 그대로. */
export function spendView(period: SpendPeriodId, metric: SpendMetricId): SpendView {
  const row = spendInput[period];
  const picked = spendProviders
    .filter((p) => row[p.id])
    .map((p) => ({ p, usd: row[p.id].usd, tokens: row[p.id].tokens }))
    .filter(({ usd, tokens }) =>
      metric === 'cost' ? usd > 0 : metric === 'tokens' ? tokens > 0 : usd > 0 && tokens > 0,
    )
    .map(({ p, usd, tokens }) => ({
      id: p.id,
      title: p.title,
      amount: metric === 'cost' ? usd : metric === 'tokens' ? tokens : (usd / tokens) * 1e6,
      usd,
      tokens,
    }))
    .sort((a, b) => b.amount - a.amount || a.title.localeCompare(b.title, EN, { numeric: true }));

  const def = spendMetrics.find((m) => m.id === metric)!;
  if (!picked.length) return { slices: [], center: '', unit: '', empty: def.empty };

  const totalUsd = picked.reduce((s, x) => s + x.usd, 0);
  const totalTokens = picked.reduce((s, x) => s + x.tokens, 0);
  const sum = picked.reduce((s, x) => s + x.amount, 0);
  const floored = picked.map((x) => Math.max(x.amount / sum, MIN_SHARE));
  const norm = floored.reduce((s, x) => s + x, 0);

  const value = (x: (typeof picked)[number]) =>
    metric === 'cost' ? currency2(x.usd)
      : metric === 'tokens' ? compact(x.tokens)
        : `${currency2(x.amount)}/MTok`;

  const head =
    metric === 'cost' ? { center: trayDollars(totalUsd), unit: 'dollars' }
      : metric === 'tokens' ? tokenCenter(totalTokens)
        : { center: currency2(totalTokens ? (totalUsd / totalTokens) * 1e6 : 0), unit: 'MTok' };

  return {
    ...head,
    slices: picked.map((x, i) => ({
      id: x.id,
      title: x.title,
      amount: x.amount,
      value: value(x),
      share: floored[i] / norm,
    })),
  };
}

// ---------- 메뉴 막대 스트립 ----------

// 별표된 지표만 올라감. 기본은 provider마다 Weekly 하나.
const stripGroups = cards.filter((card) => card.provider === 'claude' || card.provider === 'codex').map((card) => ({
  icon: card.icon,
  fractions: card.always.flatMap((row) => row.kind === 'bounded' && providerMetrics[card.provider].alwaysVisible.some((metric) => metric.starred && metric.title === row.label) ? [row.used / row.limit] : []),
}));

export const strip = {
  text: stripGroups.map((group) => ({ icon: group.icon, values: group.fractions.map((fraction) => `${Math.round(fraction * 100)}%`) })),
  bars: stripGroups.flatMap((group) => group.fractions),
};

// ---------- Customize L1 ----------

// 부제의 metrics 수는 켜진 수가 아니라 provider가 가진 전체 지표 수 —
// LayoutStore+Customization.metricCount = registry.descriptors(for:).count.
// metrics.ts의 선언 목록에서 세므로 지표가 늘면 목록과 수가 같이 움직임.
// 앱은 항상 복수형 "N metrics"로 찍고 단수 분기가 없음(ProviderListRow.swift:31).
// 켜짐 여부는 최초 실행 시 Mac에서 발견된 도구에 따라 정해지는 사용자 상태(ProviderEnablementStore).
// 여기서는 앱 실제 화면과 같은 조합(Claude·Codex·Antigravity)을 씀.
const enabledProviders = new Set(['claude', 'codex', 'antigravity']);

export const customize = providers.map((p) => ({
  id: p.id,
  name: p.name,
  on: enabledProviders.has(p.id),
  metrics: providerMetrics[p.id].count,
}));
