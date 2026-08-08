import Foundation

extension UserDefaults {
    /// key 미설정·미인식 raw value 시 `fallback`으로 떨어지는 `RawRepresentable` enum 읽기
    /// persisted enum 설정이 공유하는 parse idiom의 단일 거처
    func enumValue<T: RawRepresentable>(forKey key: String, default fallback: T) -> T where T.RawValue == String {
        string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }

    /// 실제 default를 가진 `Bool` 읽기 — `bool(forKey:)`의 unset=false는 default-on 설정을 표현 불가
    /// key가 진짜 미설정일 때만 `fallback` 사용 — default-on toggle이 사용자의 명시적 off를 존중
    func bool(forKey key: String, default fallback: Bool) -> Bool {
        object(forKey: key) as? Bool ?? fallback
    }
}

/// 고정 `UserDefaults.standard` key로 persist되는 `String`-raw enum — conformer는 `current` 접근자 무료 획득
/// 주입 defaults나 instance-scope key를 쓰는 store는 `UserDefaults.enumValue(forKey:default:)` 직접 사용
protocol UserDefaultsBacked: RawRepresentable where RawValue == String {
    /// persist에 사용하는 `UserDefaults.standard` key
    static var key: String { get }
    /// key 미설정·미인식 raw value 시 사용값
    static var fallback: Self { get }
}

extension UserDefaultsBacked {
    /// 라이브로 읽는 저장 선택값 (`fallback` 폴백)
    static var current: Self {
        UserDefaults.standard.enumValue(forKey: key, default: fallback)
    }
}
