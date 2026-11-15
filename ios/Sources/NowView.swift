import SwiftUI

/// The main screen: one Now card (the thing that matters right now) and a small Today strip. A placeholder until
/// the real items come from GupDoKit's planner.
struct NowView: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Now")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Text("Nothing right now")
                        .font(.title2.weight(.semibold))
                    Text("Reminders, habits and events show up here when it's their time.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(.blue.opacity(0.15), in: .rect(cornerRadius: 22))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("now-card")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Today")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Text("All clear")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("today-strip")

                Spacer()
            }
            .padding()
            .navigationTitle("GupDo")
        }
    }
}

#Preview {
    NowView()
}
