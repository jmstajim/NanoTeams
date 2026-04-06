import Foundation

/// Hard-coded default values used at app bootstrap (LLM, prompts).
enum AppDefaults {
    static let llmBaseURL = "http://localhost:1234"
    static let llmModel = "openai/gpt-oss-20b"

    static let workFolderDescriptionPrompt = """
        You are analyzing a work folder to write a reference for AI agents who will work with its contents.

        Start with 2-3 sentences describing what this folder is about overall — its purpose, domain, and how it is organized.

        Then list each file (or group of similar files), one line per entry, describing what can be found in it.
        Format: `path/to/file.ext` — brief description of contents and purpose.
        Group trivially similar files (e.g. 20 test fixtures, 50 images) into one summary line.

        Be specific and factual — mention actual names, types, and patterns you observe.
        Do not invent content not present in the files.
        Return plain text. No markdown formatting beyond the file listing.
        """
}
