# Token Usage Review and Recommendations

Reviewed: the Claude Code sessions stored for this project folder (`C:\Users\ladmin\.claude\projects\c--Code-aPePAS\`), 2026-09-02 to 2026-09-25.
Companion file: [Token-Usage-Prompts.md](Token-Usage-Prompts.md). It has copy-paste prompts for the recommendations below.

---

## 1. What the sessions show

| Session | Dates / focus | User prompts | API calls | Avg context per call | Peak context | Input tokens read (cache) |
|---|---|---|---|---|---|---|
| ed1c42dc | aPePAS phases 0–2, Test Connectivity, platforms | 56 | 2,189 | ~499K | 967K | ~1.09 B |
| 6b67641b | **aPeDiscovery** (run from the aPePAS folder) | 49 | 1,070 | ~501K | 946K | ~0.53 B |
| 11b68129 | aPePAS automation, aPeSecrets, K-items, SaaS tests | 92 | 2,363 | ~503K | 967K | ~1.18 B |
| **Total** | | **197** | **5,622** | **~500K** | | **~2.8 B** |

The number that matters most: **every API call re-sent about 500,000 tokens of conversation history**. On average, one tool call (a grep, one edit, a `git status`) carried half a million tokens of earlier context. Output tokens were only ~4.2 M in total. Almost all of the usage is the model re-reading history.

Other findings:

- **Sessions ran until auto-compaction.** Context grew to ~950K+ tokens, compacted (6 times in each large session), and then grew again. The sessions were never cleared between unrelated tasks.
- **Simulation:** I replayed the sessions as though each user prompt had started with a fresh context (~50K baseline). Input tokens dropped from ~2.8 B to ~0.58 B, about **80% less**. That number is an upper bound, because a fresh session has to re-read some files. A realistic saving is **50–70%**.
- **Short follow-ups at a huge context were expensive.** In session 11b68129, 27 prompts such as "Commit and push", "Yes" and "Status?" consumed ~164 M tokens, because each one ran on top of ~500K of history.
- **Two docs are huge and are read constantly:**
  - `Docs/Testing-Plan.md` is 311 KB (~78K tokens). Its "Findings and Fixes" section is 135 KB and its Revision Log is 61 KB. It was read 145 times.
  - `Docs/Documentation-Tracker.md` is 269 KB (~67K tokens). **264 KB of that is the Revision Log.** It was read 48 times.
  - Some lines in these files are up to 5,500 characters long, so a 15-line `Read` or a `grep` returned 15–50 KB.
- **The same files were read many times:** `Manage-Privilege.ps1` 162×, `Testing-Plan.md` 145×, `Design-Local-Linux-Discovery.md` 112×. About half of all Reads came right after an edit to the same file.
- **The project has no `CLAUDE.md`,** so each new session starts by exploring to find out the layout, test commands and documentation rules.
- **aPeDiscovery work ran inside the aPePAS project.** That session loaded aPePAS memory and context, and its transcript is stored under the aPePAS project.
- Test output (Pester) was **not** a problem: ~240 runs per session, averaging ~1 KB each.

---

## 2. Recommendations (ordered by impact)

### R1. Start a fresh context for each task (`/clear`). Highest impact, est. 50–70%.

**Instructions**
1. Treat one feature, bug or K-item as one session.
2. When the task is finished and committed, run `/clear` (or open a new Claude Code conversation) before starting the next unrelated task.
3. If you need a thread from earlier work, use the handoff prompt (Prompts file, P3) before clearing and the resume prompt (P4) after.
4. When you want to keep going on the same topic but the context is large, run `/compact` with a focus instruction instead of letting auto-compaction trigger at ~950K.

**Why:** Every call re-sends the whole conversation. At 500K average context, a 10-call task costs ~5 M input tokens. The same task in a fresh ~50–100K session costs ~0.5–1 M. The work from earlier tasks is already in git and the docs. The model doesn't need the conversation history to use it.

### R2. Put follow-up actions in the task prompt. Est. ~150 M tokens per long session.

**Instructions:** End your task prompts with the full definition of done. For example: *"…then run the unit tests, update Testing-Plan/Documentation-Tracker, commit and push."* Avoid sending "Commit and push" as a separate message at a large context. If you do send it separately, send it right before `/clear`, not after more work has piled up.

**Why:** Each extra round-trip re-sends the full history. In session 11b68129, 27 of these short messages cost ~164 M tokens. Put in the original prompt, the same steps cost almost nothing extra.

### R3. Move the revision logs and closed findings out of the working docs. Est. ~100K+ tokens per full doc read.

**Instructions** (prompt P2 does this):
1. Move `Documentation-Tracker.md` → `## Revision Log` (264 KB) into `Docs/Archive/Documentation-Tracker-Revision-Log.md`. Keep only the last ~10 entries in the main file.
2. Move `Testing-Plan.md` → `## Revision Log` (61 KB) into `Docs/Archive/Testing-Plan-Revision-Log.md` in the same way.
3. Move **closed** items from `Testing-Plan.md` → `## Findings and Fixes` (135 KB) into `Docs/Archive/Findings-Closed.md`. Leave a one-line index row for each ID (e.g. `| F29 | Fixed 2026-09-10 | see Archive |`), so references still resolve.
4. Going forward, keep table rows short. Put a one-line summary in the table and details under a heading, or use git commit messages for the long explanations.

**Why:** These two files make up ~145K tokens and were read nearly 200 times. Every read, and even every `grep` (because lines are up to 5,500 characters), puts tens of thousands of tokens into the context, and they stay there for the rest of the session. The revision logs also duplicate `git log`. After this change, the active parts of both files should be under ~25K tokens combined.

### R4. Add a short `CLAUDE.md` to each project. Saves the exploration at the start of every session.

**Instructions:** Use prompt P1 to create `C:\Code\aPePAS\CLAUDE.md` (and one for aPeDiscovery and aPeSecrets). Keep it **under ~80 lines** with:
- a folder map (where modules, tests and docs live)
- the exact commands to run the unit tests
- a "which docs to update for which kind of change" checklist
- pointers to rules that already exist (Architecture.md menu ordering, error-message format, etc.). Point to them rather than copying them.

**Why:** Without it, each new session greps and reads to rediscover the same facts, and the "Verify documentation has been updated" requests make the model re-read every doc to decide what needs changing. `CLAUDE.md` is loaded on **every** call, so keep it short. A 3K-token file that saves 30K+ of exploration per session pays for itself quickly. A 30K-token one would cost more than it saves.

### R5. Open each project in its own folder.

**Instructions:** For aPeDiscovery or aPeSecrets work, open `C:\Code\aPeDiscovery` (or `aPeSecrets`) as the VS Code workspace before you start Claude Code. Don't start that work from the aPePAS window.

**Why:** Session 6b67641b (0.53 B tokens) was aPeDiscovery work running in the aPePAS project. It loaded aPePAS memory and git status, which were irrelevant, and it gets no benefit from an aPeDiscovery-specific `CLAUDE.md` or memory. Per-project sessions also keep each context focused on one codebase.

### R6. Give subagents the broad review and search requests.

**Instructions:** For requests like "Verify all documentation has been updated", "What are the outstanding issues?" or "Review the project", ask for a subagent explicitly (prompt P5). Where the job is mechanical, you can also ask for a smaller model. The Agent tool in this session accepts a `model` option (`haiku`, `sonnet`, `opus`), and there is a read-only `Explore` agent type.

**Why:** A subagent reads the big files in **its own** context and returns only a short summary. Only that summary joins your main conversation, so the main session doesn't grow by 100K+ tokens of file dumps that every later call would re-send.

### R7. Point the model at exact locations when you know them.

**Instructions:** When you know where the change goes, name the file and function (e.g. *"In `Manage-Privilege.ps1`, function `Invoke-ActionModule`…"*) or the finding ID. For large files, ask for a targeted read (prompt P6 includes this).

**Why:** `Manage-Privilege.ps1` is 3,742 lines (~46K tokens) and was read 162 times. A precise pointer lets the model grep and read ~50 lines instead of scanning the file. In the longer term, splitting `Manage-Privilege.ps1` into smaller modules (for example, profile management, menus and automation) would reduce this further. That's an architecture decision for you to make, and I haven't assessed it here.

### R8. Keep secrets out of the chat. (Security, not tokens.)

**Instructions:** Several prompts contained passwords (lab, test and admin accounts). Rotate those credentials. Next time, put test credentials in an environment variable, the Windows Credential Manager, or your CyberArk CP/CCP (which aPeSecrets already supports), and tell Claude the name of the variable or object instead of the value.

**Why:** Session transcripts are stored in plain text under `C:\Users\ladmin\.claude\projects\`, and whatever you paste stays in the context for the rest of the session.

---

## 3. Suggested per-task workflow

1. Open the correct project folder → start Claude Code (a fresh session).
2. Send one task prompt with the scope and the definition of done (P6).
3. Let it finish, including tests, docs, commit and push.
4. If there's unfinished work, run the handoff prompt (P3).
5. `/clear` → next task. Use P4 to resume from the handoff if needed.

## 4. How to measure improvement

After a week, ask Claude to re-run this analysis (prompt P7) and compare the **average context per call** against the ~500K baseline above. A good target is **under 150K**.

## 5. Things to check yourself

- `/clear`, `/compact`, `/model` and `/resume` are standard Claude Code commands. Run `/help` in your build to confirm them, and to see whether a `/context` command (context-usage breakdown) is available.
- I didn't change any Claude Code settings (for example, auto-compaction thresholds). I haven't verified which settings your version supports. If you want to go further, ask the `claude-code-guide` agent before editing `settings.json`.
