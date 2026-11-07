# wechat-cli

Local CLI for any chat in the logged-in macOS WeChat client. It uses macOS Accessibility only. JSON goes to stdout and diagnostics go to stderr. It opens no network ports. Sending doesn't use the clipboard. Saving an image copies it from WeChat's viewer, then restores your clipboard unless you copied something newer.

Tested on macOS 26.6.2 with WeChat 3.8.10 (build 28633), English UI.

## Setup

1. Turn on Terminal in System Settings > Privacy & Security > Accessibility.
2. Open WeChat, log in, and stay on the Chats tab.
3. Build and check:

```sh
swiftc -O src/*.swift -o wechat-cli
./wechat-cli selftest
./wechat-cli status
```

There is no allowlist. `--chat` takes the chat's exact display name, and `chat_key` in the output is that name. A missing name, or one matching more than one row, is rejected. Data is stored in `~/Library/Application Support/wechat-cli/`.

## Commands

```text
wechat-cli start
wechat-cli status
wechat-cli chats
wechat-cli read --chat "File Transfer" --limit 20
wechat-cli send --chat "File Transfer" --text "Test" --request-id test-001
wechat-cli watch [--interval 2]
wechat-cli events [--after <cursor>] [--limit 1000]
wechat-cli events --after <cursor> --follow
wechat-cli events --latest
wechat-cli history --chat "File Transfer" --limit 100
wechat-cli search --query "text" [--chat "File Transfer"]
wechat-cli backfill --chats 10 --last 100
wechat-cli backfill --chat "File Transfer" --last all
wechat-cli export --out <folder>
wechat-cli windows
wechat-cli detach --chat "File Transfer"
wechat-cli backfill --chat "File Transfer" --detached --last 100
```

`send` returns `local_echo_confirmed`, `unknown`, `failed` or `duplicate_request`. A request ID is never reused, even after `failed`, so a retry needs a new ID. Never retry `unknown` automatically: the message may have gone out. Local echo doesn't prove remote delivery.

`chats` lists names from the chat list. A name containing a comma with no space after it comes back cut short.

`events --follow` keeps running. It prints anything after the cursor, then sleeps until `watch` signals new rows through a macOS notification, with no polling.

`history` and `search` read SQLite only and never touch WeChat.

`events` returns `kind: "message"` or `kind: "gap"`. A gap means coverage may be incomplete, and its `reason` says why. `chat_key: "*"` means the gap affects every chat. Save the last `cursor` you processed and pass it to `--after`.

`read` returns `event_id: null`, because a read isn't a queue event. `complete` is true only when the view is at the newest message and `--limit` messages were returned.

If WeChat's main window is closed, or the app has quit, every command except `status` reopens it, which brings WeChat to the front. `status` only reports.

If WeChat is logged out, stderr prints `it's logged out`. `status` also reports `logged_out`, and `watch` records a gap.

## History

All messages go into the `messages` table in `events.db`: chat, sender, is_self, type, text, image_path, displayed_time and sent_minute. `watch` adds new messages and `backfill` adds older ones, to the same table. Rerunning either doesn't add duplicates.

- **Types:** every message is `text` or `image`. Links and replies are stored as text, and a reply's text includes the quoted part. Stickers and unknown cells are skipped.
- **Images:** saved in `images/` in the data folder, as `.jpg`, `.png` or `.gif`, with `images/<file>` stored relative to the data folder. Command output gives the absolute path. `backfill` and `watch` open each image in WeChat's viewer to copy it, which takes a few seconds and shows a window briefly. A failed image keeps `image_path` null. `watch` only saves images for new messages.
- **Time:** `sent_minute` is local `yyyy-MM-dd HH:mm`, worked out from WeChat's time label. A label covers the messages after it, so it's approximate. An unrecognized label gives null, and `displayed_time` keeps the original.
- **`backfill`:** `--last` is a number or `all`, 100 by default. It stops scrolling once it has enough. `--chats N` takes the first N rows of the chat list, which reorders as messages arrive.
- **`export`:** writes one CSV per chat. A cell starting with `=`, `+`, `-` or `@` gets a leading `'`, so a spreadsheet won't run it as a formula.

