//! Bounded native Antigravity (`agy`) transcript validation and projection.

use std::{
    collections::VecDeque,
    path::{Path, PathBuf},
};

use serde_json::Value;

use super::{HEAD_BYTES, Message, push_message};
use crate::runtime_api::conversation::Identity;

#[derive(Default)]
pub(super) struct AntigravityState {
    pending_calls: VecDeque<usize>,
    running_calls: Vec<usize>,
}

/// Pure lexical path to a local Antigravity CLI transcript for `session_id`
/// (zero filesystem I/O so it is safe to construct on the UI thread).
pub(super) fn local_transcript_path(session_id: &str) -> Option<String> {
    if !crate::session::valid_antigravity_conversation_segment(session_id) {
        return None;
    }
    let path = crate::platform::dirs::home_dir()?
        .join(".gemini")
        .join("antigravity-cli")
        .join("brain")
        .join(session_id)
        .join(".system_generated")
        .join("logs")
        .join("transcript_full.jsonl");
    let raw = path.to_str()?;
    crate::session::valid_antigravity_transcript_path(raw, session_id).then(|| raw.to_owned())
}

/// If `transcript_full.jsonl` does not exist yet on disk, try sibling `transcript.jsonl`.
pub(super) fn fallback_transcript_path(path: &Path) -> Option<PathBuf> {
    (path.file_name().and_then(|name| name.to_str()) == Some("transcript_full.jsonl"))
        .then(|| path.with_file_name("transcript.jsonl"))
}

pub(super) fn validate_source(identity: &Identity, path: &str, head: &[u8]) -> bool {
    if !crate::session::valid_antigravity_transcript_path(path, &identity.session_id) {
        return false;
    }
    if head.is_empty() {
        return true;
    }
    let Some(end) = head.iter().position(|byte| *byte == b'\n') else {
        // Brand-new partial line 0 still being appended, or an oversized JSON object line.
        return head.len() < HEAD_BYTES || head.first() == Some(&b'{');
    };
    let line = &head[..end];
    serde_json::from_slice::<Value>(line).ok().is_some_and(|record| {
        record.is_object()
            && record["type"].is_string()
            && (record["step_index"].is_u64() || record["source"].is_string())
    })
}

fn is_housekeeping(kind: &str) -> bool {
    matches!(
        kind,
        "CONVERSATION_HISTORY"
            | "CHECKPOINT"
            | "SYSTEM_MESSAGE"
            | "EPHEMERAL_MESSAGE"
            | "ERROR_MESSAGE"
    )
}

fn extract_user_request(text: &str) -> &str {
    const OPEN: &str = "<USER_REQUEST>";
    const CLOSE: &str = "</USER_REQUEST>";
    if let Some(start) = text.find(OPEN) {
        let rest = &text[start + OPEN.len()..];
        if let Some(end) = rest.find(CLOSE) {
            return rest[..end].trim();
        }
    }
    text.trim()
}

fn complete_running(messages: &mut [Message], state: &mut AntigravityState) {
    for index in state.running_calls.drain(..) {
        if let Some(message) = messages.get_mut(index) {
            message.complete = true;
        }
    }
}

