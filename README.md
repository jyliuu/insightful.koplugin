# BookAgent for KOReader

BookAgent gives each book one persistent AI conversation. A highlighted passage can enter the conversation through one of five actions. The OpenAI-compatible model can answer directly or call five bounded tools against the open KOReader document:

- `search_book`
- `read_around`
- `list_links`
- `toc`
- `current_position`

The plugin does not index books, create embeddings, send a whole book automatically, run background work, or create multiple conversations per book.

## Install

1. Copy this directory to `koreader/plugins/bookagent.koplugin`.
2. Copy `configuration.lua.sample` to `configuration.lua`.
3. Set `base_url`, `model`, and `api_key` in `configuration.lua`.
4. Restart KOReader.

Highlight text and tap `AI`. The main KOReader menu also contains `BookAgent` so a conversation can be reopened without selecting text.

**Ask AI…** opens one full-page conversation view immediately with the keyboard closed. Tap the message field to open the keyboard. The chat remains active beneath KOReader's modal keyboard, so its conversation pane, scrolling, and close control still respond; tap the conversation pane to dismiss the keyboard. A message field and **Send** button stay below the conversation for the first question and every follow-up. Chat navigation advances by half a visible page, leaving the previous half above for reading continuity. User turns appear in gray blocks labeled **YOU**; AI turns are labeled **AI** and render Markdown headings, emphasis, lists, links, quotes, and code blocks. Horizontal rules separate turns.

The current AI turn streams into that full-page view in short batches suited to an e-ink screen. When the model calls a book function, an **AGENT ACTION** block shows the actual function name and a safe argument summary, such as `search_book` with its query or `read_around` with its hit ID. Direct answers show only **Waiting for model response…** until visible text arrives. Private model reasoning is never displayed, and BookAgent does not invent actions. **Stop** cancels the active network subprocess.

On Zen UI, enable its **AI assistant** highlight item. BookAgent registers in that recognized slot so the AI icon is not removed by Zen UI's custom highlight menu.

Conversation files are stored under KOReader's settings directory at `bookagent/conversations/<book-id>.lua`. The preferred book ID is KOReader's stored partial document checksum. Raw tool excerpts are sent only for the active request and are not persisted in the conversation.

`list_links` defaults to the current page. It can also inspect a page, XPointer, or search hit. Internal results receive temporary link IDs that `read_around` can follow. External URLs are reported but never opened, and rolling-document inspection restores the reader's original XPointer.

## Host checks

Run:

```sh
./scripts/test.sh
```

These checks cover the agent loop, multiple calls in one turn, budgets, malformed responses, failed tools, hyperlink normalization and position restoration, quick actions, streamed SSE text, hidden-reasoning activity, streamed tool calls, transport framing, conversation HTML structure, Markdown viewer wiring, and per-book persistence. They do not prove final display geometry, live network behavior, or document extraction on a physical Kindle.
