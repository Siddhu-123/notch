import AppKit
import AVFoundation
import Combine
import SwiftUI

struct CompactCalendarPane: View {
    @ObservedObject var provider: CalendarProvider
    let hapticsEnabled: Bool
    @State private var hapticTrigger = 0

    private var dates: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (-1...5).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            dayStrip
            GeometryReader { geometry in
                if geometry.size.width >= 460 {
                    HStack(alignment: .top, spacing: 10) {
                        calendarEvents
                        reminders
                    }
                } else {
                    // Narrow pages stack both lists in one scrolling page; both stay visible.
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            calendarEvents.frame(height: max(150, geometry.size.height))
                            reminders.frame(height: max(150, geometry.size.height))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sensoryFeedback(.alignment, trigger: hapticTrigger)
        .accessibilityIdentifier("calendar-panel")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(provider.selectedDate.formatted(.dateTime.weekday(.wide)))
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Text(provider.selectedDate.formatted(.dateTime.month(.wide).day()))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Button { provider.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(ChromeButtonStyle(size: 26))
                .help("Refresh calendar")
        }
    }

    private var dayStrip: some View {
        HStack(spacing: 6) {
            ForEach(dates, id: \.self) { date in
                let selected = Calendar.current.isDate(date, inSameDayAs: provider.selectedDate)
                let isToday = Calendar.current.isDateInToday(date)
                Button {
                    provider.selectDate(date)
                    if hapticsEnabled { hapticTrigger += 1 }
                } label: {
                    VStack(spacing: 2) {
                        Text(date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                        Text(date.formatted(.dateTime.day()))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(selected ? .white : .white.opacity(isToday ? 0.8 : 0.5))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(selected ? NotchModule.calendar.tint.opacity(0.32) : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        if isToday && !selected {
                            RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(NotchModule.calendar.tint.opacity(0.6), lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func column<Content: View>(_ title: String, symbol: String, count: Int?, openID: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(NotchModule.calendar.tint)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Button {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: openID) {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.45))
                    .help("Open \(title == "Events" ? "Calendar" : "Reminders")")
            }
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func emptyState(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.3))
            Text(text).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func accessPrompt(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(text).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.5))
            Button(button, action: action)
                .buttonStyle(.borderedProminent).controlSize(.small).tint(NotchModule.calendar.tint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var calendarEvents: some View {
        column("Events", symbol: "calendar", count: provider.hasCalendarAccess ? provider.events.count : nil, openID: "com.apple.iCal") {
            if !provider.hasCalendarAccess {
                accessPrompt("Calendar access is off.", button: "Allow Calendar") { provider.requestCalendarAccess() }
            } else if provider.events.isEmpty {
                emptyState("calendar", "Nothing scheduled for this day.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(provider.events) { event in
                            HStack(spacing: 8) {
                                Capsule().fill(Color(nsColor: event.calendarColor)).frame(width: 4, height: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(2)
                                    Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    private var reminders: some View {
        column("Reminders", symbol: "checklist", count: provider.hasReminderAccess ? provider.reminders.count : nil, openID: "com.apple.reminders") {
            if !provider.hasReminderAccess {
                accessPrompt("Reminders access is off.", button: "Allow Reminders") { provider.requestReminderAccess() }
            } else if provider.reminders.isEmpty {
                emptyState("checkmark.circle", "No reminders due.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(provider.reminders) { reminder in
                            Button { provider.toggleReminder(reminder) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 15))
                                        .foregroundStyle(NotchModule.calendar.tint)
                                    Text(reminder.title)
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundStyle(.white.opacity(reminder.isCompleted ? 0.45 : 1))
                                        .lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 9).padding(.vertical, 8)
                                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help(reminder.isCompleted ? "Mark reminder incomplete" : "Mark reminder complete")
                        }
                    }
                }
            }
        }
    }
}