pub(super) fn project_record(
    record: &Value,
    id: &str,
    messages: &mut Vec<Message>,
    state: &mut AntigravityState,
) {
    let Some(kind) = record["type"].as_str() else {
        return;
    };
    match kind {
        "USER_INPUT" => {
            complete_running(messages, state);
            state.pending_calls.clear();
            if let Some(content) = record["content"].as_str() {
                push_message(
                    messages,
                    id.into(),
                    "user",
                    extract_user_request(content).to_owned(),
                    false,
                );
            }
        },
        "PLANNER_RESPONSE" => {
            complete_running(messages, state);
            state.pending_calls.clear();
            if let Some(content) = record["content"].as_str() {
                push_message(messages, id.into(), "assistant", content.to_owned(), false);
            }
            if let Some(tool_calls) = record["tool_calls"].as_array() {
                for (index, call) in tool_calls.iter().enumerate() {
                    if !call.is_object() {
                        continue;
                    }
                    let block_id = format!("{id}:{index}");
                    let name = call["name"].as_str().filter(|n| !n.is_empty()).unwrap_or("tool");
                    let input = match call.get("args").or_else(|| call.get("arguments")) {
                        Some(Value::String(text)) => text.clone(),
                        Some(Value::Null) | None => String::new(),
                        Some(other) => serde_json::to_string_pretty(other).unwrap_or_default(),
                    };
                    let msg_index = messages.len();
                    messages.push(Message {
                        id: block_id,
                        role: "tool",
                        text: input,
                        name: Some(name.to_owned()),
                        detail: None,
                        complete: false,
                        truncated: false,
                        error: false,
                        paired: false,
                        event: false,
                    });
                    state.pending_calls.push_back(msg_index);
                }
            }
        },
        _ if !is_housekeeping(kind)
            && !matches!(
                record["source"].as_str(),
                Some("USER_EXPLICIT" | "SYSTEM" | "SYSTEM_SDK")
            ) =>
        {
            let Some(index) = state.pending_calls.pop_front() else {
                return;
            };
            let status = record["status"].as_str();
            let running = status == Some("RUNNING");
            let is_error = status == Some("ERROR");
            let output = record["content"]
                .as_str()
                .filter(|s| !s.is_empty())
                .or_else(|| record["error"].as_str().filter(|s| !s.is_empty()))
                .unwrap_or_default();
            if let Some(message) = messages.get_mut(index) {
                if !output.is_empty() || !running {
                    message.detail = Some(output.to_owned());
                }
                message.complete = !running;
                message.error = is_error;
            }
            if running {
                state.running_calls.push(index);
            }
        },
        _ => {},
    }
}

#[cfg(test)]
mod tests {
    use super::super::*;
    use std::io::Write;
    use std::path::PathBuf;

    const SESSION: &str = "021267b4-1ed5-4421-be03-c4d2054f5cae";

    fn agy_identity(session_id: &str) -> Identity {
        Identity { kind: "antigravity".into(), session_id: session_id.into(), epoch: Some(3) }
    }

