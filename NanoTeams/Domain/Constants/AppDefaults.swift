import Foundation

/// Hard-coded default values used at app bootstrap (LLM, prompts).
enum AppDefaults {
    static let llmBaseURL = "http://localhost:1234"
    static let llmModel = "openai/gpt-oss-20b"

    /// Default hard limit for `read_file` line count. Files exceeding this are
    /// rejected with an error pointing the LLM at `read_lines`.
    /// `0` is a sentinel meaning "no limit" (read the entire file regardless of size).
    static let readFileMaxLines = 500
    /// Inclusive lower bound for the configurable `read_file` line limit.
    /// `0` denotes the "unlimited" sentinel.
    static let readFileMaxLinesMin = 0
    /// Inclusive upper bound for the configurable `read_file` line limit.
    static let readFileMaxLinesMax = 2000

    /// Default cap on the number of `search` matches returned when the LLM
    /// does not pass an explicit `max_results`.
    static let searchMaxResults = 50
    /// Inclusive lower bound for the configurable `search` result cap.
    static let searchMaxResultsMin = 5
    /// Inclusive upper bound for the configurable `search` result cap.
    static let searchMaxResultsMax = 500

    /// Default number of source lines to include before each `search` match
    /// when the LLM does not pass an explicit `context_before`.
    static let searchContextBefore = 2
    /// Default number of source lines to include after each `search` match
    /// when the LLM does not pass an explicit `context_after`.
    static let searchContextAfter = 3
    /// Inclusive lower bound for the configurable `search` context.
    static let searchContextMin = 0
    /// Inclusive upper bound for the configurable `search` context.
    static let searchContextMax = 20

    static let workFolderContextPrompt = """
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
