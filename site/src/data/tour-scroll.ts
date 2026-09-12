export type ScrollDecision = 'native' | 'hold' | 'previous' | 'next' | 'leave';

export class TourScrollGesture {
  private lastTime = -Infinity;
  private direction = 0;
  private distance = 0;
  private consumed = false;
  private leaving = false;
  private consumedAt = -Infinity;
  private strength = 0;

  reset(): void {
    this.lastTime = -Infinity;
    this.direction = 0;
    this.distance = 0;
    this.consumed = false;
    this.leaving = false;
    this.consumedAt = -Infinity;
    this.strength = 0;
  }

  move(delta: number, time: number, index: number, count: number, active: boolean, touch = false): ScrollDecision {
    if (!delta) return 'native';
    const direction = Math.sign(delta);
    // 작아진 관성은 무시하되, 계속 밀거나 휠을 돌리는 입력은 잠금을 다시 열어 진행.
    const elapsed = time - this.consumedAt;
    const continued = this.consumed && elapsed >= 350 && (Math.abs(delta) >= this.strength / 2 || elapsed >= 1200);
    if (!touch && (time - this.lastTime > 220 || direction !== this.direction || continued)) this.reset();
    this.lastTime = time;
    this.direction = direction;
    if (this.leaving) return 'hold';
    if (!active) {
      // 섹션 진입·내부 스크롤 직후의 중복 전환 방지.
      if (!this.consumed) this.consume(delta, time);
      return 'native';
    }
    if (this.consumed) return 'hold';
    this.distance += delta;
    if (Math.abs(this.distance) < 40) return 'hold';
    this.consume(delta, time);
    const next = index + Math.sign(this.distance);
    if (next < 0 || next >= count) {
      this.leaving = true;
      return 'leave';
    }
    return next < index ? 'previous' : 'next';
  }

  private consume(delta: number, time: number): void {
    this.consumed = true;
    this.consumedAt = time;
    this.strength = Math.abs(delta);
  }
}