    fn agy_fixture(
        session_id: &str,
        filename: &str,
        records: &[Value],
    ) -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let logs = dir
            .path()
            .join(".gemini")
            .join("antigravity-cli")
            .join("brain")
            .join(session_id)
            .join(".system_generated")
            .join("logs");
        std::fs::create_dir_all(&logs).unwrap();
        let path = logs.join(filename);
        let mut file = File::create(&path).unwrap();
        for record in records {
            writeln!(file, "{record}").unwrap();
        }
        (dir, path)
    }

    #[test]
    fn antigravity_projects_user_requests_tools_generic_results_and_hides_thinking() {
        let id = agy_identity(SESSION);
        let (_dir, path) = agy_fixture(
            SESSION,
            "transcript_full.jsonl",
            &[
                json!({
                    "step_index": 0,
                    "source": "USER_EXPLICIT",
                    "type": "USER_INPUT",
                    "status": "DONE",
                    "content": "System preamble\n<USER_REQUEST>\n帮我检查构建\n第二行\n</USER_REQUEST>\nTrailing note"
                }),
                json!({
                    "step_index": 1,
                    "source": "MODEL",
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "thinking": "private chain of thought secret",
                    "content": "",
                    "tool_calls": [
                        {"name": "read_file", "args": {"Path": "/tmp/a.rs"}},
                        {"name": "run_command", "args": {"CommandLine": "cargo test"}}
                    ]
                }),
                json!({
                    "step_index": 2,
                    "source": "SYSTEM_SDK",
                    "type": "EPHEMERAL_MESSAGE",
                    "status": "DONE",
                    "content": "internal sdk notice"
                }),
                json!({
                    "step_index": 3,
                    "source": "MODEL",
                    "type": "GENERIC",
                    "status": "DONE",
                    "content": "fn main() {}"
                }),
                json!({
                    "step_index": 4,
                    "source": "MODEL",
                    "type": "GENERIC",
                    "status": "RUNNING",
                    "content": "background task started"
                }),
                json!({
                    "step_index": 5,
                    "source": "MODEL",
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "thinking": "more private reasoning",
                    "content": "## 已完成\n一切正常。",
                    "tool_calls": [
                        {"name": "run_command", "arguments": "{\"cmd\":\"bad\"}"}
                    ]
                }),
                json!({
                    "step_index": 6,
                    "source": "MODEL",
                    "type": "GENERIC",
                    "status": "ERROR",
                    "error": "permission denied",
                    "content": ""
                }),
            ],
        );
        let capture = capture_file(&path, None).unwrap();
        validate_source(&id, path.to_str().unwrap(), &capture.head).unwrap();
        let (messages, before, truncated) = project(&id, &capture).unwrap();
        assert!(!truncated);
        assert!(before.is_none());
        assert_eq!(messages.len(), 5);
        assert_eq!(messages[0].role, "user");
        assert_eq!(messages[0].text, "帮我检查构建\n第二行");

        assert_eq!(messages[1].role, "tool");
        assert_eq!(messages[1].name.as_deref(), Some("read_file"));
        assert_eq!(messages[1].detail.as_deref(), Some("fn main() {}"));
        assert!(messages[1].complete);
        assert!(!messages[1].error);

        // Background RUNNING tool call becomes complete once the next PLANNER_RESPONSE arrives.
        assert_eq!(messages[2].role, "tool");
        assert_eq!(messages[2].name.as_deref(), Some("run_command"));
        assert_eq!(messages[2].detail.as_deref(), Some("background task started"));
        assert!(messages[2].complete);
        assert!(!messages[2].error);

        assert_eq!(messages[3].role, "assistant");
        assert_eq!(messages[3].text, "## 已完成\n一切正常。");

        assert_eq!(messages[4].role, "tool");
        assert_eq!(messages[4].detail.as_deref(), Some("permission denied"));
        assert!(messages[4].complete);
        assert!(messages[4].error);

        let serialized = serde_json::to_string(&messages).unwrap();
        assert!(!serialized.contains("private chain of thought"));
        assert!(!serialized.contains("more private reasoning"));
        assert!(!serialized.contains("internal sdk notice"));
    }

    #[test]
    fn antigravity_keeps_live_running_tool_incomplete_and_rejects_foreign_files() {
        let id = agy_identity(SESSION);
        let (_dir, path) = agy_fixture(
            SESSION,
            "transcript.jsonl",
            &[
                json!({"step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "status": "DONE", "content": "plain question"}),
                json!({"step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE", "content": "", "tool_calls": [{"name": "run_command", "args": {"cmd": "sleep 10"}}]}),
                json!({"step_index": 2, "source": "MODEL", "type": "GENERIC", "status": "RUNNING", "content": "still running..."}),
            ],
        );
        // Append partial trailing JSON line to verify partial writes wait for a newline.
        File::options()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(b"{\"step_index\":3,\"type\":\"PLANNER_RESPONSE\"")
            .unwrap();
        let capture = capture_file(&path, None).unwrap();
        validate_source(&id, path.to_str().unwrap(), &capture.head).unwrap();
        let (messages, _, _) = project(&id, &capture).unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].text, "plain question");
        assert_eq!(messages[1].role, "tool");
        assert!(!messages[1].complete, "tail RUNNING step stays in progress");
        assert_eq!(messages[1].detail.as_deref(), Some("still running..."));

        // Wrong session id or foreign Codex JSONL in an antigravity path must fail validation.
        assert!(validate_source(&agy_identity("other-session"), path.to_str().unwrap(), &capture.head).is_err());
        let (_foreign_dir, foreign_path) = agy_fixture(
            SESSION,
            "transcript.jsonl",
            &[json!({"type": "session_meta", "payload": {"id": SESSION}})],
        );
        let foreign = capture_file(&foreign_path, None).unwrap();
        assert!(validate_source(&id, foreign_path.to_str().unwrap(), &foreign.head).is_err());
    }

    #[test]
    fn antigravity_falls_back_from_missing_full_transcript_to_compact_sibling() {
        let id = agy_identity(SESSION);
        let (_dir, compact) = agy_fixture(
            SESSION,
            "transcript.jsonl",
            &[
                json!({"step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "status": "DONE", "content": "hi"}),
                json!({"step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE", "content": "hello"}),
            ],
        );
        let missing_full = compact.with_file_name("transcript_full.jsonl");
        let capture = capture_local_file(&id, &missing_full, None).unwrap();
        validate_source(&id, missing_full.to_str().unwrap(), &capture.head).unwrap();
        let (messages, _, _) = project(&id, &capture).unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[1].text, "hello");
    }
}
