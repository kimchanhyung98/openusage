// Customize의 provider 12곳과 각 provider의 지표 목록.
// 손으로 적는 것은 앱 소스에 그대로 있는 두 가지뿐 — widgetDescriptors 선언 순서, DefaultLayout의 세 배열.
// 켜짐·섹션·별은 전부 그 배열에서 판정. 셋을 따로 적으면 지표가 늘 때마다 서로 어긋남.
// L1 부제의 "N metrics"도 이 목록을 세어 만듦(registry.descriptors(for:).count).

/** Providers/<Name>/<Name>Provider.swift의 widgetDescriptors 선언 순서. 뒤 3개가 있으면 spendTiles. */
const declared: Record<string, Array<[string, string]>> = {
  claude: [
    ['claude.session', 'Session'],
    ['claude.weekly', 'Weekly'],
    ['claude.fable', 'Fable'],
    ['claude.trend', 'Usage Trend'],
    ['claude.extra', 'Extra Usage'],
    ['claude.sonnet', 'Sonnet'],
    ['claude.today', 'Today'],
    ['claude.yesterday', 'Yesterday'],
    ['claude.last30', 'Last 30 Days'],
  ],
  codex: [
    ['codex.session', 'Session'],
    ['codex.weekly', 'Weekly'],
    ['codex.trend', 'Usage Trend'],
    ['codex.resetWatch', 'Reset Watch'],
    ['codex.rateLimitResets', 'Rate Limit Resets'],
    ['codex.spark', 'Spark'],
    ['codex.sparkWeekly', 'Spark Weekly'],
    ['codex.credits', 'Extra Usage'],
    ['codex.today', 'Today'],
    ['codex.yesterday', 'Yesterday'],
    ['codex.last30', 'Last 30 Days'],
  ],
  cursor: [
    ['cursor.usage', 'Total Usage'],
    ['cursor.auto', 'Auto Usage'],
    ['cursor.api', 'API Usage'],
    ['cursor.onDemand', 'Extra Usage'],
    ['cursor.requests', 'Requests'],
    ['cursor.credits', 'Credits'],
    ['cursor.trend', 'Usage Trend'],
    ['cursor.today', 'Today'],
    ['cursor.yesterday', 'Yesterday'],
    ['cursor.last30', 'Last 30 Days'],
  ],
  // spendTiles 없음.
  antigravity: [
    ['antigravity.geminiPro', 'Session'],
    ['antigravity.geminiWeekly', 'Weekly'],
    ['antigravity.claude', 'Claude'],
    ['antigravity.claudeWeekly', 'Claude Weekly'],
  ],
  copilot: [
    ['copilot.premium', 'Credits'],
    ['copilot.extra', 'Extra Usage'],
    ['copilot.orgCredits', 'Org Credits'],
    ['copilot.orgSpend', 'Org Spend'],
    ['copilot.chat', 'Chat'],
    ['copilot.completions', 'Completions'],
  ],
  devin: [
    ['devin.daily', 'Daily'],
    ['devin.weekly', 'Weekly'],
    ['devin.extra', 'Extra Balance'],
  ],
  grok: [
    ['grok.weekly', 'Weekly'],
    ['grok.payAsYouGo', 'Extra Usage'],
    ['grok.trend', 'Usage Trend'],
    ['grok.today', 'Today'],
    ['grok.yesterday', 'Yesterday'],
    ['grok.last30', 'Last 30 Days'],
  ],
  kimi: [
    ['kimi.session', 'Session'],
    ['kimi.weekly', 'Weekly'],
  ],
  kiro: [['kiro.credits', 'Credits']],
  opencode: [
    ['opencode.session', 'Session'],
    ['opencode.weekly', 'Weekly'],
    ['opencode.monthly', 'Monthly'],
    ['opencode.trend', 'Usage Trend'],
    ['opencode.today', 'Today'],
    ['opencode.yesterday', 'Yesterday'],
    ['opencode.last30', 'Last 30 Days'],
  ],
  // Today·This Week·This Month는 spendTiles가 아니라 API spend 값.
  openrouter: [
    ['openrouter.credits', 'Credits'],
    ['openrouter.balance', 'Balance'],
    ['openrouter.today', 'Today'],
    ['openrouter.week', 'This Week'],
    ['openrouter.month', 'This Month'],
    ['openrouter.keyLimit', 'Key Limit'],
  ],
  zai: [
    ['zai.session', 'Session'],
    ['zai.weekly', 'Weekly'],
    ['zai.webSearches', 'Web Searches'],
  ],
};

// 아래 세 배열은 Stores/DefaultLayout.swift에서 그대로 옮긴 것.

