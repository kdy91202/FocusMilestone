import AppKit
import Foundation
import SwiftUI

@main
struct FocusMilestoneApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 640)
    }
}

enum FocusPhase: String, Codable {
    case focus
    case breakTime

    var title: String {
        switch self {
        case .focus: return "집중"
        case .breakTime: return "휴식"
        }
    }

    var systemImage: String {
        switch self {
        case .focus: return "scope"
        case .breakTime: return "cup.and.saucer"
        }
    }

    var accent: Color {
        switch self {
        case .focus: return Color(red: 0.88, green: 0.16, blue: 0.20)
        case .breakTime: return Color(red: 0.03, green: 0.48, blue: 0.42)
        }
    }
}

struct FocusTask: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var isDone: Bool

    init(id: UUID = UUID(), title: String, isDone: Bool = false) {
        self.id = id
        self.title = title
        self.isDone = isDone
    }
}

struct PersistedFocusState: Codable {
    var goal: String
    var focusMinutes: Int
    var breakMinutes: Int
    var totalSessions: Int
    var completedSessions: Int
    var tasks: [FocusTask]
}

@MainActor
final class FocusStore: ObservableObject {
    @Published var goal: String = "" {
        didSet { save() }
    }

    @Published private(set) var focusMinutes: Int = 25 {
        didSet { save() }
    }

    @Published private(set) var breakMinutes: Int = 5 {
        didSet { save() }
    }

    @Published private(set) var totalSessions: Int = 4 {
        didSet { save() }
    }

    @Published private(set) var completedSessions: Int = 0 {
        didSet { save() }
    }

    @Published private(set) var tasks: [FocusTask] = [
        FocusTask(title: "목표를 한 문장으로 정리하기"),
        FocusTask(title: "첫 번째 산출물 만들기"),
        FocusTask(title: "마무리 점검하기")
    ] {
        didSet { save() }
    }

    @Published private(set) var mode: FocusPhase = .focus
    @Published private(set) var remainingSeconds: Int = 25 * 60
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "오늘의 집중 목표를 정해보세요."

    private let storageKey = "FocusMilestone.persistedState.v1"
    private var timer: Timer?
    private var phaseEndDate: Date?

    init() {
        load()
        remainingSeconds = phaseDurationSeconds
    }

    deinit {
        timer?.invalidate()
    }

    var phaseDurationSeconds: Int {
        switch mode {
        case .focus: return focusMinutes * 60
        case .breakTime: return breakMinutes * 60
        }
    }

