# Insightful for KOReader

Insightful is a simple, lightweight AI reading harness for KOReader. Instead of putting the whole book into every prompt, it gives the LLM five specific ways to read the book you have open.

Ask who Adeimantus is, for example. The LLM can search for his name and read the passages around a few matches. It can then answer from those passages. If it needs more context, it can search again. Each lookup appears on screen as an **AGENT ACTION**, so you can see which parts of the book went into the answer.

Insightful keeps this job narrow. Here is how it compares with two broader KOReader AI plugins.

| Plugin | Main design | Local book tools | Web search | Wider features |
| --- | --- | --- | --- | --- |
| Insightful | A small reading harness with saved chats for each book | Five tools that the model can call | No | Focused on the open book and the selected chat |
| [KOAssistant](https://github.com/zeeyado/koassistant.koplugin) | A full AI reading suite | Three book tools with automatic and manual modes | Yes | X-Ray, summaries, recap, library tools, artifacts, and more |
| [Assistant](https://github.com/omer-faruq/assistant.koplugin) | A general AI helper for selected text and book actions | No model-directed local book tool loop | Yes | Translation, dictionary, Term X-Ray, recap, custom prompts, and more |

<table>
  <tr>
    <td align="center" width="50%">
      <img src="docs/images/insightful-01-highlight-ai.png" alt="A passage selected in KOReader with the AI sparkle action visible"><br>
      <sub>Select a passage</sub>
    </td>
    <td align="center" width="50%">
      <img src="docs/images/insightful-02-actions.png" alt="Insightful quick action menu for a selected passage"><br>
      <sub>Choose an action or ask a question</sub>
    </td>
  </tr>
  <tr>
    <td align="center" width="50%">
      <img src="docs/images/insightful-05-agent-action.png" alt="Insightful showing a completed read_around call while waiting for the model response"><br>
      <sub>See which part of the book the LLM reads</sub>
    </td>
    <td align="center" width="50%">
      <img src="docs/images/insightful-04-answer.png" alt="Insightful conversation showing a selected passage and an AI answer"><br>
      <sub>Read the saved conversation</sub>
    </td>
  </tr>
</table>

Insightful works with OpenAI, DeepSeek, OpenRouter, and Anthropic. It does not build an index, create embeddings, or run jobs in the background. Each book can have several saved chats that you can close and open later.

## Install

1. Copy this directory to `koreader/plugins/insightful.koplugin` on the device.
2. Copy `configuration.lua.sample` to `configuration.lua`.
3. Add one or more provider profiles to `configuration.lua`.
4. Restart KOReader and open a book.

You should now see **Insightful** in the reader menu. Its submenu lets you continue the current chat, open the chat list, start a new chat, or view token use. Select some text and **AI** should also appear in the highlight menu.

`configuration.lua` contains your API key, so keep it private. Git already ignores it.

## Configure the provider

Add an entry under `providers` for each service you want to use. Insightful lists a provider in its settings menu when that profile has an API key. The `provider` value at the top of the file is the default.

| `provider` | Endpoint | API |
| --- | --- | --- |
| `openai` | `https://api.openai.com/v1/chat/completions` | OpenAI Chat Completions |
| `deepseek` | `https://api.deepseek.com/chat/completions` | DeepSeek Chat Completions |
| `openrouter` | `https://openrouter.ai/api/v1/chat/completions` | OpenRouter Chat Completions |
| `anthropic` | `https://api.anthropic.com/v1/messages` | Anthropic Messages |

Here is a configuration with OpenAI and OpenRouter. Select the active service and model under **Insightful**, then **Provider**. Insightful saves the selected provider and model in KOReader settings. The API keys stay in `configuration.lua`.

```lua
return {
    provider = "openai",
    stream = true,
    verify_ssl = true,
    providers = {
        openai = {
            base_url = "https://api.openai.com/v1/chat/completions",
            model = "gpt-4.1-mini",
            api_key = "YOUR_OPENAI_API_KEY",
        },
        openrouter = {
            base_url = "https://openrouter.ai/api/v1/chat/completions",
            model = "openrouter/auto",
            api_key = "YOUR_OPENROUTER_API_KEY",
        },
    },
}
```

The older flat configuration still works and appears as one provider. Move its endpoint, model, key, and provider-specific options into `providers` when you want to switch services from the menu.

DeepSeek and OpenRouter can list models through their APIs. Open a provider in the menu and choose **Load available models**. Insightful shows at most 50 models. The OpenRouter request asks for text models that support tools, and its submenu also has **Search available models** because the catalog is much larger. **Enter model ID** lets you use an exact model that is not in the displayed list. Refreshing the list does not send a chat request.

The sample configuration includes the less common settings, such as timeouts, extra request fields, and HTTP headers. Insightful leaves the output token limit and temperature unset for OpenAI, DeepSeek, and OpenRouter unless you choose values yourself. Anthropic requires `max_tokens`, so Insightful uses `8192` when you leave it out.

## Read with Insightful

Select a passage and tap **AI**. Under Zen UI, this is the sparkle icon. The menu gives you a few useful shortcuts. **Explain** deals with the passage as a whole, while **Explain terms** focuses on its vocabulary. Use **Context / history** for the setting or ideas behind a passage. Use **People / characters** when you need to know who someone is.

Choose **Ask AI…** when you want to write the question yourself. The conversation opens with the keyboard closed. Tap **Message Insightful…** to start typing. The message field stays above the keyboard, and a tap in the conversation closes the keyboard again.

The four shortcuts send their questions immediately. They use the current chat unless **New chat for highlighted actions** is on.

When that setting is off, the highlighted passage menu also shows **Start a new chat**. Tick it before choosing an action to put that one answer in a fresh chat. It applies to that highlight only and does not change the setting for the book.

Open **Insightful** from the reader menu when you want to manage chats for the current book. Choose **Chats** to see the saved chats, or tap the menu icon in an open chat. Tap a chat to open it. Hold a chat and confirm the prompt to delete it. Choose **Start new chat** when you want a blank conversation.

Turn on **New chat for highlighted actions** when each button chosen from the highlighted passage menu should start a separate chat. This includes **Ask AI…**. Once the chat is open, later messages continue that chat. The setting applies only to the current book.

Each answer is labelled with the model that wrote it, so a chat that spans a provider or model change still shows which model produced each reply. Answers saved before this was added are labelled **AI**.

If a request fails, the error appears in the chat and **Retry** becomes available. It runs the same question again without adding a second copy of it to the chat. Failures that cannot succeed on a second attempt, such as a missing or rejected API key, leave **Retry** disabled because the configuration has to change first.

## Check token use

Open **Insightful**, then **Statistics**, from the reader menu. **General** shows the current provider, model, streaming mode, and output limit. **Current book** shows model requests and token use for the open book. **All books** shows the combined totals for every book.

Insightful uses the token counts returned by the provider. The totals include each model request made while answering, including requests made after a book tool runs. If a provider response has no token counts, the statistics screen shows how many requests are missing counts.

When the provider reports a request cost in US dollars, Insightful adds it to the current book and all books totals. OpenRouter returns this cost. The other supported providers normally return token counts without a request cost, so Insightful shows the cost as unavailable. Insightful does not estimate cost from a saved price table.

Counts begin after you install a version that includes statistics. Insightful does not estimate token use for older saved chats.

## Open the chat list with a gesture

Insightful adds an action named **Insightful: show chats** to KOReader's gesture manager. Open **Taps and gestures**, then **Gesture manager**, and assign the action to a corner hold, a swipe, or a multiswipe. The assigned gesture opens the chat list for the current book without selecting text.

## See what the model reads

After you send a question, the provider can start writing an answer or ask Insightful to read something. Provider code cannot call KOReader directly. It can only ask for one of the five functions below.

Insightful checks the request and runs the function against the open document. It then returns a limited amount of text to the provider. The provider can ask for another function or finish the answer.

```text
model → tool request → Insightful → open document → limited result → model
```

| Function | What Insightful does |
| --- | --- |
| `search_book` | Searches the open book for one or more phrases and returns a limited number of matches. |
| `read_around` | Reads a short section around a page, location, search match, or internal link. |
| `list_links` | Lists links on the current page or near another location. |
| `toc` | Reads the table of contents. |
| `current_position` | Reports your current reading position. |

A request often goes from `search_book` to `read_around` and then to the answer. Each tool call returns a limited amount of book text.

The **AGENT ACTION** block is a record of calls that Insightful actually ran. You see the function name and the useful argument for that call. A search shows its query. A read shows the page, match, link, or location. Private reasoning from the provider stays hidden.

`list_links` starts on the current page unless the model gives it another location. Internal links get temporary IDs so `read_around` can follow them. External URLs are shown but never opened. When Insightful moves through a reflowable document to inspect another location, it returns you to the place where you were reading.

## Conversations and privacy

Your turns appear in gray blocks marked **YOU**, with model replies under **AI**. Replies can contain headings, lists, links, quotes, code blocks, and tables. Text arrives in short batches instead of making the Kindle wait for the complete answer.

Insightful saves all chats for a book in one file in KOReader's settings directory.

```text
insightful/conversations/<book-id>.lua
```

Token totals are stored separately as aggregate numbers.

```text
insightful/statistics.lua
```

KOReader's stored partial checksum is normally used as the book ID. Insightful saves each chat's questions and model replies, along with the current chat and the setting for starting a new chat from highlighted actions. The first test build with multiple chats moves an existing conversation into the first chat for its book. Text fetched by a book function is kept only for the active request and is not copied into the conversation file.

The provider may receive the passage you selected, your question, earlier conversation turns, and text returned by a book function. Insightful never uploads the full book on its own.

## Zen UI

Turn on **AI assistant** in Zen UI's highlight settings. Insightful uses this slot so the sparkle icon stays in Zen UI's custom highlight menu.

## Development

Run the checks from the plugin directory.

```sh
./scripts/test.sh
```

The script runs the same tests under LuaJIT and Lua, then parses every Lua file. The tests cover the agent loop, tool limits, provider formats, streaming, storage, links, and conversation rendering. They do not test the final screen layout or a live network request on a Kindle.

Insightful uses Semantic Versioning and Conventional Commit prefixes. Use `./scripts/bump-version.sh patch`, `minor`, or `major` to update `VERSION`, `_meta.lua`, and `CHANGELOG.md` together. A `vX.Y.Z` tag runs the checks, uses that version's changelog section as the release notes, and creates a ZenPM compatible GitHub release ZIP. See [RELEASING.md](RELEASING.md) for the complete release steps.

## License and notice

Insightful is licensed under the [GNU General Public License version 3](LICENSE). See [NOTICE](NOTICE) for copyright and related project credits.
