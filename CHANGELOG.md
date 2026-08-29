# Changelog

This file records user visible changes to Insightful. Dates use the year, month, and day.

## 0.5.0 (2026-08-29)

### Added

* The highlighted passage menu now offers a one-time choice to use the current chat or start a new chat, whichever is opposite to the saved setting.
* KOReader's gesture manager now includes **Insightful: show current chat**, which opens the active chat directly.

## 0.4.2 (2026-08-23)

### Added

* The highlighted passage menu now offers **Give examples**, which asks the model to demonstrate the passage's meaning with clear, concrete examples.

### Fixed

* Quick actions now show the exact prompt sent to the model in the chat and chat title.

## 0.4.1 (2026-08-19)

### Fixed

* **Retry** still appears after a chat is closed and reopened. A chat whose last message is an unanswered question now offers to send it again, which also survives restarting KOReader.

## 0.4.0 (2026-08-19)

### Added

* A failed answer now offers **Retry**, which runs the same question again without adding a second copy of it to the chat. Failures that cannot succeed on a second attempt, such as a missing or rejected API key, leave the button disabled.
* Each answer is labelled with the model that wrote it, so a chat that spans a provider or model change shows which model produced each reply.
* The highlighted passage menu offers **Start a new chat** when the book does not already start one. It applies to that highlight only and does not change the setting for the book.
* A rate limited request now says so instead of reporting that the service could not be reached.

### Fixed

* The provider menu no longer crashes when a provider profile has no model set.

## 0.3.0 (2026-08-19)

### Added

* `configuration.lua` can hold several provider profiles, and the Provider menu switches between the ones that have an API key.
* The Provider menu lists a service's available models, with a search and an exact model ID entry. DeepSeek and OpenRouter supply their catalogs.
* Insightful now ships a changelog of user visible changes.

### Changed

* The selected provider and model persist in KOReader settings. API keys stay in `configuration.lua`.
* A configuration written in the older flat form still works and appears as a single provider.

## 0.2.2 (2026-08-10)

### Fixed

* Insightful now finishes an active answer after its chat is closed.
* Live answers refresh in larger batches, which reduces screen flashes while text streams.
* The selected setting for starting a new chat from a highlighted passage now persists for each book.
* The highlighted passage action menu now has a clear title.

## 0.2.1 (2026-08-10)

### Added

* The Statistics screen shows request counts, token use, and reported cost for the current book and for all books.

### Changed

* Insightful now appears first in the KOReader tools menu.

## 0.2.0 (2026-08-09)

### Added

* Each book can have several saved chats, with one chat active at a time.
* The chat list can open, create, and delete chats for the current book.
* Highlight actions can start a new chat when that per-book setting is enabled.

### Changed

* The model can keep using the five book tools until it has enough context or the request is cancelled.

## 0.1.0 (2026-08-09)

### Added

* The first Insightful release for KOReader.
* Support for OpenAI, DeepSeek, OpenRouter, and Anthropic.
* Five bounded tools for searching and reading the open book, listing links, reading the table of contents, and checking the current position.
* Saved conversations for each book, streamed answers, and highlighted passage actions.
