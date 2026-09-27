# Requirements: Recommended rail, per-chat Save, model and token usage

Status: implemented (2026-09-27; migration `e8f2a4c6b310`) · Jira Epic OTTAI-21 · stories OTTAI-22 (store recommendations), OTTAI-23 (rail), OTTAI-24 (earlier replies, tablet, phone), OTTAI-25 (backend saves), OTTAI-26 (Save button), OTTAI-27 (model and tokens)

This follows the redesign in [design.md](../../design.md). It changes three things:

1. When a reply brings videos, the recommended videos appear in a vertical rail on the right, titled **"Recommended"**. The rail replaces the in-chat "Alternatives" block.
2. The save button says just **"Save"**, and saves belong to the chat they were made in, not to one global library.
3. The chat box shows which model is answering, how full its context is, and how many tokens the chat has used.

## Decisions
- The mini-player docks at the top of the rail, with the Recommended list under it, like YouTube.
- By default the rail shows only the **latest** reply's recommendations. Earlier replies get a "Show recommendations" link that loads theirs.
- Existing global saves are deleted by the migration; they aren't moved into chats.
- Seek, no-autoplay and the coral theme stay as they are.

## How it works today
- Recommendations are fetched only for the video that is **playing**: `_loadRecommendations` in `app/lib/chat/chat_controller.dart` calls `GET /videos/{id}/recommendations`. They are held in memory and cleared when playback stops (`_close`), so earlier replies can't show them.
- The in-chat block is `Alternatives` (`app/lib/chat/reply.dart`). Its list comes from `ChatState.alternativesFor`. The Up next strip is `app/lib/shell/recommendations.dart`.
- The mini-player floats top-right in the chat area (`app/lib/player/mini_player.dart`, 420px wide).
- Messages store only `video_ids` (`backend/app/models.py`); recommendations aren't saved.
- Saves use `SavedVideo`, unique per (user, video), through `/api/me/saved` (`backend/app/account/router.py`). In the app they live in `app/lib/library/saved.dart`, labelled "Save to practice routine" / "Saved", with a "Chats | Saved" switch in `app/lib/shell/side_nav.dart`.
- Ollama's token counts are thrown away in `chat_json` (`backend/app/ollama.py`). The LLM gets the system prompt plus the last 6 messages (`understand()` in `backend/app/chat/llm.py`). The model is picked only in Settings.

---

## R1: Recommended rail (layout)

**Desktop (width 1024px or more)**
- A right-hand column about 380px wide, full height. From top to bottom:
  1. The **mini-player**, docked and no longer floating. It shows only while a video is open, and keeps all its current controls.
  2. A **"Recommended"** header.
  3. A vertical, scrollable list of video rows.
- Each row shows:
  - thumbnail (16:9) with a duration badge
  - title (up to 2 lines)
  - channel
  - a green "NN% match" badge
- The playing video's row is highlighted. Videos already played in this chat are dimmed and marked "Watched".
- The rail appears as soon as a reply with videos arrives, even before anything plays; videos still don't autoplay. Before the chat has any videos, the rail is hidden and the chat takes the full width.
- In theater mode the large player sits to the left of the rail, and the rail keeps its list.

**Tablet (720–1023px)**
- The rail becomes a "Recommended" button in the top bar that opens it as a sheet from the right (`ShadSheet`).
- The mini-player keeps its current floating card.

**Phone (under 720px)**
- Each reply keeps an in-chat collapsible block, renamed **"Recommended"**, that starts closed.
- The mini-player keeps its phone strip.

**Removed**
- The "Alternatives" block on desktop and tablet.
- The Up next strip (`recommendations.dart`).
- The word "Alternatives" everywhere, including collapse keys, copy and tests.

**Unchanged**
- Clicking a row plays that video in place.
- "next", the N key and voice commands play the top unplayed row of the rail.

**shadcn:** `ShadCard`, `ShadBadge`, `ShadButton.ghost` rows, `ShadTooltip`, `ShadSheet` (tablet), `ShadAccordion` (phone).

**Acceptance criteria**
- A new reply with videos shows the rail with its recommendations and nothing autoplays.
- Playing a video from the rail docks the mini-player at the top of the rail, and the video never reloads when switching between mini and theater.
- Nothing overflows at the golden sizes: desktop, laptop-short, tablet and phone.

## R2: Recommendations per reply

**Which reply the rail shows**
- **Default:** the rail shows only the **latest** reply's recommendations. This holds even while a video from an earlier reply is playing, and the rail moves on when a new reply with videos arrives.
- **Earlier replies:** each earlier reply with videos has a **"Show recommendations"** link (`ShadButton.link`).
  - Clicking it loads that reply's recommendations into the rail. The header then reads "Recommended · earlier: ‹video title›" and shows a **"Back to latest"** link.
  - The rail returns to the latest reply on "Back to latest", when a new reply arrives, or when the chat is reopened.
  - On phones the link opens that reply's "Recommended" block. On tablets it opens the sheet.

**What the rail lists for a reply**
- The reply's other search results, plus the recommendations for its main video.
- No duplicates, the reply's main video left out, sorted by match.

