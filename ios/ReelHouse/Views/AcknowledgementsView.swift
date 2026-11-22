import SwiftUI

// Credits for the data services the server draws on. TMDB's
// terms ask for the notice below wherever its data is shown; the rest is courtesy and license
// attribution. Android's twin is ui/screens/AcknowledgementsScreen.kt - keep the two in step.
struct AcknowledgementsView: View {
    private struct Credit: Identifiable {
        let name: String
        let detail: String
        let url: String
        var id: String { name }
    }

    private static let data: [Credit] = [
        Credit(name: "The Movie Database (TMDB)",
               detail: "Movie and TV descriptions and artwork, when your server has a TMDB key. This product uses the TMDB API but is not endorsed or certified by TMDB.",
               url: "https://www.themoviedb.org"),
        Credit(name: "MusicBrainz and Cover Art Archive",
               detail: "Album details and cover art the server looks up for your music.",
               url: "https://musicbrainz.org"),
        Credit(name: "ListenBrainz",
               detail: "Similar-artist suggestions and listening history, if you connect an account.",
               url: "https://listenbrainz.org"),
        Credit(name: "LRCLIB",
               detail: "Song lyrics.",
               url: "https://lrclib.net"),
    ]

    var body: some View {
        Form {
            Section("Data") {
                ForEach(Self.data) { row($0) }
            }
            Section {
                Text("ReelHouse is an independent project. It is not affiliated with or endorsed by any media company or service named in the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Acknowledgements")
    }

    private func row(_ credit: Credit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Link(credit.name, destination: URL(string: credit.url)!)
                .font(.body.weight(.semibold))
            Text(credit.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
