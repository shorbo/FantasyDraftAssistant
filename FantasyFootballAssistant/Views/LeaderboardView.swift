import SwiftUI

struct LeaderboardView: View {
    let session: DraftSession
    @State private var metric: LeaderboardMetric = .value

    private func valueText(_ delta: Int) -> String { delta >= 0 ? "+\(delta)" : "\(delta)" }
    private func pointsText(_ p: Double) -> String { "\(Int(p.rounded())) pts" }

    private func gradeColor(_ grade: String) -> Color {
        switch grade.first {
        case "A": return .green
        case "B": return .blue
        case "C": return .secondary
        case "D": return .orange
        default: return .red
        }
    }

    private func score(_ team: TeamGrade) -> Double {
        metric == .value ? Double(team.totalValue) : team.projectedPoints
    }

    private func primaryText(_ team: TeamGrade) -> String {
        metric == .value ? valueText(team.totalValue) : pointsText(team.projectedPoints)
    }

    private func primaryColor(_ team: TeamGrade) -> Color {
        metric == .value ? (team.totalValue >= 0 ? .green : .red) : .primary
    }

    private func grade(_ team: TeamGrade) -> String {
        metric == .value ? team.valueGrade : team.pointsGrade
    }

    var body: some View {
        let board = session.leaderboard.sorted { score($0) > score($1) }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Draft Leaderboard").font(.title2).bold()
                    Picker("", selection: $metric) {
                        ForEach(LeaderboardMetric.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    Text(metric == .value
                        ? "Value vs. consensus rank — drafting a player later than their rank is a steal (+), earlier is a reach (−)."
                        : session.hasRealProjections
                            ? "Projected points of each team's best starting lineup, from your loaded FantasyPros projections (modeled fallback for any position not loaded)."
                            : "Projected points of each team's best starting lineup (modeled from consensus positional rank — load FantasyPros projections at setup for real numbers).")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Graded on a curve against the field, so an average draft is a C.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    ForEach(Array(board.enumerated()), id: \.element.id) { i, team in
                        leaderRow(rank: i + 1, team: team)
                    }
                }

                if let mine = board.first(where: \.isMine) {
                    yourDraft(mine)
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func leaderRow(rank: Int, team: TeamGrade) -> some View {
        let medals = ["🥇", "🥈", "🥉"]
        let secondary = metric == .value
            ? pointsText(team.projectedPoints)
            : "value \(valueText(team.totalValue))"
        return HStack(spacing: 12) {
            Text(rank <= 3 ? medals[rank - 1] : "\(rank)")
                .font(.headline)
                .frame(width: 34, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(team.teamName).bold().lineLimit(1)
                    if team.isMine {
                        Text("YOU").font(.caption2).bold().foregroundStyle(.green)
                    }
                }
                Text(secondary).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Text(primaryText(team))
                .font(.system(.body, design: .rounded)).bold()
                .monospacedDigit()
                .foregroundStyle(primaryColor(team))

            Text(grade(team))
                .font(.headline).bold()
                .foregroundStyle(gradeColor(grade(team)))
                .frame(width: 40)
                .padding(.vertical, 4)
                .background(gradeColor(grade(team)).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .background(
            team.isMine ? Color.green.opacity(0.08) : Color.gray.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(team.isMine ? Color.green.opacity(0.4) : .clear)
        )
    }

    private func yourDraft(_ team: TeamGrade) -> some View {
        let steals = team.bestPicks.filter { $0.delta > 0 }.prefix(3)
        let reaches = team.worstPicks.filter { $0.delta < 0 }.prefix(3)
        return VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("YOUR DRAFT — \(team.teamName)")
                .font(.system(size: 12, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 24) {
                pickColumn("Best value", picks: Array(steals), positive: true,
                           empty: "No picks beat their rank.")
                pickColumn("Biggest reaches", picks: Array(reaches), positive: false,
                           empty: "No reaches — you never jumped a player's rank.")
            }
        }
    }

    private func pickColumn(_ title: String, picks: [PickValue], positive: Bool, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout).bold()
            if picks.isEmpty {
                Text(empty).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(picks) { pv in
                HStack(spacing: 8) {
                    PositionBadge(player: pv.pick.player)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pv.pick.player.name).bold().lineLimit(1)
                        Text("Pick #\(pv.pick.pickNumber) · ranked #\(pv.effectiveRank)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(valueText(pv.delta))
                        .font(.callout).bold().monospacedDigit()
                        .foregroundStyle(positive ? Color.green : Color.red)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
