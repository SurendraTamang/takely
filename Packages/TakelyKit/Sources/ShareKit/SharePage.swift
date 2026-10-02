import Foundation

/// The shared link's page: the video with its title, summary and chapters, and the tags that make the link unfurl
/// (OpenGraph/Twitter: Slack, iMessage, X, LinkedIn) and embed (oEmbed: Notion, Medium).
public struct SharePage: Sendable, Equatable {
    public struct Chapter: Sendable, Equatable {
        public var t: Double
        public var title: String
    }

    public var title: String
    public var summary: String?
    public var chapters: [Chapter]
    public var duration: Double
    public var width: Int
    public var height: Int
    /// The folder's public address (the page is `index.html` in it) and the media files' names in it.
    public var base: URL
    public var video: String
    public var poster: String?
    public var captions: String?

    var pageURL: URL { base.appending(path: "index.html") }
    var videoURL: URL { base.appending(path: video) }
    var posterURL: URL? { poster.map { base.appending(path: $0) } }

    public var html: String {
        let title = Self.escape(title)
        let description = Self.escape(summary ?? "A Takely recording · \(Self.time(duration))")
        let chapterList =
            chapters.isEmpty
            ? ""
            : "<ol class=\"chapters\">"
                + chapters.filter { $0.t.isFinite }.map {
                    "<li><a href=\"#t=\(Int($0.t))\" data-t=\"\($0.t)\">\(Self.time($0.t))</a> \(Self.escape($0.title))</li>"
                }.joined()
                + "</ol>"
        let track = captions.map { "<track kind=\"captions\" src=\"\($0)\" srclang=\"en\" label=\"Captions\" default>" } ?? ""
        let image =
            posterURL.map {
                "<meta property=\"og:image\" content=\"\($0.absoluteString)\">\n<meta name=\"twitter:image\" content=\"\($0.absoluteString)\">"
            } ?? ""
        return """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(title)</title>
            <meta name="description" content="\(description)">
            <meta property="og:type" content="video.other">
            <meta property="og:title" content="\(title)">
            <meta property="og:description" content="\(description)">
            <meta property="og:url" content="\(pageURL.absoluteString)">
            \(image)
            <meta property="og:video" content="\(videoURL.absoluteString)">
            <meta property="og:video:secure_url" content="\(videoURL.absoluteString)">
            <meta property="og:video:type" content="video/mp4">
            <meta property="og:video:width" content="\(width)">
            <meta property="og:video:height" content="\(height)">
            <meta name="twitter:card" content="summary_large_image">
            <meta name="twitter:title" content="\(title)">
            <link rel="alternate" type="application/json+oembed" href="\(base.appending(path: "oembed.json").absoluteString)" title="\(title)">
            <style>
            :root { color-scheme: light dark; --bg: #fafafa; --fg: #1c1c1e; --muted: #6e6e73; }
            @media (prefers-color-scheme: dark) { :root { --bg: #111; --fg: #f2f2f7; --muted: #98989d; } }
            body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
            main { max-width: 1100px; margin: 0 auto; padding: 24px 16px 48px; }
            video { width: 100%; max-height: 80vh; background: #000; border-radius: 12px; display: block; }
            h1 { font-size: 1.4rem; margin: 18px 0 6px; }
            p { color: var(--muted); margin: 0 0 12px; }
            .chapters { padding-left: 1.2rem; } .chapters a { font-variant-numeric: tabular-nums; color: inherit; }
            footer { margin-top: 32px; font-size: .8rem; color: var(--muted); }
            body.embed main { padding: 0; max-width: none; } body.embed video { border-radius: 0; max-height: 100vh; }
            body.embed h1, body.embed p, body.embed .chapters, body.embed footer { display: none; }
            </style>
            </head>
            <body>
            <main>
            <video controls playsinline preload="metadata"\(poster.map { " poster=\"\($0)\"" } ?? "") src="\(video)">\(track)</video>
            <h1>\(title)</h1>
            \(summary.map { "<p>\(Self.escape($0))</p>" } ?? "")
            \(chapterList)
            <footer>Recorded with Takely</footer>
            </main>
            <script>
            if (new URLSearchParams(location.search).has("embed")) document.body.classList.add("embed");
            const v = document.querySelector("video");
            const seek = t => { v.currentTime = t; v.play(); };
            document.querySelectorAll("[data-t]").forEach(a => a.addEventListener("click", e => { e.preventDefault(); seek(+a.dataset.t); }));
            const m = location.hash.match(/t=(\\d+)/); if (m) v.addEventListener("loadedmetadata", () => { v.currentTime = +m[1]; }, { once: true });
            </script>
            </body>
            </html>
            """
    }

    /// oEmbed (https://oembed.com): lets editors like Notion embed the player from the link.
    public var oEmbed: Data {
        let embedWidth = min(width, 1280)
        let embedHeight = width > 0 ? embedWidth * height / width : 720
        let object: [String: Any] = [
            "version": "1.0", "type": "video", "provider_name": "Takely", "title": title,
            "width": embedWidth, "height": embedHeight, "thumbnail_url": posterURL?.absoluteString ?? "",
            "html":
                "<iframe src=\"\(pageURL.absoluteString)?embed=1\" width=\"\(embedWidth)\" height=\"\(embedHeight)\" frameborder=\"0\" allow=\"fullscreen; picture-in-picture\" allowfullscreen></iframe>",
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(
            of: ">", with: "&gt;"
        )
        .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    static func time(_ t: Double) -> String {
        let s = t.isFinite ? Int(max(0, t).rounded(.down)) : 0
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
