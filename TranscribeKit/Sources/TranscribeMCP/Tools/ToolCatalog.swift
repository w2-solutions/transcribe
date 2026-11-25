import Foundation

/// The two read-only tools (§3.4), as tools/list returns them. Every property name matches `^[A-Za-z0-9_.-]{1,64}$`,
/// every schema is a plain object with no root `anyOf`/`oneOf`, and unknown arguments are ignored when called.
public enum ToolCatalog {
    public static let listRecordings = "list_recordings"
    public static let getTranscript = "get_transcript"

    public static let listRecordingsDescription = "Lists the user's recordings from the Transcribe app, newest first: id, title, date and time, length, folder, the device it was recorded on, and the speakers with how each name was decided. Only finished recordings are listed. Use query to search titles, transcript text and speaker names (every word must appear, case-insensitive); each result then shows its first matching line with a time. Use speaker to find recordings where a person spoke, and from_date/to_date (YYYY-MM-DD, the user's time zone) to limit dates. Pass a recording's id to get_transcript to read it."

    public static let getTranscriptDescription = "Returns one recording's transcript as lines of \"[start–end] Speaker: text\", with times from the start of the recording, after a header listing the speakers and how each name was decided. Names marked (auto) were recognised automatically and not confirmed. Long transcripts come in parts of about 30,000 characters: when the result ends with next_cursor, call again with that cursor and the same recording_id to continue. Use start_seconds and end_seconds to read only part of a recording."

    public static let tools: JSONValue = [
        tool(name: listRecordings, title: "List recordings", description: listRecordingsDescription, properties: [
            "query": ["type": "string",
                      "description": "Words to search for in titles, transcripts and speaker names. Every word must appear."],
            "speaker": ["type": "string",
                        "description": "Only recordings where a speaker with this name spoke (named by the user or recognised automatically; guesses are not counted). Case-insensitive; part of a name is fine."],
            "from_date": ["type": "string",
                          "description": "Earliest date, YYYY-MM-DD or an ISO 8601 date-time, in the user's time zone."],
            "to_date": ["type": "string", "description": "Latest date, inclusive, YYYY-MM-DD or an ISO 8601 date-time."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 20,
                      "description": "How many recordings to return."],
            "cursor": ["type": "string", "description": "next_cursor from the previous call, for the next page."],
        ], required: []),
        tool(name: getTranscript, title: "Get transcript", description: getTranscriptDescription, properties: [
            "recording_id": ["type": "string", "description": "The id from list_recordings."],
            "start_seconds": ["type": "number", "minimum": 0, "description": "Only turns that end after this time."],
            "end_seconds": ["type": "number", "minimum": 0, "description": "Only turns that start before this time."],
            "cursor": ["type": "string",
                       "description": "next_cursor from the previous call. When given, start_seconds and end_seconds are ignored."],
        ], required: ["recording_id"]),
    ]

    /// Short descriptions for the Claude Desktop `.mcpb` manifest.
    public static let manifestEntries: [(name: String, description: String)] = [
        (listRecordings, "List and search recordings."),
        (getTranscript, "Read a transcript with times and speaker names."),
    ]

    private static func tool(name: String, title: String, description: String, properties: [String: JSONValue],
                             required: [String]) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "additionalProperties": false, "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": .object(schema),
            "annotations": ["title": .string(title), "readOnlyHint": true, "destructiveHint": false,
                            "idempotentHint": true, "openWorldHint": false],
        ]
    }
}
