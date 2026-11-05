import SwiftUI

/// The open panel: a header in the menu-bar band (the camera housing owns the
/// middle), the page content, and a one-line footer.
struct ExpandedView: View {
    let store: AppStore
    let geometry: IslandGeometry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: geometry.barHeight)
            Group {
                switch store.page {
                case .usage: UsageList(store: store)
                case .activity: ActivityView(store: store)
                }
            }
            .padding(.top, 10)
            .frame(maxHeight: .infinity, alignment: .top)
            footer
                .frame(height: AppStore.footerHeight)
        }
        .padding(.bottom, 10)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            HStack(spacing: 2) {
                tab("Usage", .usage)
                tab("Activity", .activity, badge: store.liveAgents.isEmpty ? nil : store.liveAgents.count)
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            Spacer(minLength: 0)
            Text(status)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.l)
    }

    private var status: String {
        if store.refreshing { return "Updating…" }
        guard let last = store.lastRefresh else { return "" }
        let age = Format.ago(last)
        return age == "now" ? "Updated just now" : "Updated \(age) ago"
    }

    private func tab(_ title: String, _ page: AppStore.Page, badge: Int? = nil) -> some View {
        let selected = store.page == page
        return Button {
            store.page = page
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 14)
                        .background(Capsule().fill(Theme.live))
                }
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, Theme.Space.m)
            .frame(height: 22)
            .background(Capsule().fill(selected ? Color.white.opacity(0.14) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(badge.map { "\(title), \($0) working" } ?? title)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 0.5)
                .padding(.horizontal, Theme.Space.l)
            HStack(spacing: 6) {
                switch store.page {
                case .usage:
                    let failing = store.providers.filter { $0.error != nil }.count
                    if failing > 0 {
                        Circle().fill(Theme.warn).frame(width: 6, height: 6)
                        Text(failing == 1 ? "1 needs attention" : "\(failing) need attention")
                    } else if !store.providers.isEmpty {
                        Circle().fill(Theme.live).frame(width: 6, height: 6)
                        Text("\(store.providers.count) providers")
                    }
                    Spacer(minLength: 0)
                    if let next = store.providers.filter({ $0.error == nil })
                        .compactMap({ $0.headline?.resetsAt }).filter({ $0 > Date() }).min(),
                       let countdown = Format.countdown(to: next) {
                        Text("Next reset in \(countdown)")
                    }
                case .activity:
                    Circle()
                        .fill(store.liveAgents.isEmpty ? Color.white.opacity(0.3) : Theme.live)
                        .frame(width: 6, height: 6)
                    Text(store.sessions.isEmpty
                         ? "No sessions"
                         : "\(store.sessions.count) sessions · \(store.liveAgents.count) working")
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.l)
            .frame(maxHeight: .infinity)
        }
    }
}