    var remainingText: String {
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var elapsedProgress: Double {
        guard phaseDurationSeconds > 0 else { return 0 }
        let elapsed = Double(phaseDurationSeconds - remainingSeconds)
        return min(max(elapsed / Double(phaseDurationSeconds), 0), 1)
    }

    var checklistProgress: Double {
        guard !tasks.isEmpty else { return 0 }
        let doneCount = tasks.filter(\.isDone).count
        return Double(doneCount) / Double(tasks.count)
    }

    var doneTaskCount: Int {
        tasks.filter(\.isDone).count
    }

    func startOrPause() {
        isRunning ? pause() : start()
    }

    func start() {
        guard !isRunning else { return }
        if remainingSeconds <= 0 {
            remainingSeconds = phaseDurationSeconds
        }

        phaseEndDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))
        isRunning = true
        statusMessage = mode == .focus ? "집중 중입니다." : "짧게 회복하는 시간입니다."
        scheduleTimer()
    }

    func pause() {
        guard isRunning else { return }
        updateRemainingFromClock()
        timer?.invalidate()
        timer = nil
        phaseEndDate = nil
        isRunning = false
        statusMessage = "잠시 멈췄습니다."
    }

    func resetCurrentPhase() {
        timer?.invalidate()
        timer = nil
        phaseEndDate = nil
        isRunning = false
        remainingSeconds = phaseDurationSeconds
        statusMessage = "\(mode.title) 타이머를 초기화했습니다."
    }

    func resetPlan() {
        timer?.invalidate()
        timer = nil
        phaseEndDate = nil
        isRunning = false
        mode = .focus
        completedSessions = 0
        remainingSeconds = phaseDurationSeconds
        statusMessage = "새로운 집중 라운드를 시작할 준비가 됐습니다."
    }

    func skipPhase() {
        completePhase(shouldContinue: isRunning)
    }

    func updateFocusMinutes(_ value: Int) {
        focusMinutes = value
        if !isRunning && mode == .focus {
            remainingSeconds = phaseDurationSeconds
        }
    }

    func updateBreakMinutes(_ value: Int) {
        breakMinutes = value
        if !isRunning && mode == .breakTime {
            remainingSeconds = phaseDurationSeconds
        }
    }

    func updateTotalSessions(_ value: Int) {
        totalSessions = value
        completedSessions = min(completedSessions, totalSessions)
    }

    func addTask(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tasks.append(FocusTask(title: trimmed))
        statusMessage = "체크리스트에 추가했습니다."
    }

    func toggleTask(_ task: FocusTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].isDone.toggle()
        statusMessage = tasks[index].isDone ? "하나 완료했습니다." : "다시 확인할 항목으로 돌렸습니다."
        save()
    }

    func deleteTask(_ task: FocusTask) {
        tasks.removeAll { $0.id == task.id }
        statusMessage = "항목을 삭제했습니다."
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let nextTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(nextTimer, forMode: .common)
        timer = nextTimer
    }

    private func tick() {
        updateRemainingFromClock()
        if remainingSeconds <= 0 {
            completePhase(shouldContinue: true)
        }
    }

    private func updateRemainingFromClock() {
        guard let phaseEndDate else { return }
        remainingSeconds = max(0, Int(ceil(phaseEndDate.timeIntervalSinceNow)))
    }

    private func completePhase(shouldContinue: Bool) {
        timer?.invalidate()
        timer = nil
        phaseEndDate = nil
        isRunning = false
        remainingSeconds = 0
        NSSound.beep()

        switch mode {
        case .focus:
            completedSessions = min(completedSessions + 1, totalSessions)
            if completedSessions >= totalSessions {
                mode = .focus
                remainingSeconds = phaseDurationSeconds
                statusMessage = "오늘의 집중 라운드를 마쳤습니다."
                return
            }
            mode = .breakTime
            remainingSeconds = phaseDurationSeconds
            statusMessage = "집중 세션 완료. 휴식으로 넘어갑니다."
        case .breakTime:
            mode = .focus
            remainingSeconds = phaseDurationSeconds
            statusMessage = "휴식 종료. 다음 집중을 시작합니다."
        }

        if shouldContinue {
            start()
        }
    }

    private func save() {
        let state = PersistedFocusState(
            goal: goal,
            focusMinutes: focusMinutes,
            breakMinutes: breakMinutes,
            totalSessions: totalSessions,
            completedSessions: completedSessions,
            tasks: tasks
        )

        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let state = try? JSONDecoder().decode(PersistedFocusState.self, from: data)
        else {
            return
        }

        goal = state.goal
        focusMinutes = min(max(state.focusMinutes, 5), 90)
        breakMinutes = min(max(state.breakMinutes, 1), 30)
        totalSessions = min(max(state.totalSessions, 1), 12)
        completedSessions = min(state.completedSessions, totalSessions)
        tasks = state.tasks
    }
}

struct ContentView: View {
    @StateObject private var store = FocusStore()
    @State private var draftTask = ""
    @State private var isShowingSettings = false

    var body: some View {
        ZStack {
            AppBackground()

            HStack(spacing: 24) {
                timerColumn
                checklistColumn
            }
            .padding(28)
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private var timerColumn: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Label(store.mode.title, systemImage: store.mode.systemImage)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(store.mode.accent)
                    Text(store.statusMessage)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        isShowingSettings.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("타이머 설정")
                    .popover(isPresented: $isShowingSettings, arrowEdge: .bottom) {
                        SettingsPopover(store: store)
                            .frame(width: 280)
                    }

                    SessionBadge(
                        completed: store.completedSessions,
                        total: store.totalSessions,
                        accent: store.mode.accent
                    )
                }
            }

            TimerDialView(
                progress: store.elapsedProgress,
                remainingText: store.remainingText,
                phaseTitle: store.mode.title,
                accent: store.mode.accent
            )
            .frame(maxWidth: 430, maxHeight: 430)

            TimerControls(store: store)
        }
        .frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var checklistColumn: some View {
        VStack(spacing: 16) {
            GoalPanel(goal: $store.goal)

            ChecklistPanel(
                tasks: store.tasks,
                doneCount: store.doneTaskCount,
                progress: store.checklistProgress,
                draftTask: $draftTask,
                accent: store.mode.accent,
                onAdd: {
                    store.addTask(draftTask)
                    draftTask = ""
                },
                onToggle: store.toggleTask,
                onDelete: store.deleteTask
            )
            .frame(maxHeight: .infinity)
        }
        .frame(width: 360)
        .frame(maxHeight: .infinity)
    }
}

struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark ? darkColors : lightColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var lightColors: [Color] {
        [
            Color(red: 0.96, green: 0.95, blue: 0.92),
            Color(red: 0.90, green: 0.94, blue: 0.95),
            Color(red: 0.98, green: 0.96, blue: 0.93)
        ]
    }

    private var darkColors: [Color] {
        [
            Color(red: 0.07, green: 0.08, blue: 0.09),
            Color(red: 0.09, green: 0.13, blue: 0.14),
            Color(red: 0.13, green: 0.11, blue: 0.09)
        ]
    }
}

struct TimerDialView: View {
    let progress: Double
    let remainingText: String
    let phaseTitle: String
    let accent: Color

    private let minuteMarks = Array(stride(from: 0, through: 55, by: 5))

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            ZStack {
                RoundedRectangle(cornerRadius: side * 0.12, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.08))
                    .shadow(color: .black.opacity(0.25), radius: 22, x: 0, y: 18)

                RoundedRectangle(cornerRadius: side * 0.10, style: .continuous)
                    .fill(Color(red: 0.91, green: 0.92, blue: 0.95))
                    .padding(side * 0.055)
                    .overlay {
                        RoundedRectangle(cornerRadius: side * 0.10, style: .continuous)
                            .stroke(.white.opacity(0.85), lineWidth: 2)
                            .padding(side * 0.074)
                    }

                Circle()
                    .fill(Color.white.opacity(0.48))
                    .frame(width: side * 0.72, height: side * 0.72)
                    .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 10)

                TimerWedge(progress: progress)
                    .fill(accent.opacity(0.86))
                    .frame(width: side * 0.56, height: side * 0.56)
                    .shadow(color: accent.opacity(0.24), radius: 12, x: 0, y: 8)

                tickMarks(side: side)

                ForEach(minuteMarks, id: \.self) { minute in
                    Text("\(minute)")
                        .font(.system(size: side * 0.045, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.10, green: 0.09, blue: 0.11))
                        .position(numberPoint(for: minute, side: side))
                }

                knob(side: side)

                VStack(spacing: 3) {
                    Text(phaseTitle)
                        .font(.system(size: side * 0.034, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.45, green: 0.42, blue: 0.40))
                    Text(remainingText)
                        .font(.system(size: side * 0.070, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color(red: 0.10, green: 0.09, blue: 0.11))
                }
                .padding(.horizontal, side * 0.035)
                .padding(.vertical, side * 0.018)
                .background(.white.opacity(0.68), in: Capsule())
                .offset(y: side * 0.31)
            }
            .frame(width: side, height: side)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func tickMarks(side: CGFloat) -> some View {
        ZStack {
            ForEach(0..<60, id: \.self) { index in
                let isMajor = index % 5 == 0
                Capsule()
                    .fill(Color(red: 0.11, green: 0.10, blue: 0.12).opacity(isMajor ? 0.9 : 0.55))
                    .frame(width: isMajor ? 2.4 : 1.2, height: isMajor ? side * 0.055 : side * 0.030)
                    .offset(y: -side * 0.255)
                    .rotationEffect(.degrees(Double(index) * 6))
            }
        }
    }

    private func knob(side: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.96, green: 0.95, blue: 0.93))
                .frame(width: side * 0.18, height: side * 0.18)
                .shadow(color: .black.opacity(0.24), radius: 12, x: 0, y: 8)

            ForEach(0..<28, id: \.self) { index in
                Capsule()
                    .fill(Color(red: 0.78, green: 0.76, blue: 0.72).opacity(0.7))
                    .frame(width: 1.1, height: side * 0.034)
                    .offset(y: -side * 0.072)
                    .rotationEffect(.degrees(Double(index) * 360 / 28))
            }

            Circle()
                .fill(Color.white.opacity(0.78))
                .frame(width: side * 0.115, height: side * 0.115)
        }
    }

    private func numberPoint(for minute: Int, side: CGFloat) -> CGPoint {
        let radius = side * 0.395
        let radians = (Double(minute) / 60 * 360 - 90) * .pi / 180
        return CGPoint(
            x: side / 2 + cos(radians) * radius,
            y: side / 2 + sin(radians) * radius
        )
    }
}

