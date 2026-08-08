# Insightful Working Instructions

This file applies to this repository.

## Required product shape

- Keep one persistent conversation per book.
- Keep the path `provider -> neutral tool call -> BookTools.execute -> KOReader document API` explicit.
- Keep provider code independent of KOReader document methods.
- Keep book-tool code independent of provider wire formats.
- Implement only `search_book`, `read_around`, `list_links`, `toc`, and `current_position`.
- Do not add embeddings, a vector database, multiple agents, web search, background indexing, or multiple chats per book.

## Editing and checks

- Read current KOReader and reference-plugin APIs before changing integration code.
- Make small Lua modules with explicit inputs and return values.
- Keep all text returned by book tools bounded.
- Never log API keys, authorization headers, or complete books.
- Save conversation state after user and assistant turns with KOReader's settings writer.
- Run `./scripts/test.sh` after code changes.
- Run `luac -p` on every Lua source file before reporting completion.
- Treat host tests as logic checks. Report physical-Kindle behavior as unverified until it is observed on the device.
