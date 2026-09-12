export const tourGeometry = {
  width: 1280,
  height: 840,
  panelWidth: 320,
  panelHeight: 610,
  focus: { x: 880, y: 0, width: 392, height: 684 },
} as const;

export interface CameraFrame { x: number; y: number; scale: number }

/** 팝업과 메뉴 막대가 여백을 포함해 뷰포트 안에 들어오는 카메라 위치. */
export function tourCamera(width: number, height: number, zoomed: boolean): CameraFrame {
  const bounds = zoomed ? tourGeometry.focus : { x: 0, y: 0, width: tourGeometry.width, height: tourGeometry.height };
  const scale = Math.min(width / bounds.width, height / bounds.height, zoomed ? 1.35 : 0.75);
  return {
    x: (width - bounds.width * scale) / 2 - bounds.x * scale,
    y: (height - bounds.height * scale) / 2 - bounds.y * scale,
    scale,
  };
}