struct TimerWedge: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let start = Angle.degrees(-90)
        let end = Angle.degrees(-90 + max(0.001, min(progress, 1)) * 360)

        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct TimerControls: View {
    @ObservedObject var store: FocusStore

    var body: some View {
        HStack(spacing: 10) {
            Button {
                store.startOrPause()
            } label: {
                Label(store.isRunning ? "일시정지" : "시작", systemImage: store.isRunning ? "pause.fill" : "play.fill")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(store.mode.accent)

            Button {
                store.resetCurrentPhase()
            } label: {
                Label("리셋", systemImage: "arrow.counterclockwise")
            }
            .controlSize(.large)

            Button {
                store.skipPhase()
            } label: {
                Label("넘기기", systemImage: "forward.end.fill")
            }
            .controlSize(.large)

            Button {
                store.resetPlan()
            } label: {
                Label("새 라운드", systemImage: "target")
            }
            .controlSize(.large)
        }
    }
}

struct SessionBadge: View {
    let completed: Int
    let total: Int
    let accent: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "flag.checkered")
            Text("\(completed)/\(total)")
                .monospacedDigit()
        }
        .font(.system(size: 14, weight: .bold, design: .rounded))
        .foregroundStyle(accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.86), in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
    }
}

struct GoalPanel: View {
    @Binding var goal: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("오늘의 목표", systemImage: "sparkle.magnifyingglass")
                .font(.system(size: 14, weight: .bold, design: .rounded))

            TextField("예: 기획서 1차 초안 완성", text: $goal)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(12)
                .fieldSurface()
        }
        .panelStyle()
    }
}

struct SettingsPopover: View {
    @ObservedObject var store: FocusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("타이머 설정", systemImage: "slider.horizontal.3")
                .font(.system(size: 14, weight: .bold, design: .rounded))

            SettingStepper(
                title: "집중",
                value: Binding(get: { store.focusMinutes }, set: store.updateFocusMinutes),
                range: 5...90,
                step: 5,
                unit: "분"
            )

            SettingStepper(
                title: "휴식",
                value: Binding(get: { store.breakMinutes }, set: store.updateBreakMinutes),
                range: 1...30,
                step: 1,
                unit: "분"
            )

            SettingStepper(
                title: "라운드",
                value: Binding(get: { store.totalSessions }, set: store.updateTotalSessions),
                range: 1...12,
                step: 1,
                unit: "회"
            )
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SettingStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(value)\(unit)")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 14, weight: .medium, design: .rounded))
    }
}

struct ChecklistPanel: View {
    let tasks: [FocusTask]
    let doneCount: Int
    let progress: Double
    @Binding var draftTask: String
    let accent: Color
    let onAdd: () -> Void
    let onToggle: (FocusTask) -> Void
    let onDelete: (FocusTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("체크리스트", systemImage: "checklist")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
                Text("\(doneCount)/\(tasks.count)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accent)
            }

            ProgressView(value: progress)
                .tint(accent)

            HStack(spacing: 8) {
                TextField("이번 라운드에서 할 일", text: $draftTask)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
                    .onSubmit(onAdd)

                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .help("추가")
            }
            .padding(10)
            .fieldSurface()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tasks) { task in
                        TaskRow(task: task, accent: accent, onToggle: onToggle, onDelete: onDelete)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .panelStyle()
    }
}

struct TaskRow: View {
    let task: FocusTask
    let accent: Color
    let onToggle: (FocusTask) -> Void
    let onDelete: (FocusTask) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                onToggle(task)
            } label: {
                Image(systemName: task.isDone ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(task.isDone ? accent : .secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(task.isDone ? "완료 해제" : "완료")

            Text(task.title)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(task.isDone ? .secondary : .primary)
                .strikethrough(task.isDone, color: .secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onDelete(task)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("삭제")
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.82), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.30), lineWidth: 1)
        }
    }
}

struct PanelStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.primary)
            .padding(16)
            .background(panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(panelStroke, lineWidth: 1)
            }
            .shadow(color: shadowColor, radius: 16, x: 0, y: 10)
    }

    private var panelBackground: Color {
        if colorScheme == .dark {
            Color(red: 0.13, green: 0.15, blue: 0.16).opacity(0.94)
        } else {
            Color(nsColor: .windowBackgroundColor).opacity(0.68)
        }
    }

    private var panelStroke: Color {
        colorScheme == .dark ? .white.opacity(0.10) : .white.opacity(0.52)
    }

    private var shadowColor: Color {
        colorScheme == .dark ? .black.opacity(0.22) : .black.opacity(0.05)
    }
}

struct FieldSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.96), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
            }
    }
}

extension View {
    func panelStyle() -> some View {
        modifier(PanelStyleModifier())
    }

    func fieldSurface() -> some View {
        modifier(FieldSurfaceModifier())
    }
}
