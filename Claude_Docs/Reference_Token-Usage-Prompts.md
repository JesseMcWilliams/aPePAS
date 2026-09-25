# Token-Saving Prompts

These are copy-paste prompts for the recommendations in [Planning_Token-Usage-Recommendations.md](Planning_Token-Usage-Recommendations.md). Each one says when to use it and why it helps.

---

## P1 — Create a lean CLAUDE.md (R4, one-time per project)

**Use:** once in aPePAS, once in aPeDiscovery, once in aPeSecrets. Start a fresh session in each project folder.

```
Create a CLAUDE.md at the project root. Hard limit: 80 lines. Include only:
1. A folder map (one line per top-level folder: what lives there).
2. The exact commands to run the unit tests (all, and a single test file), and how to read a pass/fail summary.
3. A "change type -> docs to update" checklist (e.g. new module -> User-Guide, Architecture, Testing-Plan Component Test Matrix, Documentation-Tracker).
4. Pointers (file + section name) to existing conventions. Don't copy their content.
5. Branch/commit/PR conventions used in this repo.
Do not include history, finding details, or anything already derivable from git log.
Show me the draft before writing it.
```

**Why:** Each new session gets the project layout, test commands and doc rules without exploring for them. The line limit matters because CLAUDE.md is re-sent on every call.

---

## P2 — Archive revision logs and closed findings (R3, one-time)

**Use:** in a fresh aPePAS session, on its own branch.

```
Reduce the size of Claude_Docs/Testing_Plan.md and Claude_Docs/Archive_Planning_Documentation-Tracker.md without losing information:
1. Move the "## Revision Log" section of each file into Docs/Archive/<FileName>-Revision-Log.md. Keep only the 10 most recent entries in the original, plus a link to the archive.
2. In Testing_Plan.md "## Findings and Fixes", move every CLOSED/FIXED finding's full detail into Docs/Archive/Findings-Closed.md. In the original, leave a one-line index row per ID (ID | status | date | link) so references like F29 still resolve. Keep open findings and the Known Issues / Risk Register in place.
3. Don't reword any content. This is a move, not a rewrite.
4. Report the before/after size of each file. Then commit on a new branch.
Use a script to do the moves rather than reading the whole files into context.
```

**Why:** These two files are ~145K tokens and were read ~200 times. The last line of the prompt keeps this one-time job from filling its own context with the files it's moving.

---

## P3 — Handoff before /clear (R1)

**Use:** at the end of a task when something is still unfinished, just before you run `/clear`.

```
Before I clear context: write a handoff note to the scratchpad file SESSION-HANDOFF.md (overwrite it) with at most 25 lines:
- branch name and last commit hash
- what was completed
- what is unfinished, with the exact next step
- files and functions involved (paths + function names)
- any test commands or live-test details I'd need (no passwords)
Then tell me the file path.
```

**Why:** The next session gets the ~25 lines it actually needs instead of 500K tokens of conversation.

> Note: the scratchpad folder is session-specific. If you want the note to survive between sessions, change "the scratchpad file" to a fixed path, e.g. `C:\Code\aPePAS\.handoff\SESSION-HANDOFF.md`, and add `.handoff/` to `.gitignore`.

---

## P4 — Resume from handoff (R1)

**Use:** as the first message of a new session that continues earlier work.

```
Read <path to SESSION-HANDOFF.md> and continue from "next step". Only read the files it lists unless you need more.
```

**Why:** The model starts from a small, precise brief and doesn't have to re-explore the repo.

---

## P5 — Delegated verification and review (R6)

**Use:** instead of "Verify documentation has been updated", "What are the outstanding issues?" or "Review the project".

```
Use a subagent (Explore agent, or model haiku if the check is mechanical) to verify documentation against the changes on this branch (git diff main...HEAD). It should check each doc named in the CLAUDE.md checklist and return ONLY a list of: doc, section, what's missing. Keep file contents out of this conversation. Then fix the gaps it reports.
```

Variant for outstanding items:

```
Use an Explore subagent to list open items from Claude_Docs/Testing_Plan.md (Known Issues / open Findings) and Docs/Open-Items if present. Return ID, one-line summary, and priority only.
```

**Why:** The large files are read in the subagent's context. Your main session gets back a short list instead of 100K+ tokens of documents that every later call would re-send.

---

## P6 — Scoped task template (R2, R7)

**Use:** as the standard shape for any new task.

```
Task: <what to change>
Where: <file(s) and function(s), or finding/K ID, if known>
Constraints: <e.g., must work on Self-Hosted and ISPSS; use Get-CpmOptions>
Done when: unit tests pass (<test file>), docs per CLAUDE.md checklist are updated, changes are committed and pushed to <branch>.
Read large files (Manage-Privilege.ps1, Testing_Plan.md) with grep + targeted line ranges, not whole-file reads.
```

**Why:** Pointing at exact locations avoids scanning 3,700-line files. Putting "done when" in the same prompt saves the separate "commit and push" round-trips that cost ~164 M tokens in one session.

---

## P7 — Re-measure usage (Section 4 of recommendations)

**Use:** after a week or two of the new workflow.

```
Analyze my Claude Code session transcripts in C:\Users\ladmin\.claude\projects\c--Code-aPePAS\ (and the aPeDiscovery/aPeSecrets project folders if they exist) that are newer than 2026-09-25. For each session report: user prompts, API calls, average and peak context per call, and total cache-read tokens. Compare against the baseline in Planning_Token-Usage-Recommendations.md (avg ~500K/call). Use a script. Don't read the transcripts directly.
```

**Why:** It confirms whether the changes worked. The instruction to use a script matters because the transcripts are 13–27 MB each.

---

## P8 — Focused compaction (R1, when you can't clear)

**Use:** when you're mid-task and the context is large, but you need to keep going on the same topic. Type it as a slash command:

```
/compact Keep only: current branch, the task in progress, files/functions being changed, failing tests and their errors, and decisions I've made this session. Drop earlier completed tasks.
```

**Why:** A manual compaction with a focus keeps what matters and shrinks the context well before auto-compaction would trigger near ~950K. (Check with `/help` that your build's `/compact` accepts focus text.)
