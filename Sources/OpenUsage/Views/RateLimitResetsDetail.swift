import SwiftUI

/// Codex reset credit의 만료 타임라인과 claim 흐름.
/// confirm 진입 때 credit별 idempotency key를 발급해 재시도에 재사용하며, `claim`이 없으면 읽기 전용.
struct RateLimitResetsDetail: View {
    /// 행의 "N available" 개수 — 빈 `expiries`의 중의성 해소 전용: 0이면 empty state, >0이면 만료 시각 미fetch.
    let count: Int
    let expiries: [Date]
    /// cursor의 popover 내부 여부 보고 — trigger가 inline 값→popover 이동 중 popover를 유지.
    var onHoverChange: (Bool) -> Void
    /// confirm/in-flight 동안 popover를 pin — cursor 이탈로 claim 도중 흐름이 무너지지 않게 유지. claim 흐름 없으면 `nil`.
    var onPinChange: ((Bool) -> Void)?
    /// 지정 만료 시각의 credit을 주어진 idempotency key로 claim — `nil`이면 timeline이 read-only.
    var claim: ((_ expiry: Date, _ redeemRequestID: String) async -> ResetClaimOutcome)?

    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    @State private var claimedExpiries: Set<Date> = []
    @State private var confirmingExpiry: Date?
    @State private var claimingExpiry: Date?
    @State private var hoveredExpiry: Date?
    /// credit별 idempotency key — confirm 최초 진입 시 발급, 해당 credit의 모든 retry에 재사용(CLI의 double-spend 보호와 동일).
    @State private var redeemRequestIDs: [Date: String] = [:]
    @State private var banner: Banner?
    /// 이 popover 세션에서 "더 reset할 것 없음"을 학습했는지 — claim 성공 또는 `nothing_to_reset` 거절(credit 미소비) 후 true.
    /// 남은 "Use" 버튼은 tooltip과 함께 비활성. popover close 시 fresh @State로 초기화.
    @State private var nothingToReset = false

    private static let width: CGFloat = 250

    /// confirm 대기 또는 claim 진행 중 — 다른 node를 얼려 claim이 한 번에 하나만 일어나게 보장.
    private var claimInProgress: Bool { confirmingExpiry != nil || claimingExpiry != nil }