## Detached windows

`detach` double-clicks a chat, which opens it in its own window titled `<chat>(Window)`. `windows` shows which window is main and which are detached. The cursor moves for the double-click. `backfill --detached` works only in that window and opens it if needed. It never takes the UI lock.

`send` always works in the chat's detached window. It reuses an open one, or opens one if needed, which is the only moment it needs the main window. At most 5 detached windows stay open. The least recently used closes first, and a window with a draft or used in the last 10 seconds is never closed. If none can close, the command fails with `too_many_detached_windows`.

The UI lock covers only the main window. A small focus lock covers the keyboard, mouse and clipboard, so sends, image saves, double-clicks and search take turns briefly, while `watch` reads without it. The chat list positions of the 20 most recently used chats are remembered in the `recent_rows` table, which `watch` keeps current. A position is only trusted for 60 seconds, and the row's name is always checked first. A wrong position just causes a full scan.

A chat that isn't in the chat list is opened through the search box. The box is always cleared first, and exactly one result must match the exact name, otherwise it's rejected. Search brings WeChat to the front and moves the cursor.

## Senders in groups

In a group, each text message carries its sender's display name, in the main window and in detached windows. `sender_display_name` holds that name, and your own messages have `is_self: true`. Display names can change and aren't proof of identity. A member displayed as "Me" would read as you.

## How `watch` works

`watch` covers every chat, but opens one only when needed. Each tick reads the chat list and captures a chat if its row changed or it's already open. Chats active in the last 10 minutes are also rechecked every 60 seconds. It compares message sequences with the last snapshot, so identical messages stay separate. If the snapshots don't overlap, it records a `no_overlap` gap and sets a new baseline.

Existing messages aren't emitted as new. The first time a chat changes, `watch` has no snapshot, so it records a `first_seen` gap and emits only the newest message. Others that arrived with it are missed. After a restart it records a `watcher_restart` gap, then picks up anything still visible in chats it has captured before. Chats never captured aren't compared, so changes during downtime are missed there.

WeChat's unread text is ignored: it was seen on about 374 rows at once, then removed, without real messages. Only the name, preview and time count as a row change. A repeated identical message in the same minute therefore leaves the row unchanged, and is found by the 60-second recheck or the chat's next message.

`watch --debug-rows` appends row changes to `rows-debug.jsonl` in the data folder. It holds chat previews and isn't size-limited.

If more than 10 rows change in one tick, `watch` records a `mass_row_change` gap and opens nothing, so a date rollover can't open every chat. Real messages in that tick are missed.

Opening a chat probably marks it as read. `watch` won't switch chats within 3 seconds of a key press or click.

## Test results (2026-11-06)

Messages were sent only to File Transfer.

