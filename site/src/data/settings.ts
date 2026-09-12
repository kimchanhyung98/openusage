// 배포 앱의 Settings 순서와 일반 상태 재현. 이스터에그·권한 오류·실행 중 상태는 기본 화면에서 숨김.
import { accountFamilies, type DemoAccountFamily } from './accounts.ts';

export type Control =
  | { kind: 'toggle'; on: boolean }
  | { kind: 'picker'; value: string; options: string[] }
  | { kind: 'action'; label: string; message: string };

export interface SettingRow {
  id: string;
  label: string;
  control: Control;
  /** 행 아래 도움말. */
  note?: string;
  /** 라벨 옆 info.circle. 눌리지 않는 이미지. */
  info?: boolean;
}

export interface SettingGroup {
  id: string;
  title: string;
  /** 제목 옆 accessory — Accounts는 plus.circle 버튼, iCloud Sync는 info.circle. */
  accessory?: 'add' | 'info' | 'manage';
  rows: SettingRow[];
  /** Accounts 섹션에만 있는 family 하위 카드. */
  families?: DemoAccountFamily[];
}

export const settingGroups: SettingGroup[] = [
  {
    id: 'general',
    title: 'General',
    rows: [
      { id: 'showTotalSpend', label: 'Show Total Spend', control: { kind: 'toggle', on: true } },
      { id: 'launchAtLogin', label: 'Launch at Login', control: { kind: 'toggle', on: false } },
      { id: 'globalShortcut', label: 'Global Shortcut', control: { kind: 'action', label: 'Record Shortcut', message: 'Record a global shortcut in the Mac app.' } },
    ],
  },
  {
    id: 'accounts',
    title: 'Accounts',
    accessory: 'add',
    rows: [
      { id: 'usageCards', label: 'Usage Cards', control: { kind: 'picker', value: 'Single Card', options: ['Single Card', 'Separate Cards'] } },
    ],
    families: accountFamilies,
  },
  {
    id: 'icloud',
    title: 'iCloud Sync',
    accessory: 'info',
    rows: [
      {
        id: 'syncAcrossMacs',
        label: 'Sync Across Macs',
        control: { kind: 'toggle', on: false },
        note: 'Shares usage history through iCloud, so you can see one combined summary for all your Macs.',
      },
    ],
  },
  {
    id: 'appearance',
    title: 'Appearance',
    rows: [
      { id: 'iconStyle', label: 'Icon Style', control: { kind: 'picker', value: 'Bars', options: ['Text', 'Bars'] } },
      { id: 'theme', label: 'Theme', control: { kind: 'picker', value: 'System', options: ['System', 'Light', 'Dark'] } },
      { id: 'density', label: 'Density', control: { kind: 'picker', value: 'Compact', options: ['Default', 'Compact'] } },
      { id: 'timeFormat', label: 'Time Format', control: { kind: 'picker', value: '24-hour', options: ['Auto', '12-hour', '24-hour'] } },
      { id: 'increaseTransparency', label: 'Increase Transparency', control: { kind: 'toggle', on: false } },
    ],
  },
  {
    id: 'usageDisplay',
    title: 'Usage Display',
    rows: [
      // 이 두 개는 대시보드의 헤드라인·리셋 라벨과 같은 상태라 서로 반영됨.
      { id: 'showUsageAs', label: 'Show Usage As', control: { kind: 'picker', value: 'Used', options: ['Used', 'Left'] } },
      { id: 'resetTimes', label: 'Reset Times', control: { kind: 'picker', value: 'Exact Time', options: ['Countdown', 'Exact Time'] } },
      { id: 'alwaysShowPacing', label: 'Always Show Pacing', control: { kind: 'toggle', on: true }, info: true },
    ],
  },
  {
    id: 'notifications', title: 'Notifications',
    rows: [
      { id: 'underTenPercent', label: 'Almost Out', control: { kind: 'toggle', on: false }, info: true },
      { id: 'healthyToClose', label: 'Cutting It Close', control: { kind: 'toggle', on: false }, info: true },
      { id: 'closeToRunningOut', label: 'Will Run Out', control: { kind: 'toggle', on: false }, info: true },
    ],
  },
  {
    id: 'privacy', title: 'Privacy',
    rows: [
      { id: 'hideFromScreenShare', label: 'Hide From Screen Share', control: { kind: 'toggle', on: true },
        note: 'While your screen is shared or recorded, the menu bar shows “OpenUsage” instead of your usage.' },
      { id: 'shareAnonymousUsage', label: 'Share Anonymous Usage', control: { kind: 'toggle', on: false },
        note: 'Shares anonymous usage counts and error types to help improve OpenUsage. No account details, credentials, or usage values are sent.' },
    ],
  },
  {
    id: 'tokscale', title: 'Tokscale', accessory: 'manage',
    rows: [
      { id: 'usageSync', label: 'Usage Sync', info: true,
        control: { kind: 'action', label: 'Sync', message: 'Publish usage to your Tokscale profile from the Mac app. This preview does not upload data.' },
        note: 'Sync local usage to your public Tokscale profile.' },
    ],
  },
  {
    id: 'commandLine', title: 'Command Line',
    rows: [
      { id: 'terminalHelper', label: 'Terminal Helper',
        control: { kind: 'action', label: 'Install…', message: 'Install the terminal helper from the Mac app.' },
        note: 'Adds a global `openusage` command agents can use to monitor limits.' },
    ],
  },
  {
    id: 'advanced', title: 'Advanced',
    rows: [
      { id: 'logLevel', label: 'Log Level', control: { kind: 'picker', value: 'Info', options: ['Error', 'Warning', 'Info', 'Debug'] } },
      { id: 'copyLogPath', label: '', control: { kind: 'action', label: 'Copy Log Path', message: 'Copy the actual log file path from Settings → Advanced in the Mac app.' } },
      { id: 'revealLog', label: '', control: { kind: 'action', label: 'Reveal in Finder', message: 'Reveal the app log in Finder from the Mac app.' } },
    ],
  },
  {
    // 업데이트 피드가 포함된 배포판 기준 표시.
    id: 'updates', title: 'Updates',
    rows: [
      { id: 'updateAutomatically', label: 'Update Automatically', control: { kind: 'toggle', on: true } },
      { id: 'betaUpdates', label: 'Beta Updates', control: { kind: 'toggle', on: false } },
      { id: 'checkForUpdates', label: '', control: { kind: 'action', label: 'Check for Updates…', message: 'Check for signed app updates in the Mac app.' } },
    ],
  },
];

/** Settings 맨 아래의 Customize 이동 행. 섹션 제목 없이 카드 하나로 놓임. */
export const settingsCrossLink = {
  title: 'Customize',
  subtitle: "Choose what's visible and where",
};
