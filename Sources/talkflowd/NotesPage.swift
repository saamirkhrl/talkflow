import SwiftUI

/// A placeholder until the note taker is designed: no recording, storage
/// or model code lives here.
struct NotesPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Notes").font(AppFont.pageTitle).foregroundColor(Palette.ink)
            VStack(spacing: 14) {
                Image(systemName: "doc.text")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(Palette.muted)
                    .accessibilityHidden(true)
                Text("Meeting notes are on the way")
                    .font(AppFont.panelTitle)
                    .foregroundColor(Palette.ink)
                Text("talkflow will listen to a meeting and write the notes for you, on this Mac. Nothing is uploaded.")
                    .font(AppFont.body)
                    .foregroundColor(Palette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
                AppPill(text: "Coming soon", font: AppFont.caption, horizontal: 14, vertical: 4)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Palette.ink.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
        }
        .padding(.top, AppMetrics.titlebar + AppMetrics.pageTop)
        .padding(.horizontal, AppMetrics.pageSide)
        .padding(.bottom, AppMetrics.pageBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