| Test | Result |
|---|---|
| Send and read back exact text, including Chinese | Pass |
| Multi-line send and exact readback | Pass |
| Send with WeChat in the background | Pass |
| Repeated request ID sends once | Pass |
| Existing draft is set aside for the send, then restored (File Transfer and a real DM) | Pass |
| `detach` double-click opens a detached window, and `windows` tells main from detached | Pass |
| `backfill --detached --last 10` loop alongside a real send through the main window: 30 runs, 10 overlapping, all ok | Pass |
| `send` verifies the main input is focused before Return, with a detached window open | Pass |
| `send` from detached windows, with two open: File Transfer and a real DM each got only their own message | Pass |
| Remembered row: wrong position still opens the right chat, and a duplicate name is refused | Pass |
| Search path, forced on two chats already in the list, with the box cleared first | Pass |
| Unknown name rejected after a search (about 7 s) | Pass |
| All at once: `watch`, main window switching chats, `backfill --detached --last 300`, and sends to two chats: 70 of 70 main reads ok, both sends confirmed, 300 saved, no duplicates, order matches | Pass |
| New message in File Transfer during its detached `backfill`: backfill finished normally | Pass |
| LRU limit: 5 windows, least recently used closed first, main window never closed | Pass |
| Group detached windows are recognized (`<chat>(<members>)(Window)`) | Pass |
| Sender labels in 4 group detached windows: all 79 text messages had a sender, 3 distinct senders per group including `Me` | Pass |
| `events --follow` printed a new message 0.39 s after the send confirmed, with no CPU use while waiting | Pass |
| Real `backfill --detached --last 100` on File Transfer with a send through the main window partway: 100 saved in 44 s, 11 images, rows kept loading during the send | Pass |
| Unknown chat name rejected | Pass |
| Switching between File Transfer and another chat, both ways (about 1.9 s) | Pass |
| Peer labels in one real chat: text, sticker and quote-reply | Pass after fixing a reply bug |
| Baseline emits no existing messages | Pass |
| Second `watch` refused | Pass |
| Two identical messages stay distinct events | Pass |
| Message sent while `watch` was stopped is captured, with a gap | Pass |
| Incremental read by cursor | Pass |
| `backfill --chats 10 --last 10`: 90 messages from 9 chats, 9 images, no failed images, every `sent_minute` filled | Pass |
| The tenth chat rejected as `chat_ambiguous` | Pass, correct rejection |
| Rerun of `backfill` adds no duplicates (10 chats in the earlier run) | Pass |
| Clipboard unchanged after `backfill` | Pass |
| `export` CSVs parse back with all 90 rows | Pass |
| `watch` writes a new message to the `messages` table | Pass |
| Parser, alignment and row-matching checks (`selftest`) | Pass |

## Not yet tested

- `backfill --last all`, and speed on very long chats.
- Search for a contact who really is missing from the chat list. Clicking that result may behave differently.
- Sending from a group's detached window.
- Incoming messages in a covered detached window.
- `watch` saving a newly received image.
- Images that were never downloaded to this Mac.
- Sender labels on image messages in groups. An unrecognized label gives a null sender.
- Opening rows far down the chat list.
- Ambiguous names against real rows. Only the matching rule has a self-check.
- Incoming messages from another device, including misses, duplicates and latency. This includes `watch` opening a chat that is not already open.
- User interruption during a send.
- Logged-out detection, which is inferred from the login window having no tab buttons.
- Sleep, lock, network loss, app restart, minimized window and remote sessions.
- Running unattended under launchd, which may need its own Accessibility permission.

## Known limitations

- Chinese UI is not supported yet. The parser only knows WeChat's English labels, so on a Chinese UI senders and `sent_minute` would often be null. WeChat updates may also change the cell names.
- A peer whose display name is "Me" will read as self.
- Only messages WeChat has loaded are visible (about 25 messages after opening a chat). A burst larger than that produces a gap.
- A recalled or edited message in the middle of a snapshot causes a `no_overlap` gap, and new messages in that same snapshot are not emitted.
- Chats missing from the loaded chat list (410 here) give `chat_not_found`.
- The adapter assumes no two chats share the same name. Same-name chats in the chat list are rejected as `chat_ambiguous`, but a detached window that is already open is used without that check. A name with a comma and no space after it may also be rejected.
- Mini program cards (`MMNormalAppBrand`) and system notices (`MMSystem`) are skipped.
- History alignment has no real message IDs, so a recalled or edited message can leave a duplicate or a missing repeat.
- Commands take turns at the WeChat window, because it has one open chat and one input box. `backfill` works in short turns. If `send` or `watch` switches chats during a `backfill`, its saved progress stays, but it has to scroll back up, so it runs slower on a busy account.
- `events.db`, `images/` and any exports hold message content from every chat captured, unencrypted, and FileVault is off on this Mac. File permissions are the only protection.
