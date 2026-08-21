# AI NPC Dialogues — Implementation Plan

**Status:** Approved for implementation (cloud agent deliverable)  
**Feature:** Optional free-text NPC conversations powered by a local or remote LLM  
**Constraint:** Completely optional — Wilds must behave exactly as today when AI Dialogues are off or unavailable  

---

## 1. Goals

Make Gen1 / Gen2 NPCs feel more immersive by allowing optional free-text conversations.

When enabled and a provider is reachable, the player can:

1. Talk to an eligible NPC (normal Vanilla/Wilds dialogue first).
2. Choose **Talk** or **Leave**.
3. Enter free-text questions.
4. Receive short, in-character replies from an LLM that uses structured Wilds context.

When disabled, misconfigured, offline, timed out, or returning invalid output: fall back to normal dialogue with **no gameplay freeze**.

---

## 2. Verified engine network surface (research)

### 2.1 Public mod API (`mod.fetch`)

Gen1Recomp documents and exposes:

| Method | Notes |
|--------|--------|
| `mod.fetch:available()` | `false` without transport or `network` permission |
| `mod.fetch:get(url, opts)` | http/https only; `opts.accept`, `opts.maxSeconds` (≤30) |
| `mod.fetch:poll(handle)` | `{ status, body, err, progress }` — never blocks |
| `mod.fetch:release` / `cancel` | handle lifecycle |

**Finding:** Public `mod.fetch` is **GET-only**. Chat Completions require `POST` with a JSON body, custom headers (`Authorization`, `Content-Type`), and a response body.

### 2.2 Engine internals (`src/net/Fetch.lua`)

Already present on the Gen1Recomp `dev` branch:

| Method | Notes |
|--------|--------|
| `Fetch.get` | GET + body |
| `Fetch.post` | POST **without** returning response body (log-style) |
| `Fetch.request(url, opts)` | `method` / `body` / `headers` → body + HTTP code |
| `Fetch.poll` / `release` / `cancel` | Same async contract |

Transport: `HostShell.httpRequest` (curl on desktop; Android `love.system.httpRequest` bridge). Workers run off the render thread.

**Finding:** `require("src.net.Fetch")` needs **`engine_internals`** (already declared by Wilds). Undeclared `src.*` requires are unsupported and may break; under `POKEPORT_DEV=1` they warn.

### 2.3 Chosen network path

```text
lib/ai/transport.lua
  1. Prefer runtime probe: mod.fetch.request / mod.fetch.post  (future-proof)
  2. Else: pcall(require, "src.net.Fetch") → Fetch.request   (current path)
  3. Else: report unavailable → safe vanilla fallback
```

Manifest permissions after this feature:

```json
"permissions": ["engine_internals", "network"]
```

- `network` — documents intent; enables `mod.fetch` if/when POST is public.
- `engine_internals` — already required; needed today for `Fetch.request`.

**Never** call blocking `HostShell.http*` / `curl` / `socket` on the render thread.

---

## 3. Architecture

New optional subsystem (isolated from spawn/follower/catching cores):

```text
lib/ai/
  init.lua                 -- install / tick / eligibility gate; no-op when off
  config.lua               -- options + private provider config + defaults
  dialogue.lua             -- NPC talk flow: vanilla → Talk/Leave → input → reply
  context_builder.lua      -- structured Gen1/Gen2 context via GameCompat only
  memory.lua               -- optional bounded conversation memory (Wilds private data)
  transport.lua            -- async HTTP adapter + mock inject for tests
  prompt.lua               -- system prompt + sanitization + TextBox packing
  providers/
    init.lua               -- provider registry / resolve
    local_openai.lua       -- LM Studio / local OpenAI-compatible (default)
    openai.lua             -- Official OpenAI (user API key)
    openai_compatible.lua  -- Custom base URL + optional key
    mock.lua               -- Deterministic CI provider
```

Wiring (minimal invasion):