**Where the recommendations come from (backend)**
- When the reply is made, compute the recommendations for its main video with the existing `recommendations()` in `backend/app/videos/service.py`.
- Store them on the message as `messages.recommendations`, a JSONB list of `{youtube_id, match}` (Alembic migration).
- Return them in the chat response and in `GET /conversations/{id}/messages`. That way a chat reopened from History shows its rail with no second lookup.
- Messages from before this change have no stored list. For them the app falls back to `GET /videos/{id}/recommendations` and keeps the result per video for the session. A backfill script is optional.

**In the app**
- Keep recommendations per reply (for example `Map<int, List<Video>>`) instead of the single `recommendations` list.
- Stopping a video no longer clears them.

**Acceptance criteria**
- A reopened chat shows the latest reply's recommendations straight away.
- "Show recommendations" on an earlier reply swaps the rail to that reply's list, and "Back to latest" restores it.
- "next" follows whichever list the rail is showing.
- Backend test: recommendations are stored and returned. App test: switching between replies.

## R3: "Save", scoped to the chat

**The button**
- It reads **"Save"**, or **"Saved"** when on. Tooltips: "Save to this chat" / "Remove from this chat".
- It appears on the main video card, in the mini-player header, and as a hover action on rail rows.
- The "practice routine" and "library" wording is removed everywhere.

**What a save belongs to**
- A save belongs to one (chat, video) pair, so the same video can be saved in two chats separately.
- Deleting a chat, or "Clear all conversations", deletes that chat's saves.

**Sidebar**
- The "Saved" tab lists only the **current chat's** saves, labelled "Saved in this chat · N", newest first. Click a save to play it; hover to remove it.
- A new chat with nothing sent yet shows: "Save videos in this chat to find them here."

**Other ways to save**
- Saying or typing "save this" saves the playing video to the current chat.
- Demo users behave the same way. Their saves are deleted with their chats at demo cleanup.

**shadcn:** `ShadButton.outline`, `ShadBadge`, `ShadTooltip`.

**Acceptance criteria**
- Saving in chat A doesn't mark the video as saved in chat B.
- Switching chats switches the Saved list.
- Saving the same video twice in one chat does nothing extra.
- App tests cover these cases.

## R4: Per-chat saves (backend)

**Schema**
- `saved_videos` gets a `conversation_id` column: a foreign key to conversations, `ON DELETE CASCADE`, `NOT NULL`.
- The unique constraint changes to (conversation_id, youtube_id).
- `user_id` stays, for ownership checks.

**Migration**
- Deletes all existing saved rows, then adds the column and the constraint.
- The downgrade drops the column and restores the old constraint. The saves themselves are not restored.

**API**
- `GET /api/conversations/{id}/saved`
- `PUT /api/conversations/{id}/saved/{youtube_id}` (safe to repeat)
- `DELETE /api/conversations/{id}/saved/{youtube_id}`
- All three check ownership, returning 404 if the chat isn't the user's, and are rate-limited like the current endpoints.
- `/api/me/saved` is removed.

**Acceptance criteria**
- Backend tests cover:
  - ownership (404 for another user's chat)
  - repeated saves
  - the cascade on chat delete and on clear-all
  - the migration on a database with existing saves

## R5: Model, context and token usage in the chat box

**Status line under the composer** (mono, next to the shortcut hint)
- **Model** in use, for example `llama3.2:3b`. Clicking it opens a `ShadPopover` for switching the model for this chat, using the same list as Settings (`/api/models`).
- **Context usage** for the next request, for example `ctx 1.2k / 4k`, with a small `ShadProgress` meter.
  - The meter turns amber above 75% and coral above 90%.
  - Its tooltip explains that only the last N messages are sent to the model.
- **Tokens used in this chat**, for example `3.4k tokens` (prompt plus output). The tooltip breaks this down per reply.

**Per reply**
- The assistant reply header shows the model and token count next to "Matched in 0.8s", for example `llama3.2:3b · 412 tok`.
- Replies made by the keyword fallback show "no LLM".

**Backend**
- `chat_json` returns Ollama's `prompt_eval_count` and `eval_count` along with the content.
- The chat and summary endpoints store `messages.model`, `prompt_tokens` and `output_tokens` (same migration as R2) and return them. The conversation response includes the totals.
- Each model's context length comes from Ollama `/api/show` (`model_info.*.context_length`, or `num_ctx` if set). It is cached and exposed in `/api/models` as `{name, context}`.
- Requests send an explicit `num_ctx`, so the limit shown in the app is the one actually used.

**Guard**
- If the next prompt would go over about 90% of the context window, the backend drops the oldest history messages first instead of letting Ollama cut them silently.
- When that happens, the status line says "older messages trimmed".

**Recommendations and saves are never added to the LLM prompt**, so they don't use context.

**shadcn:** `ShadPopover`, `ShadProgress`, `ShadTooltip`, `ShadBadge`.

**Acceptance criteria**
- The numbers shown match Ollama's reported counts.
- Switching the model changes the next reply's model badge.
- The trim guard has a unit test.
- Fallback replies show "no LLM" and add 0 tokens.

## Applies to everything
- Works on web, Android and Windows.
- New golden tests: the rail on desktop, the rail sheet on tablet, and the phone "Recommended" block.
- Coral tokens and shadcn components only (design.md §6).
- Backend passes pytest, bandit and pip-audit. The app passes the analyzer, format check and tests.
