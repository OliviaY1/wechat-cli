# macOS WeChat Adapter Requirements

## Goal

Build a local, deterministic adapter for the owner's logged-in WeChat account. Support any chat in the account, addressed by its exact display name. No AI or MCP integration in this phase.

## Implementation

- Use macOS Accessibility (`AXUIElement`) through Swift or Python/PyObjC.
- Prefer AX attributes/actions; use keyboard events or paste when necessary.
- Require Accessibility permission and an unlocked graphical desktop session.
- Do not use screenshots, OCR, database decryption, process injection, hooks, re-signing, or kernel changes.
- Record tested macOS and WeChat versions. Background/minimized operation requires explicit testing.

## Features

1. **Status:** report application availability, permissions, and UI readiness.
2. **Chats:** list the chats WeChat exposes.
3. **Read:** return recent text messages exposed by the selected chat's accessibility tree, with a completeness indicator.
4. **Send:** resolve and verify the recipient, populate the input, submit, and verify the local message echo.
5. **Watch:** capture new messages through AX notifications where reliable, otherwise configurable polling.
6. **Event queue:** persist captured events and expose cursor-based incremental reads.

7. **History:** save messages to SQLite, with `backfill` for past messages (last N or all) and `export` for one CSV per chat.

Messages are text or images. Links and replies are saved as text, and stickers are skipped. Images are files on disk, with the absolute path in SQLite. Sent time is kept to the minute. Unread and read state is never used. Exclude contact creation, group administration, and Moments.

## Identity and Message Data

- Display names are not WeChat IDs. Never invent a wxid or native message ID.
- Reject missing or ambiguous recipients; do not select the first partial-name match.
- Recheck the active chat immediately before sending.
- Return: `event_id`, `chat_key`, `sender_display_name`, `is_self`, `message_type`, `text`, `observed_at`, and `displayed_time`.
- Use locally generated event IDs; distinguish observation time from displayed message time.
- Unknown identity/time fields must be null. Display names are not authenticated identities.
- Report UI coverage limits explicitly.

## Sending Guarantees

- Accept `request_id`, `chat_key`, and `text`; persist request records to prevent duplicate submissions.
- If the input contains an existing draft, set it aside, send, then restore it; preserve user content.
- Send from a detached chat window (at most 5 open, least recently used closed first), so the main window stays free for `watch`.
- Serialize UI operations that share a resource. Stop on unexpected focus, recipient, or user-interaction changes.
- Preserve clipboard contents where possible without overwriting a newer user copy.
- Return `local_echo_confirmed`, `unknown`, `failed`, or `duplicate_request`.
- Never automatically resend an uncertain submission. Local echo is not proof of remote delivery.

## Monitoring and Recovery

- Establish an initial baseline; do not emit existing messages as new by default.
- Do not deduplicate solely by text or assume AX element IDs survive restarts.
- Track outgoing messages without suppressing unrelated identical messages.
- Persist queue cursors and report gaps after sleep, lock, disconnect, app exit, or unreadable UI.
- An unreadable chat must not be reported as an empty chat.
- Validate one chat first, then test independent windows or serialized switching for multiple chats.

## Local Interface

```text
wechat-adapter status
wechat-adapter chats
wechat-adapter read --chat "Test Group" --limit 20
wechat-adapter send --chat "File Transfer" --text "Test" --request-id test-001
wechat-adapter watch
wechat-adapter events --after <cursor>
wechat-adapter backfill --chats 10 --last 100
wechat-adapter export --out <folder>
```

Use JSON/JSONL on stdout and diagnostics on stderr. Open no network ports by default. Keep event storage private to the local user; omit message bodies and full accessibility trees from routine logs.

## Acceptance Tests

- Send one message to File Transfer and read back the exact local echo.
- Correctly target a group and DM; reject ambiguous names.
- Preserve existing drafts and avoid wrong-chat sends after user interruption.
- Repeated request IDs send once; distinct identical incoming messages remain distinct.
- Capture numbered messages sent from another device; measure misses, duplicates, and latency.
- Report sender display names where available and null otherwise.
- Recover from app restart/network interruption without silently losing coverage or resending unknown requests.
- Test background, minimized, locked, and remote-session states; document supported behavior.

## Delivery

Deliver a capability probe, adapter source, CLI, setup instructions, test results, and known limitations. Target detection within a few seconds under tested desktop conditions; report measurements rather than guaranteeing real-time completeness.

Current exploratory testing confirmed accessible text/sender labels and one File Transfer send/readback on this Mac. It does not yet validate a standalone adapter, continuous monitoring, or remote delivery.
