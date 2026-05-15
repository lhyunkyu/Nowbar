import SwiftUI
import Combine

// MARK: - Plugin Protocol
/// NowBar 알약에 표시될 플러그인이 구현해야 하는 프로토콜.
/// ObservableObject를 채택하면 상태 변화 시 뷰가 자동으로 갱신됩니다.
protocol NowBarPluginProtocol: AnyObject {
    /// 플러그인 고유 ID (역 도메인 형식 권장, e.g. "com.nowbar.music")
    var pluginID: String { get }

    /// true이면 사이드바에 알약이 표시됨
    var isActive: Bool { get }

    /// 높을수록 위에 표시 (기본값 100 → 음악)
    var priority: Int { get }

    /// 알약 배경 강조 색상
    var accentColor: Color { get }

    /// 알약 내부 전경(텍스트/아이콘) 색상
    var fgColor: Color { get }

    /// 콜랩스 상태 내부 컨텐츠 뷰 (패딩/배경 없이 HStack 내용만)
    func makeCollapsedView() -> AnyView

    /// 확장 상태 전체 뷰 (배경색 + 컨텐츠 포함)
    func makeExpandedView() -> AnyView

    /// 알약이 확장될 때 호출
    func onExpand()

    /// 알약이 축소될 때 호출
    func onCollapse()

    var objectWillChange: ObservableObjectPublisher { get }
}

// MARK: - Type-Erased Plugin Wrapper
/// 이종(heterogeneous) 플러그인 배열을 위한 타입 소거 래퍼.
/// 내부 플러그인의 objectWillChange를 구독해 자신의 objectWillChange로 전파합니다.
final class AnyNowBarPlugin: ObservableObject, Identifiable {
    let id: String

    private let _isActive:          () -> Bool
    private let _priority:          () -> Int
    private let _accentColor:       () -> Color
    private let _fgColor:           () -> Color
    private let _makeCollapsedView: () -> AnyView
    private let _makeExpandedView:  () -> AnyView
    private let _onExpand:          () -> Void
    private let _onCollapse:        () -> Void
    private var cancellable: AnyCancellable?

    var isActive:    Bool  { _isActive() }
    var priority:    Int   { _priority() }
    var accentColor: Color { _accentColor() }
    var fgColor:     Color { _fgColor() }

    func makeCollapsedView() -> AnyView { _makeCollapsedView() }
    func makeExpandedView()  -> AnyView { _makeExpandedView() }
    func onExpand()   { _onExpand() }
    func onCollapse() { _onCollapse() }

    init<P: ObservableObject & NowBarPluginProtocol>(_ plugin: P) {
        id               = plugin.pluginID
        _isActive        = { plugin.isActive }
        _priority        = { plugin.priority }
        _accentColor     = { plugin.accentColor }
        _fgColor         = { plugin.fgColor }
        _makeCollapsedView = { plugin.makeCollapsedView() }
        _makeExpandedView  = { plugin.makeExpandedView() }
        _onExpand        = { plugin.onExpand() }
        _onCollapse      = { plugin.onCollapse() }

        // 내부 플러그인 변화 → 래퍼도 objectWillChange emit
        cancellable = plugin.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

// MARK: - Plugin Manager
/// 등록된 모든 NowBar 플러그인을 관리하는 싱글턴.
/// - 플러그인 등록/해제
/// - 활성 플러그인 정렬 (priority 내림차순)
/// - 확장 상태(expandedPluginID) 관리 → NotchState.isSideBarExpanded 동기화
final class NowBarPluginManager: ObservableObject {
    static let shared = NowBarPluginManager()

    @Published private(set) var registeredPlugins: [AnyNowBarPlugin] = []

    /// 현재 확장된 플러그인 ID. nil이면 모두 축소.
    @Published var expandedPluginID: String? = nil

    private var pluginCancellables: [String: AnyCancellable] = [:]
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // expandedPluginID 변화 → NotchState.isSideBarExpanded 동기화
        $expandedPluginID
            .map { $0 != nil }
            .receive(on: DispatchQueue.main)
            .sink { NotchState.shared.isSideBarExpanded = $0 }
            .store(in: &cancellables)
    }

    // MARK: - 등록 / 해제

    /// 플러그인을 등록합니다. 같은 pluginID는 중복 등록되지 않습니다.
    func register<P: ObservableObject & NowBarPluginProtocol>(_ plugin: P) {
        guard !registeredPlugins.contains(where: { $0.id == plugin.pluginID }) else { return }
        let wrapped = AnyNowBarPlugin(plugin)
        // 플러그인 변화 → manager도 objectWillChange emit (activePlugins 재계산 트리거)
        pluginCancellables[plugin.pluginID] = plugin.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
        registeredPlugins.append(wrapped)
    }

    /// 플러그인을 해제합니다.
    func unregister(pluginID: String) {
        if expandedPluginID == pluginID { expandedPluginID = nil }
        pluginCancellables.removeValue(forKey: pluginID)
        registeredPlugins.removeAll { $0.id == pluginID }
    }

    // MARK: - 활성 플러그인

    /// isActive == true인 플러그인을 priority 내림차순으로 반환합니다.
    var activePlugins: [AnyNowBarPlugin] {
        registeredPlugins
            .filter { $0.isActive }
            .sorted { $0.priority > $1.priority }
    }

    var isAnyExpanded: Bool { expandedPluginID != nil }

    // MARK: - 확장/축소

    func expand(pluginID: String) {
        guard expandedPluginID != pluginID else { return }
        // 기존에 열려있던 플러그인 축소
        if let old = expandedPluginID {
            registeredPlugins.first(where: { $0.id == old })?.onCollapse()
        }
        expandedPluginID = pluginID
        registeredPlugins.first(where: { $0.id == pluginID })?.onExpand()
    }

    func collapse(pluginID: String) {
        guard expandedPluginID == pluginID else { return }
        registeredPlugins.first(where: { $0.id == pluginID })?.onCollapse()
        expandedPluginID = nil
    }

    func collapseAll() {
        if let id = expandedPluginID {
            registeredPlugins.first(where: { $0.id == id })?.onCollapse()
        }
        expandedPluginID = nil
    }
}
