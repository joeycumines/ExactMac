import SwiftUI

/// The queue review: a DIFFERENT SURFACE, not a variant of the prompt — the same standing
/// the envelope review holds, and for the same reason. When requests queue behind the one
/// the operator is looking at, the decision in front of them is not the only one waiting,
/// and a surface that cannot say so leaves the operator answering one question blind to the
/// rest. So this opens with a full-bleed band, names the count, lists every waiting request
/// with its own consequence and its server-default scope, and offers the honest batch: one
/// option applied to each — never a blanket grant.
struct QueueReview: View {
    struct Item: Equatable, Identifiable {
        var id: String
        var title: String
        var scopeLine: String
    }

    let items: [Item]
    /// Promotes one waiting request to the active prompt so the operator decides it with
    /// its full disclosure. NO DEFAULT: a Decide link that defaults to a no-op is a row
    /// that absorbs the click and decides nothing.
    var onDecide: (String) -> Void
    /// Denies every waiting request, one decision each.
    var onDenyAll: (String) -> Void
    /// Returns to the active prompt without deciding anything here.
    var onBack: () -> Void

    @State private var operatorNote: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // The band, with the way back. The review replaces the prompt's decision
            // surface, so the band carries the only exit from it.
            HStack(spacing: 0) {
                Text("QUEUED REQUESTS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Design.Ink.textPrimary)
                Spacer(minLength: 0)
                Button(action: onBack) {
                    Text("Back to prompt")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Design.Ink.accentText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Design.Space.frame)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: Design.Radius.large,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: Design.Radius.large,
                    style: .continuous,
                )
                .fill(Design.Ink.surfaceRaised),
            )

            VStack(alignment: .leading, spacing: Design.Space.one) {
                Text("\(items.count) requests waiting")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Design.Ink.textPrimary)
                Text("Review requests individually, or deny all.")
                    .font(.system(size: 11))
                    .foregroundStyle(Design.Ink.textTertiary)
            }
            .padding(.top, 14)
            .padding(.horizontal, Design.Space.frame)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.chip) {
                    ForEach(items) { item in
                        HStack(alignment: .center, spacing: Design.Space.chip) {
                            VStack(alignment: .leading, spacing: Design.Space.hair) {
                                Text(item.title)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Design.Ink.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(item.scopeLine)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Design.Ink.textTertiary)
                            }
                            Spacer(minLength: 0)
                            Button {
                                onDecide(item.id)
                            } label: {
                                Text("Decide")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Design.Ink.accentText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(Design.Space.three)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .background(Design.Ink.surfaceSunken)

            VStack(alignment: .leading, spacing: Design.Space.component) {
                EnvelopeNoteField(text: $operatorNote)

                HStack {
                    ConsoleButton(title: "Deny all", kind: .deny) {
                        onDenyAll(operatorNote)
                    }
                    .frame(width: 96)
                    Spacer(minLength: 0)
                }

                Text("Each request receives its own decision. No blanket grant is created.")
                    .font(.system(size: 10))
                    .foregroundStyle(Design.Ink.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Design.Space.three)
            .padding(.horizontal, Design.Space.frame)
            .padding(.bottom, Design.Space.frame)
        }
        .frame(width: Design.Layout.promptWidth)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
                .fill(Design.Ink.surface),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
                .strokeBorder(Design.Ink.controlBorder, lineWidth: 1),
        )
    }
}