    private var visibleExpiries: [Date] {
        expiries.filter { !claimedExpiries.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let banner {
                bannerView(banner)
                    .transition(.scale(scale: 0.95, anchor: .top).combined(with: .opacity))
            }
            // claim의 강제 refresh가 outcome 도착 전에 in-flight credit을 `expiries`에서 제거할 수 있음 —
            // spinner가 banner로 넘어갈 때까지 "Resetting…" 행 유지, 그 동안 empty/unknown 상태는 모순이라 억제.
            if let claimingExpiry, !visibleExpiries.contains(claimingExpiry) {
                claimingRow().transition(.opacity)
                if case .timeline(let entries) = Self.content(count: count - claimedExpiries.count, expiries: visibleExpiries) {
                    timeline(entries)
                }
            } else {
                switch Self.content(count: count - claimedExpiries.count, expiries: visibleExpiries) {
                case .timeline(let entries): timeline(entries)
                case .unknownExpiries(let count): unknownExpiriesState(count)
                case .empty: emptyState
                }
            }
        }
        .padding(14)
        .frame(width: Self.width)
        // ideal 높이를 고정 크기로 보고 — NSPopover는 한 번 커진 높이를 유지하므로 confirm 접힘 시 다시 줄어들게 처리.
        .fixedSize(horizontal: false, vertical: true)
        .onContinuousHover { phase in
            switch phase {
            case .active: onHoverChange(true)
            case .ended: onHoverChange(false)
            }
        }
        // pinned popover 아래에서 credits가 바뀔 수 있음 — confirm 대기 credit이 사라지면 confirm을 접고 pin 해제.
        // in-flight claim은 outcome handler가 상태를 소유하므로 불간섭.
        .onChange(of: expiries) { _, newValue in
            if let confirming = confirmingExpiry, !newValue.contains(confirming) {
                cancelConfirm()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("You have no rate limit resets")
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// credit은 있으나 만료 목록을 못 가져온 경우(usage-body count fallback) — 개수를 표시해 행의 "N available"과
    /// 모순되지 않게 유지.
    private func unknownExpiriesState(_ count: Int) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(count) available")
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.primary)
            Text("Expiry times unavailable")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func timeline(_ entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // identity는 index가 아닌 만료 시각 — claim 후 renumber 시 한 행만 떠나고 나머지가 slide up하도록 유지.
            ForEach(entries, id: \.date) { entry in
                let isFirst = entry.id == 0
                let isLast = entry.id == entries.count - 1
                HStack(alignment: .top, spacing: 10) {
                    rail(for: entry, isFirst: isFirst, isLast: isLast, dotCenterY: dotCenterY(for: entry))
                    node(entry)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func dotCenterY(for entry: Entry) -> CGFloat {
        confirmingExpiry == entry.date ? confirmCardPadding + 9 : nodeHeight / 2
    }

    /// 두 segment의 connector rail(상단 고정 + 하단 stretch) — dot을 관통해 끊김 없이 이어지고, 첫/마지막 node는
    /// 바깥 segment 숨김. GeometryReader가 아닌 segment 방식 — HStack 안에서 전체 높이로 확실히 stretch됨.
    private func rail(for entry: Entry, isFirst: Bool, isLast: Bool, dotCenterY: CGFloat) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(.quaternary).frame(width: 1.5).frame(height: dotCenterY)
                    .opacity(isFirst ? 0 : 1)
                Rectangle().fill(.quaternary).frame(width: 1.5).frame(maxHeight: .infinity)
                    .opacity(isLast ? 0 : 1)
            }
            numberedDot(entry).padding(.top, dotCenterY - 9)
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }

    private func numberedDot(_ entry: Entry) -> some View {
        ZStack {
            Circle().fill(Theme.meterFill(entry.severity)).frame(width: 18, height: 18)
            Text("\(entry.number)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Self.numberColor(entry.severity))
        }
    }

    private static func numberColor(_ severity: WidgetData.MeterSeverity) -> Color {
        severity == .warning ? .black : .white
    }

    @ViewBuilder
    private func node(_ entry: Entry) -> some View {
        if confirmingExpiry == entry.date {
            confirmRow(entry)
                // 상단 anchor — rail dot이 정렬되는 첫 줄을 고정한 채 카드가 아래로 펼쳐짐.
                .transition(.scale(scale: 0.95, anchor: .top).combined(with: .opacity))
        } else if claimingExpiry == entry.date {
            claimingRow()
                .transition(.opacity)
        } else {
            row(entry)
                // confirm/claim 동안 다른 node는 얼리고 흐리게 — active node만 live로 읽히게 처리.
                .opacity(claimInProgress ? 0.45 : 1)
                .allowsHitTesting(!claimInProgress)
                .transition(.opacity)
        }
    }

    /// resting/claimable node의 고정 높이 — hover로 countdown↔"Use" 교체 시 행 높이가 튀지 않게 고정.
    private var nodeHeight: CGFloat { density.supportingPointSize + 18 }
    /// confirm 카드 내부 padding — `dotCenterY`와 공유해 rail dot이 카드 첫 줄에 정렬.
    private let confirmCardPadding: CGFloat = 10

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 8) {
            Text(entry.time)
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing(entry)
        }
        .frame(height: nodeHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredExpiry = entry.date }
            else if hoveredExpiry == entry.date { hoveredExpiry = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.accessibilityLabel)
    }

    @ViewBuilder
    private func trailing(_ entry: Entry) -> some View {
        Group {
            if claim != nil, hoveredExpiry == entry.date, !claimInProgress {
                Button("Use") { beginConfirm(entry.date) }
                    .controlSize(.small)
                    .disabled(nothingToReset)
                    .hoverTooltip(nothingToReset ? "Nothing to reset right now" : nil)
                    .transition(.opacity)
            } else if let countdown = entry.countdown {
                Text(countdown)
                    .font(.system(size: density.supportingPointSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredExpiry)
    }

    private func confirmRow(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Use this reset?")
                .font(.system(size: density.supportingPointSize, weight: .medium))
                .foregroundStyle(.primary)
            Text("Immediately reset your usage limits. This can't be undone.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { runClaim(entry.date) } label: {
                    Text("Reset").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button { cancelConfirm() } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(confirmCardPadding)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5))
        }
        .padding(.vertical, 4)
    }

    private func claimingRow() -> some View {
        HStack(spacing: 8) {
            Text("Resetting your usage…")
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            ProgressView().controlSize(.small)
        }
        .frame(height: nodeHeight)
    }

    private func bannerView(_ banner: Banner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: banner.icon)
                .font(.system(size: 14))
                .foregroundStyle(banner.tint)
                .accessibilityHidden(true)
            Text(banner.text)
                .font(.system(size: density.supportingPointSize, weight: .medium))
                .foregroundStyle(banner.tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(banner.tint.opacity(0.12))
        }
    }

    // MARK: - Claim flow actions

    /// claim 흐름의 모든 layout 변화가 공유하는 단일 clock — rail·행·popover 높이가 함께 이동.
    private static let flowAnimation: Animation = .snappy(duration: 0.25)

    private func beginConfirm(_ date: Date) {
        if redeemRequestIDs[date] == nil {
            redeemRequestIDs[date] = UUID().uuidString
        }
        withAnimation(Self.flowAnimation) {
            banner = nil
            hoveredExpiry = nil
            confirmingExpiry = date
        }
        onPinChange?(true)
    }

    private func cancelConfirm() {
        withAnimation(Self.flowAnimation) {
            confirmingExpiry = nil
        }
        onPinChange?(false)
    }

    private func runClaim(_ date: Date) {
        guard let claim else { return }
        // confirm 시점에 발급한 key 재사용 — 여기서의 발급은 confirm↔클릭 사이 상태 유실 대비 fallback.
        let redeemRequestID = redeemRequestIDs[date] ?? UUID().uuidString
        withAnimation(Self.flowAnimation) {
            confirmingExpiry = nil
            claimingExpiry = date
        }
        Task {
            let outcome = await claim(date, redeemRequestID)
            withAnimation(Self.flowAnimation) {
                claimingExpiry = nil
                apply(outcome, for: date)
            }
            onPinChange?(false)
        }
    }

    private func apply(_ outcome: ResetClaimOutcome, for date: Date) {
        switch outcome {
        case .success:
            claimedExpiries.insert(date)
            nothingToReset = true
            banner = .init(text: "Reset claimed. Enjoy!", icon: "checkmark.circle.fill", tint: .green)
        case .nothingToReset:
            nothingToReset = true
            banner = .init(text: "Your usage doesn't need a reset yet", icon: "info.circle.fill", tint: .accentColor)
        case .noCredit:
            claimedExpiries.insert(date)
            banner = .init(text: "That reset is no longer available", icon: "exclamationmark.triangle.fill", tint: .orange)
        case .failed:
            banner = .init(text: "Couldn't reset usage. Please try again.", icon: "xmark.circle.fill", tint: .red)
        }
    }

    struct Banner: Equatable {
        let text: String
        let icon: String
        let tint: Color
    }

    /// body가 렌더링할 내용 — count/expiries에서 1회 해석해 empty/count-only/timeline 선택을 unit-test 가능하게 분리.
    enum Content: Equatable {
        case timeline([Entry])
        case unknownExpiries(count: Int)
        case empty
    }

    /// 빈 `expiries`의 중의성 해소 — `count == 0`이면 empty state, 양수 count면 만료 fetch 실패로 개수만 표시.
    static func content(count: Int, expiries: [Date], now: Date = Date()) -> Content {
        let entries = entries(from: expiries, now: now)
        if !entries.isEmpty { return .timeline(entries) }
        if count > 0 { return .unknownExpiries(count: count) }
        return .empty
    }

    /// timeline node 한 개의 표시 문자열 — pure/static이라 view 없이 unit-test 가능.
    struct Entry: Identifiable, Equatable {
        let id: Int
        let number: Int
        let date: Date       // credit의 만료 시각 — claim 흐름의 identity
        let severity: WidgetData.MeterSeverity
        let time: String
        let countdown: String?

        var accessibilityLabel: String {
            "Reset \(number), \(time)" + (countdown.map { ", expires in \($0)" } ?? "")
        }
    }

    /// 만료 시각들로 timeline entry 구성 — 임박 순 정렬, 1부터 번호, 정확 시각 + countdown 쌍.
    /// 임박 판정은 relative 기준(≤5분에 `soon` 수렴) — exact 시각과 countdown이 서로 모순되지 않게 통일.
    static func entries(from expiries: [Date], now: Date = Date()) -> [Entry] {
        expiries.sorted().enumerated().map { index, date in
            let relative = Formatters.whenLabel(at: date, mode: .relative, now: now)
            let absolute = Formatters.whenLabel(at: date, mode: .absolute, now: now)
            let imminent = (relative == nil || relative == Formatters.imminent)
            return Entry(
                id: index,
                number: index + 1,
                date: date,
                severity: WidgetData.expirySeverity(secondsRemaining: date.timeIntervalSince(now)),
                time: (imminent || absolute == nil) ? "Expiring soon" : absolute!,
                countdown: imminent ? nil : relative
            )
        }
    }
}
