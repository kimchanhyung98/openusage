import CoreGraphics
import Darwin
import Foundation
import os

/// "지금 화면을 관찰 중인가" 판정 — 메뉴바 Hide From Screen Share 설정(`MenuBarPrivacyStore`)의 live 신호.
/// macOS는 공개 "capturing" API 부재 — window server의 watcher flag를 `dlsym`으로 runtime 해석(SkyLight `SLSIsScreenWatcherPresent`, 구 `CGS` 철자 fallback).
/// symbol 부재 시 crash 대신 degrade — 공백 1회 loud 로깅 후 공개 세션 dictionary fallback(원격 세션만 보고, in-app 캡처 미보고).
enum ScreenCaptureProbe {
    /// `SLSIsScreenWatcherPresent()` — 화면 capture stream 보유 프로세스 존재 시 true.
    private typealias IsWatcherPresent = @convention(c) () -> Bool
    /// `SLSRegisterNotifyProc(callback, event, context)` — window-server notification 등록.
    /// callback signature는 window server의 `(event, data, dataLength, context)`.
    private typealias RegisterNotifyProc = @convention(c) (
        @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32

    /// screen watcher attach/detach의 window-server notification id — private이나 장기 안정.
    /// 탐지를 빠르게만 할 뿐 정확성은 store poll이 보장 — 값이 조용히 바뀌어도 기능 불파손.
    private static let watcherAttachedEvent: UInt32 = 1502
    private static let watcherDetachedEvent: UInt32 = 1503

    private static let isWatcherPresent: IsWatcherPresent? =
        symbol("SLSIsScreenWatcherPresent", "CGSIsScreenWatcherPresent")
            .map { unsafeBitCast($0, to: IsWatcherPresent.self) }

    private static let registerNotifyProc: RegisterNotifyProc? =
        symbol("SLSRegisterNotifyProc", "CGSRegisterNotifyProc")
            .map { unsafeBitCast($0, to: RegisterNotifyProc.self) }

    /// 설치된 변경 handler — window server가 자체 스레드에서 callback 호출, actor 대신 lock 보호.
    private static let changeHandler = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    /// 등록은 프로세스당 1회 — window server에 unregister 부재.
    @MainActor private static var didInstall = false

    /// 현재 화면 캡처 여부 — window-server 호출 1회로 poll 가능한 비용, private symbol 부재 시 공개 세션 dictionary fallback.
    static func isScreenCaptured() -> Bool {
        if let isWatcherPresent { return isWatcherPresent() }
        return sessionReportsSharedScreen()
    }

    /// screen watcher attach/detach 시 `handler` 실행 등록 — poll tick 대기 없이 공유 시작 즉시 메뉴바 전환.
    /// best-effort — 등록 실패·symbol 소실은 로깅 후 poll만으로 탐지 지속.
    @MainActor
    static func installChangeNotifications(_ handler: @escaping @Sendable () -> Void) {
        changeHandler.withLock { $0 = handler }
        guard !didInstall else { return }
        didInstall = true

        if isWatcherPresent == nil {
            AppLog.error(.menubar, "SLSIsScreenWatcherPresent unavailable; screen-share detection is limited to remote sessions")
        }
        guard let registerNotifyProc else {
            AppLog.warn(.menubar, "SLSRegisterNotifyProc unavailable; screen-share detection relies on polling")
            return
        }
        // C-convention callback은 context 캡처 불가 — static box 경유로 handler 도달.
        let callback: @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void = { _, _, _, _ in
            ScreenCaptureProbe.changeHandler.withLock { $0 }?()
        }
        let attached = registerNotifyProc(callback, watcherAttachedEvent, nil)
        let detached = registerNotifyProc(callback, watcherDetachedEvent, nil)
        AppLog.info(.menubar, "Screen-watcher notifications registered (attach: \(attached), detach: \(detached))")
    }

    /// 공개 fallback — `CGSessionCopyCurrentDictionary`는 macOS Screen Sharing·원격 관리 세션만 보고, Zoom 공유 등 in-app 캡처 미보고.
    private static func sessionReportsSharedScreen() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsShared"] as? Bool ?? false
    }

    /// `names` 중 loaded image에서 처음 해석되는 symbol — 전부 실패 시 `nil`.
    /// `RTLD_DEFAULT`(Swift 미노출 상수) 대상 해석 — SkyLight는 AppKit이 로드.
    private static func symbol(_ names: String...) -> UnsafeMutableRawPointer? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        for name in names {
            if let address = dlsym(rtldDefault, name) { return address }
        }
        return nil
    }
}