- `main.lua` — lazy-require `lib/ai/init` after GameCompat-supported boot; call `Ai:install()` / poll on a low-frequency tick or `world.stepped` / present hook **only when a request is active or AI is enabled**.
- Wrap `OverworldController.talkTo` **after** ambient wrap (chain), only when AI Dialogues are on.
- Do **not** put HTTP code inside ambient/follower/spawn modules.

---

## 4. Provider contract

```lua
Provider:isConfigured(mod) -> boolean
Provider:startRequest(mod, context, message) -> handle | nil, err
Provider:poll(mod, handle) -> { status = "pending"|"success"|"error", text?, err? }
Provider:cancel(mod, handle)
```

Rules:

- All provider methods are `pcall`-guarded at the dialogue layer.
- Invalid JSON / empty / oversized / non-text → `error` → vanilla fallback message or leave.
- LLM output is **TEXT ONLY** — never `load` / `dofile` / `loadstring` / execute.
- Player text is always the `user` role; system instructions stay in `system`.

### 4.1 Local OpenAI-compatible (default)

```text
provider   = local
endpoint   = http://127.0.0.1:1234/v1
model      = (configured string or "local")  -- never hardcode one model id
apiKey     = optional (LM Studio usually none)
path       = /chat/completions
```

Request shape (OpenAI chat completions):

```json
{
  "model": "<model>",
  "messages": [
    { "role": "system", "content": "<prompt>" },
    { "role": "user", "content": "<player text>" }
  ],
  "temperature": 0.7,
  "max_tokens": 120
}
```

Parse `choices[1].message.content`. Support LM Studio quirks (missing model → try without / use whatever server returns).

### 4.2 OpenAI / Custom

- Same request shape; different base URL.
- API key from **private secrets file**, never from `options.lua` / manifest / ZIP / repo.
- Do not log `Authorization`, API keys, or full secret-bearing config.

### 4.3 Mock (tests)

Injected transport returns canned bodies so CI proves:

- `"Reply with exactly: Wilds AI OK"` + user `"test"` → `"Wilds AI OK"`
- Timeouts, HTTP errors, malformed JSON, injection attempts, disabled path.

---

## 5. Configuration & secrets

### 5.1 Public Mod Manager options (no secrets)

| Key | Label (≤14) | Type | Default | Notes |
|-----|-------------|------|---------|-------|
| `ai_dialogues` | `AI Dialogues` | toggle | `false` | Master switch |
| `ai_provider` | `AI Provider` | choice | `local` | `local` / `openai` / `custom` |
| `ai_model` | `AI Model` | text | `local` | Model id or local alias |
| `ai_memory` | `AI Memory` | toggle | `true` | Bounded history |
| `ai_endpoint` | `AI Endpoint` | text | `http://127.0.0.1:1234/v1` | Local/custom base |

API keys are **not** Mod Manager options (avoid global serialize/log).

### 5.2 Private secrets / provider config

File (LOVE save directory / private Wilds user data — **not** mod install dir, **not** Pokémon save):

```text
ai_provider_secrets.json   -- plaintext local storage; documented as such
```

Contents example:

```json
{
  "openai_api_key": "",
  "custom_api_key": ""
}
```

Access via `lib/ai/config.lua` helpers that:

1. Prefer engine-safe write paths (`love.filesystem` when available outside sandbox refusal, else LegacyCompat `io` into the known save root when exposed).
2. Never write secrets under `mods/overworld_wild_spawns/`.
3. Redact on every log path.

Conversation memory uses `mod.storage` (Wilds private, playthrough-scoped) **or** a separate user-data JSON under the same private root — **never** `game.save` / Pokémon cartridge fields.

---

## 6. NPC context builder (GameCompat only)

`context_builder.lua` builds a plain Lua table (then prompt text). **No Gen1-only memory addresses** in generic AI code.

### 6.1 Fields