/** DefaultLayout.metricIDs — 최초 실행 시 스위치가 켜진 지표. */
const enabledIDs = new Set([
  'antigravity.geminiPro', 'antigravity.geminiWeekly', 'antigravity.claude', 'antigravity.claudeWeekly',
  'claude.session', 'claude.weekly', 'claude.fable', 'claude.trend', 'claude.today', 'claude.yesterday',
  'codex.session', 'codex.weekly', 'codex.trend', 'codex.rateLimitResets', 'codex.today', 'codex.yesterday',
  'cursor.usage', 'cursor.auto', 'cursor.api', 'cursor.trend',
  'cursor.onDemand', 'cursor.today', 'cursor.yesterday', 'cursor.last30',
  'copilot.premium', 'copilot.extra', 'copilot.orgCredits', 'copilot.orgSpend',
  'copilot.chat', 'copilot.completions',
  'devin.daily', 'devin.weekly', 'devin.extra',
  'grok.weekly', 'grok.trend', 'grok.payAsYouGo', 'grok.today', 'grok.yesterday', 'grok.last30',
  'kimi.session', 'kimi.weekly',
  'kiro.credits',
  'opencode.session', 'opencode.weekly', 'opencode.monthly', 'opencode.trend',
  'opencode.today', 'opencode.yesterday', 'opencode.last30',
  'openrouter.credits', 'openrouter.balance',
  'openrouter.today', 'openrouter.week', 'openrouter.month', 'openrouter.keyLimit',
  'zai.session', 'zai.weekly', 'zai.webSearches',
]);

/** DefaultLayout.expandedMetricIDs — On Demand 섹션 소속. 켜짐 여부와 무관한 별개 축. */
const onDemandIDs = new Set([
  'antigravity.claude', 'antigravity.claudeWeekly',
  'claude.trend', 'claude.extra', 'claude.sonnet',
  'claude.today', 'claude.yesterday', 'claude.last30',
  'codex.trend', 'codex.resetWatch', 'codex.rateLimitResets', 'codex.spark', 'codex.sparkWeekly',
  'codex.credits', 'codex.today', 'codex.yesterday', 'codex.last30',
  'cursor.onDemand', 'cursor.requests', 'cursor.credits',
  'cursor.today', 'cursor.yesterday', 'cursor.last30',
  'copilot.orgCredits', 'copilot.orgSpend', 'copilot.chat', 'copilot.completions',
  'devin.extra',
  'grok.payAsYouGo', 'grok.today', 'grok.yesterday', 'grok.last30',
  'opencode.today', 'opencode.yesterday', 'opencode.last30',
  'openrouter.today', 'openrouter.week', 'openrouter.month', 'openrouter.keyLimit',
  'zai.webSearches',
]);

/** DefaultLayout.pinnedMetricIDs — 별이 채워진 채로 시작하는 지표. */
const pinnedIDs = new Set([
  'antigravity.geminiPro', 'antigravity.geminiWeekly',
  'claude.weekly',
  'codex.weekly',
  'cursor.auto', 'cursor.api',
  'copilot.premium',
  'kimi.weekly',
  'kiro.credits',
  'openrouter.credits',
  'zai.session', 'zai.weekly',
]);

export interface MetricRow {
  id: string;
  title: string;
  enabled: boolean;
  starred: boolean;
  /** tray가 차트를 못 그려 Usage Trend만 별이 아예 없음. WidgetDescriptor+Factories.swift:153-157. */
  pinnable: boolean;
}

export interface ProviderMetrics {
  alwaysVisible: MetricRow[];
  onDemand: MetricRow[];
  /** L1 부제 "N metrics"의 N. */
  count: number;
}

/**
 * 이 페이지의 데모 상태에서만 기본값과 다르게 켜 두는 지표.
 * 대시보드에 그 행을 보여 주려면 L2 스위치도 켜져 있어야 두 화면이 어긋나지 않음.
 */
export const demoEnabledMetrics = new Set(['codex.resetWatch']);

function row([id, title]: [string, string]): MetricRow {
  return {
    id,
    title,
    enabled: enabledIDs.has(id) || demoEnabledMetrics.has(id),
    starred: pinnedIDs.has(id),
    pinnable: !id.endsWith('.trend'),
  };
}

export const providerMetrics: Record<string, ProviderMetrics> = Object.fromEntries(
  Object.entries(declared).map(([provider, list]) => {
    const rows = list.map(row);
    return [provider, {
      alwaysVisible: rows.filter((r) => !onDemandIDs.has(r.id)),
      onDemand: rows.filter((r) => onDemandIDs.has(r.id)),
      count: rows.length,
    }];
  }),
);

/** LayoutStore.maxPinsPerProvider. 초과 시 별이 켜지지 않고 거절 알림만 뜸. */
export const maxPins = 2;

/** 대시보드 행 라벨 → 지표 id. 라벨이 곧 WidgetDescriptor.title이라 그대로 맞물림. */
export function metricID(provider: string, title: string): string | undefined {
  return declared[provider]?.find(([, t]) => t === title)?.[0];
}
