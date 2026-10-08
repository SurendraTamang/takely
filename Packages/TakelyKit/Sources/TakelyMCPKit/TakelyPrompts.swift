import MCP

/// Ready-made instructions for agents (MCP prompts; Claude Code lists them as /takely:… commands).
public enum TakelyPrompts {
    public static let all: [Prompt] = [
        Prompt(
            name: "pr_demo", title: "Record a demo of this change for the pull request",
            description: "Record a short narrated video showing a change working, upload it, and put it in the pull request.",
            arguments: [
                .init(
                    name: "change", description: "What changed and how to show it (e.g. \"the new Export button in Settings\")",
                    required: true),
                .init(name: "app", description: "The app to record (its name), if not the frontmost one"),
            ])
    ]

    public static func get(_ name: String, arguments: [String: String]?) -> GetPrompt.Result? {
        guard name == "pr_demo" else { return nil }
        let change = arguments?["change"] ?? "the change"
        let app = arguments?["app"].map { " in \($0)" } ?? ""
        return GetPrompt.Result(
            description: "Video proof for a pull request",
            messages: [.user(.text(text: prDemo(change: change, app: app)))])
    }

    /// The steps an agent follows: the video shows the real app, narrated; the person confirms what runs and what's
    /// shared; secrets found on screen are reviewed first; the link goes in the pull request.
    static func prDemo(change: String, app: String) -> String {
        """
        Make a short video showing \(change) working\(app), and attach it to the pull request.

        1. Build and launch the app with the change, ready to show it. Call takely `doctor` if anything fails.
        2. Write a demo plan (5–15 steps) for takely `run_demo`: begin with `say "…"` introducing the change, show it \
        step by step with a short `say` before each action, end with a `say` summing up. Prefer `key` shortcuts \
        (cmd+n, cmd+s…) over `click`; add `wait 1` after opening apps or windows. Never type passwords or personal data.
        3. Call `run_demo` with the plan. The person sees the plan and confirms it before anything runs; if they \
        decline, ask what to change. (To record manually instead: `record_start` with the app's window, do the steps, \
        `record_stop`.)
        4. Call `frames` with the returned path and look at the images: if the video doesn't show the change working, \
        say so and record again instead of sharing it.
        5. Call `share` with the returned path. The person sees the video and confirms before it uploads to their own \
        storage; if they decline, don't share it and don't retry unless they ask. If secrets were found on screen, it's \
        refused until the person reviews the blurs in Takely. It returns Markdown with a clickable poster.
        6. Add that Markdown to the pull request description under "Demo" (e.g. `gh pr edit --body-file` or a PR \
        comment), and mention the video's length.
        """
    }
}
