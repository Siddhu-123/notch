import AppKit
import AVFoundation
import EventKit
import SwiftUI

struct OnboardingView: View {
    var onComplete: () -> Void

    @State private var currentStep = 0
    @StateObject private var calendar = CalendarProvider.shared
    @StateObject private var camera = CameraPreviewController.shared
    @State private var launchAtLogin = LaunchAtLoginController.isEnabled
    @State private var musicTested = false
    @State private var musicSuccess: Bool? = nil

    private let totalSteps = 3

    var body: some View {
        VStack(spacing: 0) {
            // Header with Stepper
            headerView
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()
                .opacity(0.15)

            // Step Content
            Group {
                switch currentStep {
                case 0:
                    welcomeStep
                case 1:
                    permissionsStep
                case 2:
                    howToUseStep
                default:
                    welcomeStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)

            Divider()
                .opacity(0.15)

            // Footer Navigation
            footerView
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
        }
        .frame(width: 640, height: 520)
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [Color.black.opacity(0.04), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
        .onAppear {
            calendar.refresh()
            camera.refreshStatus()
            launchAtLogin = LaunchAtLoginController.isEnabled
        }
    }

    // MARK: - Header
    private var headerView: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.tint)
                Text("Notch Setup")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }

            Spacer()

            // Step Indicator Dots
            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { index in
                    Capsule()
                        .fill(index == currentStep ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: index == currentStep ? 20 : 7, height: 7)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentStep)
                }
            }
        }
    }

    // MARK: - Step 1: Welcome
    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            // Simulated Notch Graphic
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 170, height: 32)
                    .overlay(
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text("Notch")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "waveform")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.horizontal, 12)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
            }

            VStack(spacing: 6) {
                Text("Welcome to Notch")
                    .font(.system(size: 24, weight: .bold, design: .rounded))

                Text("A native, quiet control surface tucked directly into your Mac's notch.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Feature Highlights Grid
            VStack(spacing: 12) {
                featureRow(
                    symbol: "music.note",
                    color: .pink,
                    title: "Live Audio & Now Playing",
                    detail: "Artwork, controls, and real-time audio visualizer for Apple Music & Spotify."
                )
                featureRow(
                    symbol: "calendar",
                    color: .red,
                    title: "Calendar & Reminders",
                    detail: "Upcoming events and quick to-dos accessible right from the top."
                )
                featureRow(
                    symbol: "tray.and.arrow.down.fill",
                    color: .blue,
                    title: "Persistent File Shelf",
                    detail: "Drag and drop temporary files or links to keep them within reach."
                )
                featureRow(
                    symbol: "camera.fill",
                    color: .green,
                    title: "Mirror & Quick Controls",
                    detail: "Instant camera preview for calls, brightness, volume, and battery status."
                )
            }
            .padding(.horizontal, 10)

            Spacer()
        }
    }

    private func featureRow(symbol: String, color: Color, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Step 2: Permissions
    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions & Setup")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Grant permissions so Notch can display calendar events, reminders, and mirror preview.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    // Calendar Permission Card
                    permissionCard(
                        icon: "calendar",
                        iconColor: .red,
                        title: "Calendar",
                        description: "Displays upcoming calendar events in the notch panel.",
                        status: calendarStatusText,
                        statusType: calendarStatusType,
                        buttonTitle: calendarButtonTitle,
                        action: handleCalendarAction
                    )

                    // Reminders Permission Card
                    permissionCard(
                        icon: "checklist",
                        iconColor: .orange,
                        title: "Reminders",
                        description: "Allows checking off and managing reminders.",
                        status: reminderStatusText,
                        statusType: reminderStatusType,
                        buttonTitle: reminderButtonTitle,
                        action: handleReminderAction
                    )

                    // Camera Permission Card
                    permissionCard(
                        icon: "camera.fill",
                        iconColor: .green,
                        title: "Camera (Mirror)",
                        description: "Provides an on-demand mirror preview before video calls.",
                        status: cameraStatusText,
                        statusType: cameraStatusType,
                        buttonTitle: cameraButtonTitle,
                        action: handleCameraAction
                    )

                    // Music Apple Events Card
                    permissionCard(
                        icon: "music.note",
                        iconColor: .pink,
                        title: "Music & Spotify Automation",
                        description: "Enables playback control and now-playing track sync.",
                        status: musicStatusText,
                        statusType: musicStatusType,
                        buttonTitle: "Test Connection",
                        action: handleMusicAction
                    )

                    // Launch at Login Toggle
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.blue.opacity(0.12))
                                .frame(width: 32, height: 32)
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.blue)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at Login")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            Text("Open Notch automatically when you log into your Mac.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: launchAtLogin) { _, newValue in
                                try? LaunchAtLoginController.setEnabled(newValue)
                                launchAtLogin = LaunchAtLoginController.isEnabled
                            }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(.vertical, 2)
            }
        }
    }

    private enum StatusType {
        case granted, denied, notDetermined
    }

    private func permissionCard(
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        status: String,
        statusType: StatusType,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))

                    // Status Pill
                    statusBadge(status: status, type: statusType)
                }

                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: action) {
                Text(buttonTitle)
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(statusType == .granted && buttonTitle == "Granted")
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func statusBadge(status: String, type: StatusType) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(type == .granted ? Color.green : (type == .denied ? Color.red : Color.secondary.opacity(0.6)))
                .frame(width: 5, height: 5)
            Text(status)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(type == .granted ? Color.green : (type == .denied ? Color.red : Color.secondary))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(type == .granted ? Color.green.opacity(0.12) : (type == .denied ? Color.red.opacity(0.12) : Color.secondary.opacity(0.1)))
        )
    }

    // Permission status computed helpers
    private var calendarStatusType: StatusType {
        switch calendar.calendarStatus {
        case .fullAccess, .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private var calendarStatusText: String {
        switch calendarStatusType {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not Set"
        }
    }

    private var calendarButtonTitle: String {
        switch calendarStatusType {
        case .granted: return "Granted"
        case .denied: return "Settings…"
        case .notDetermined: return "Allow"
        }
    }

    private func handleCalendarAction() {
        if calendarStatusType == .denied {
            calendar.openCalendarSettings()
        } else {
            calendar.requestCalendarAccess()
        }
    }

    private var reminderStatusType: StatusType {
        switch calendar.reminderStatus {
        case .fullAccess, .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private var reminderStatusText: String {
        switch reminderStatusType {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not Set"
        }
    }

    private var reminderButtonTitle: String {
        switch reminderStatusType {
        case .granted: return "Granted"
        case .denied: return "Settings…"
        case .notDetermined: return "Allow"
        }
    }

    private func handleReminderAction() {
        if reminderStatusType == .denied {
            calendar.openReminderSettings()
        } else {
            calendar.requestReminderAccess()
        }
    }

    private var cameraStatusType: StatusType {
        switch camera.authorizationStatus {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private var cameraStatusText: String {
        switch cameraStatusType {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not Set"
        }
    }

    private var cameraButtonTitle: String {
        switch cameraStatusType {
        case .granted: return "Granted"
        case .denied: return "Settings…"
        case .notDetermined: return "Allow"
        }
    }

    private func handleCameraAction() {
        if cameraStatusType == .denied {
            camera.openSettings()
        } else {
            camera.requestAccess()
        }
    }

    private var musicStatusType: StatusType {
        if let success = musicSuccess {
            return success ? .granted : .notDetermined
        }
        return .notDetermined
    }

    private var musicStatusText: String {
        if let success = musicSuccess {
            return success ? "Connected" : "Check Music"
        }
        return "Optional"
    }

    private func handleMusicAction() {
        musicTested = true
        MusicPermissionHelper.testMusicConnection { success in
            musicSuccess = success
        }
    }

    // MARK: - Step 3: How to Use
    private var howToUseStep: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.green)

                Text("You're Ready to Go!")
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                Text("Here's how you can interact with Notch at any time.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                usageTipRow(
                    symbol: "cursorarrow.motionlines",
                    title: "Hover or Click Top Center",
                    detail: "Hover your mouse at the top edge around the notch to expand live previews. Click or hover longer to reveal full controls."
                )
                usageTipRow(
                    symbol: "menubar.rectangle",
                    title: "Menu Bar Companion",
                    detail: "Click the sparkles icon in the menu bar to adjust settings, keep Notch pinned open, or revisit this setup window."
                )
                usageTipRow(
                    symbol: "command.circle.fill",
                    title: "Global Shortcut: ⌥ ⌘ N",
                    detail: "Use Option + Command + N from any application to quickly toggle the Notch panel."
                )
            }
            .padding(.horizontal, 10)

            Spacer()
        }
    }

    private func usageTipRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Footer
    private var footerView: some View {
        HStack {
            if currentStep > 0 {
                Button("Back") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        currentStep -= 1
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
            }

            Spacer()

            if currentStep < totalSteps - 1 {
                Button("Continue") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        currentStep += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Start Using Notch") {
                    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
