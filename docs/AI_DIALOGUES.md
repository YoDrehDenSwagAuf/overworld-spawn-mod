# AI NPC Dialogues (Optional)

Wilds of Kanto can optionally let you have free-text conversations with NPCs
using a local or remote LLM. **This feature is completely optional.**

When AI Dialogues are off, misconfigured, offline, or failing, Wilds uses
normal Vanilla/Wilds dialogue only. No AI provider is a hard dependency.

## Quick start (recommended): LM Studio (free, local)

1. Install [LM Studio](https://lmstudio.ai/) on your computer.
2. Download a small instruct model (any chat-capable model is fine).
3. In LM Studio, start the **local server** (OpenAI-compatible API).
   - Default base URL: `http://127.0.0.1:1234/v1`
4. In Wilds / Mod Manager settings:
   - **AI Dialogues** → On
   - **AI Provider** → Local
   - **AI Endpoint** → `http://127.0.0.1:1234/v1` (default)
   - **AI Model** → `local` (or the model id LM Studio shows)
5. Talk to an ordinary town NPC (Pewter City is a good first test).
6. After normal dialogue, choose **Talk**, type a question, confirm.

Wilds does **not** bundle LM Studio or any model. The game only connects to
the endpoint you run locally.

## Optional: OpenAI

1. Create an API key on your OpenAI account (never share it; Wilds does not ship keys).
2. Store it in the private secrets file (see below) as `openai_api_key`.
3. Set **AI Provider** → OpenAI and **AI Model** to a chat model (e.g. `gpt-4o-mini`).

## Optional: Custom OpenAI-compatible endpoint

1. Set **AI Provider** → Custom.
2. Set **AI Endpoint** to your base URL (e.g. `https://host.example/v1`).
3. If the host needs a key, put it in the secrets file as `custom_api_key`.

## Private secrets file (API keys)

API keys are **not** Mod Manager options (they must not be serialized/logged
with normal settings).

Wilds stores them in private user data under the LOVE save directory:

```text
wilds_ai/provider_secrets.json
```

Example:

```json
{
  "openai_api_key": "sk-...",
  "custom_api_key": "",
  "_note": "plaintext local storage (not Pokémon save data)"
}
```

This is **local plaintext storage**. Do not commit this file. It is never
placed in the mod install folder or release ZIP.

Conversation memory (when **AI Memory** is On) is also private Wilds user
data — not Pokémon cartridge/save fields.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| AI Dialogues | Off | Master switch |
| AI Provider | Local | `local` / `openai` / `custom` |
| AI Model | `local` | Model id |
| AI Endpoint | `http://127.0.0.1:1234/v1` | Local/custom base URL |
| AI Memory | On | Bounded per-NPC chat history |

## Controls

- **Desktop:** free-text keyboard screen (Enter/A confirm, Esc/B cancel).
- **Controller / mobile:** NamingScreen letter grid with a longer max length.
  Glyph set is Gen1-style; keep questions short.

## Safety & privacy

- Player text is sent only as user dialogue; system instructions stay separate.
- Model replies are treated as plain text for TextBox display only — never executed.
- If the provider errors, times out, or returns junk, Wilds falls back safely.
- Logs use `[Wilds][AI]` and never print API keys or Authorization headers.

## Permissions

Manifest declares:

- `network` — async HTTP intent / `mod.fetch` when available
- `engine_internals` — already required by Wilds; used for `src.net.Fetch.request`
  because public `mod.fetch` is currently GET-only and chat needs POST + headers

## Troubleshooting

| Symptom | Check |
|---------|--------|
| No Talk option | AI Dialogues Off, or provider unreachable / unconfigured |
| “Nothing to say” | LM Studio server not running; wrong endpoint; firewall |
| OpenAI always fails | Missing `openai_api_key` in secrets file |
| Controllers hard to type | Expected with NamingScreen; use short questions or desktop keyboard |

## Developers

See `docs/AI_DIALOGUES_PLAN.md` for architecture and milestones.
Automated tests live under `tests/ai_*_unit_test.lua` (mock transport; no real LM Studio in CI).
