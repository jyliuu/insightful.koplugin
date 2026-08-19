# Changelog

This file records user visible changes to Insightful. Dates use the year, month, and day.

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