| Field | Source |
|-------|--------|
| `generation` | `GameCompat.generation` |
| `gameVersion` | `GameCompat.gameVersion` |
| `region` | Gen1 → Kanto; Gen2 → Johto/Kanto from map tables / best-effort |
| `mapId` | `GameCompat.currentMapId` / live OW |
| `locationName` | map display name when available |
| `npcId` | Stable identity: `mapId` + object index/name + trainer id when present |
| `npcName` | Hierarchy: `def.name` → trainer name → class + “Trainer” → “Someone” |
| `trainerClass` / `role` | From NPC/trainer def when present |
| `team` | Trainer party species/levels when exposed safely |
| `battled` / `defeated` | Trainer flags / bit when available; else unknown |
| `storyHints` | Conservative flags (`mod.world:getFlag` only when useful); no spoilers beyond local knowledge |
| `localKnowledge` | Curated short blurbs keyed by map/NPC class (data table) |
| `playerParty` | Summarized species/levels via `GameCompat.party` |
| `follower` | Active follower species from Wilds follower state when present |
| `badges` | Count / names when save exposes them; omit if unavailable |
| `priorTurns` | From memory module (bounded) |

### 6.2 Knowledge boundaries (system prompt)

- Speak as the NPC; short Pokémon-style lines (prefer ≤2–3 TextBox pages).
- Only know what that NPC plausibly knows (town, job, team, local rumors).
- Do not invent modern tech, real-world politics, or out-of-region spoilers.
- Do not output code, JSON, markdown fences, or instructions to the game.
- If unsure: say you don’t know, stay in character.

### 6.3 Name hierarchy

```text
explicit NPC name
  → trainer name field
  → trainer class + generic title
  → map object name
  → "Someone"
```

---

## 7. Eligibility rules (conservative)

**Eligible (default allow):**

- Ordinary town/route talk NPCs with a normal `talkTo` path.
- Pewter City vertical slice NPC (non-story, safe) for M5.
- Trainers **after** normal dialogue, with team/battle-state context when known.

**Ineligible / skip AI offer:**

- Cutscene / script-busy (`followerInteractionBusy`, engaging battles, warp, menus).
- Story-critical NPCs on a curated denylist (Oak intro, rival scripted fights, etc.) — start small; expand carefully.
- Wilds ambient Pokémon / followers (keep existing cry/talk owners).
- Moving NPCs mid-step (same gate as vanilla).
- When `ai_dialogues` is off, provider unconfigured, or transport unavailable.

Flow:

```text
vanilla talkTo / presentText
  → if eligible + AI on + configured:
       presentTextChoice("Talk more?" / Talk | Leave)
  → else: done (vanilla only)
```

---

## 8. Free-text UI

### 8.1 Desktop / keyboard

Lightweight input screen (stack push) accepting `love.textinput` / keyboard when available; Confirm = A/Enter, Cancel = B/Esc. Max length ~80–120 glyphs.

### 8.2 Mobile / controller (M9)

Fallback to `mod.ui.NamingScreen` / engine `NamingScreen` with elevated `maxLen` (e.g. 32) and title like `ASK WHAT?`. Document glyph-grid limitations.

### 8.3 Response presentation

- Sanitize: strip control chars, code fences, role tags; clamp length; split into TextBox-friendly chunks.
- Loading: `"..."` or `"<Name> is thinking..."` via `GameCompat.presentText` while polling.
- Poll from tick; **never** busy-wait.
- On error/timeout: short apology line or silently end; restore vanilla ownership.

---

## 9. Memory (M7)

- Optional (`ai_memory`).
- Per-NPC ring buffer (e.g. last 6 turns), global cap, prune oldest.
- Stored in Wilds private user data / `mod.storage` — **not** Pokémon save blobs.
- Reset: option or diagnostics helper clears memory keys.
- Injected into context as prior turns; still treat new player text as untrusted user content.

---

## 10. Milestones (implementation order)

| ID | Scope | Automated proof |
|----|--------|-----------------|
| **M1** | `transport.lua` + DEV helper + mock transport | Mock chat → `"Wilds AI OK"`; no NPC wire |
| **M2** | Provider abstraction + local OpenAI-compatible | Provider unit tests with mock HTTP |
| **M3** | Config + secrets + diagnostics (`[Wilds][AI]`) | Config/redaction tests |
| **M4** | Context builder Gen1/Gen2 | Context field unit tests; GameCompat-only |
| **M5** | Free-text UI + Pewter vertical slice | Dialogue flow unit tests (mocked UI/stack) |
| **M6** | General eligibility + trainer context | Eligibility + trainer context tests |
| **M7** | Memory bounded + reset | Memory tests |
| **M8** | OpenAI + custom providers | Provider config tests (no real keys) |
| **M9** | Mobile/controller NamingScreen path | Input path selection tests |
| **M10** | Hardening, docs, full suite, packaging | Full Wilds regression + `docs/AI_DIALOGUES.md` |

Do **not** stop after M1. Only LM Studio install / real model / ROM device testing remain manual.

---

## 11. Tests (CI coverage areas)

New files (examples):

```text
tests/ai_transport_unit_test.lua
tests/ai_provider_local_unit_test.lua
tests/ai_config_secrets_unit_test.lua
tests/ai_context_builder_unit_test.lua
tests/ai_dialogue_flow_unit_test.lua
tests/ai_eligibility_unit_test.lua
tests/ai_memory_unit_test.lua
tests/ai_prompt_sanitize_unit_test.lua
tests/ai_openai_custom_unit_test.lua
tests/ai_disabled_noop_unit_test.lua
```

Must cover (user’s 20 areas mapped):

1. Disabled → zero gameplay change / no network  
2. Unconfigured provider → no crash, vanilla path  
3. Mock transport success `"Wilds AI OK"`  
4. Timeout → error → fallback  
5. HTTP error / invalid endpoint  
6. Malformed JSON  
7. Empty / oversized model reply  
8. Prompt injection treated as user text only  
9. LLM “code” output never executed  
10. Context Gen1 fields  
11. Context Gen2 fields  
12. Trainer team / battle state  
13. Follower summary in context  
14. Memory write/read/bound/reset  
15. Secrets not in options schema / not logged  
16. Local provider request shape  
17. OpenAI provider requires key; custom endpoint  
18. Eligibility denylist / busy world  
19. TextBox sanitization  
20. Packaging: AI libs ship; tests stay out of ZIP hygiene lists updated  

Wire new tests into `.github/workflows/release.yml` standalone list and `.modkitignore`.

After every major milestone: run the full Wilds suite (bootstrap + release test set).

---

## 12. Docs & logging

- `docs/AI_DIALOGUES.md` — LM Studio setup, optional OpenAI/custom, troubleshooting, privacy (plaintext keys).
- `docs/AI_DIALOGUES_PLAN.md` — this plan (kept in repo).
- Logs: `[Wilds][AI] …` concise; never API keys / Authorization / full private config / full chats by default.
- README / USER_GUIDE short pointer when feature lands.

---

## 13. Compatibility lock

Do **not** regress:

- Gen1 RBY wilds, followers, catching, sprites, voxel, SpeciesAssets  
- Gen2 Gold generic paths  
- Battle-return, sandbox FS rules, release packaging  
- Ambient Pokémon / follower talk ownership  

AI remains an isolated optional subsystem. Default **OFF**.

---

## 14. Git / PR

- Branch: `cursor/ai-npc-dialogue-ce26`
- Base: `main`
- Commit plan first, then implement M1→M10 with commits + pushes
- Draft PR via ManagePullRequest

---

## 15. Manual steps (user / local only)

1. Install LM Studio.  
2. Download a small instruct model.  
3. Start local server on `http://127.0.0.1:1234/v1`.  
4. Enable **AI Dialogues** in Wilds settings; provider **Local**.  
5. Talk to the Pewter slice NPC (then other eligible NPCs).  
6. Optional: set OpenAI key in private secrets file for cloud provider.

Everything else in this plan is implemented and tested automatically in-repo.
