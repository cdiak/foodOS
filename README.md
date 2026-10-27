# foodOS

**⌥⇧F — say what you ate, anywhere on your Mac. Get a meal entry in your Obsidian calorie counter.**

Press **⌥⇧F** and describe a meal. Press **⌥⇧F** again. foodOS transcribes your words on-device with [whisper.cpp](https://github.com/ggml-org/whisper.cpp). It then hands the transcript to [Claude Code](https://claude.com/claude-code) (`claude -p`). The agent estimates each item and returns JSON. foodOS sums the totals and writes one note per meal into the Obsidian vault you choose.

```
⌥⇧F  →  ● record  →  ⌥⇧F  →  … transcribe  →  ◍ estimate  →  <vault>/Nutrition/Meals/2026-10-27 0821 Eggs and toast.md
```

A [Bases](https://help.obsidian.md/bases) file turns those notes into a calorie counter: today's totals, totals against your targets, the last 7 days, and every meal grouped by day.

foodOS is the fourth sibling of [noteOS](https://github.com/cdiak/noteOS) (⌥⇧N), [everywhisper](https://github.com/cdiak/everywhisper) (⌥⇧W), and [optionai](https://github.com/cdiak/optionai) (⌥A+I). Same skeleton: one Swift file, a menu-bar item, a LaunchAgent.

## Install from a prompt

Copy everything inside the block below and paste it into a coding agent (Claude Code, Cursor, Codex, …). It should ask you which vault to use, install dependencies, fetch a model, build foodOS, and start the login agent — no manual GitHub steps.

```text
Set up foodOS: a system-wide voice calorie counter (Option+Shift+F) that writes meal notes into an Obsidian vault on this Mac. Do every step yourself in the shell; do not tell me what to run. Stay on macOS only.

Repo: https://github.com/cdiak/foodOS
Source dir: ~/.local/src/foodOS unless I name another folder (create parent dirs if needed). It only holds the source to build from; install.sh copies everything it runs into ~/.local.
Model path: ~/.cache/whisper/ggml-base.en.bin (unless a model already exists)
Binary: ~/.local/bin/foodos
Config: ~/.config/foodos/config
LaunchAgent label: com.cdiak.foodos

Steps:
1. Prerequisites
   - Confirm macOS (uname -s is Darwin). If not, stop and say foodOS is macOS-only.
   - Ensure Xcode Command Line Tools (swiftc) are available. If missing, run xcode-select --install and wait / guide only if the GUI installer blocks non-interactive completion.
   - Ensure Homebrew is available (brew). If missing, install from https://brew.sh or report that brew is required.
   - Ensure the Claude Code CLI (claude) is available. If missing, install it with: curl -fsSL https://claude.ai/install.sh | bash
   - Check auth: if `claude -p "say ok"` fails with an auth error, tell me to run `claude` once and log in, then continue.
2. Choose the vault (ask me — this is the one question you must ask)
   - List my Obsidian vaults that still exist on disk:
       python3 -c 'import json,os; [print(v["path"]) for v in json.load(open(os.path.expanduser("~/Library/Application Support/obsidian/obsidian.json")))["vaults"].values() if os.path.isdir(v["path"])]'
   - Show me the list and ask which vault foodOS should write to, and which folder inside it (default: Nutrition). Nested folders like "Health/Nutrition" are fine.
   - If ~/.config/foodos/config already exists, show its FOODOS_VAULT and FOODOS_FOLDER and offer to keep them.
   - Set FOODOS_VAULT to the absolute vault path and FOODOS_FOLDER to the folder.
3. Clone
   - Call the source dir SRC.
   - If SRC is already a git clone of this repo, git pull --ff-only origin main (or the default branch).
   - If SRC exists but is not this repo, move it to SRC.bak.<timestamp>.
   - Otherwise: git clone https://github.com/cdiak/foodOS.git SRC
4. whisper-cli
   - If whisper-cli is not on PATH, brew install whisper-cpp.
   - Resolve WHISPER_CLI to the full path of whisper-cli (command -v whisper-cli or $(brew --prefix)/bin/whisper-cli).
5. Model (do not skip; foodOS does not ship weights)
   - If a Whisper model already exists on this Mac, reuse it and set WHISPER_MODEL to it. Look with: find ~ -maxdepth 6 -name 'ggml-*.bin' -size +50M 2>/dev/null
   - Otherwise: mkdir -p ~/.cache/whisper and download with:
       curl -fL --retry 3 -o ~/.cache/whisper/ggml-base.en.bin \
         "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
   - Verify the file exists and is a normal size (~142MB for base.en).
6. Install
   - cd SRC
   - FOODOS_VAULT="<vault>" FOODOS_FOLDER="<folder>" WHISPER_CLI="<path>" WHISPER_MODEL="<path>" ./install.sh
   - install.sh creates <vault>/<folder>/Meals, plus "Calorie Counter.base" and "Food profile.md" if they do not exist. It never overwrites them.
7. Verify
   - Confirm ~/.local/bin/foodos exists and is executable.
   - Confirm the LaunchAgent is loaded: launchctl print "gui/$(id -u)/com.cdiak.foodos" shows running / path.
   - tail ~/Library/Logs/foodos.log and confirm a "foodos ready" line that shows my vault.
   - Run a test without the mic: ~/.local/bin/foodos --log "a banana and a cup of black coffee"
     Confirm a new note appears in <vault>/<folder>/Meals with calories in its frontmatter. Then delete that test note.
8. Permissions (cannot fully automate TCC — be explicit)
   - Tell me I must allow Microphone for foodos the first time I press Option+Shift+F, or enable it in:
       System Settings → Privacy & Security → Microphone
   - No Accessibility grant is needed. foodOS never pastes or taps keys.
   - If foodos is missing from the Microphone list, run ~/.local/bin/foodos once from the terminal to trigger registration, then:
       launchctl kickstart -k "gui/$(id -u)/com.cdiak.foodos"
9. Report when done
   - clone path, vault + folder, whisper-cli path, model path + size, binary path, whether the agent is running, the test meal's calories, and the hotkey (Option+Shift+F).
   - Remind me: open "<folder>/Calorie Counter.base" in Obsidian, and fill in "<folder>/Food profile.md" (about me, targets, usual foods). If I change a target, the matching number in the base's "Today vs targets" summaries must change too.

If any step fails, diagnose and fix before reporting done. Prefer fixing brew/path/model/download issues over asking me to run commands.
```

After the agent finishes, allow **Microphone** when asked, then press **⌥⇧F** and say what you ate.

### What the prompt does

| Step | Result |
|------|--------|
| Vault question | you pick the vault and folder; saved in `~/.config/foodos/config` |
| Clone / pull | `~/.local/src/foodOS` (or your folder) at latest `main` |
| `brew install whisper-cpp` | `whisper-cli` on PATH |
| `curl` model | `~/.cache/whisper/ggml-base.en.bin` (~142 MB, English), or reuses one you have |
| `./install.sh` | builds `~/.local/bin/foodos`, seeds the vault folder, registers login LaunchAgent |
| Test log | one meal logged from text, then removed |
| Permissions note | you still allow the Microphone (macOS requirement) |

---

## Requirements

| Need | Notes |
|------|-------|
| macOS | Apple Silicon or Intel |
| [Xcode Command Line Tools](https://developer.apple.com/xcode/) | for `swiftc` (build once) |
| [`whisper-cli`](https://github.com/ggml-org/whisper.cpp) | `brew install whisper-cpp` |
| A GGML Whisper model (`.bin`) | not included — see the prompt above |
| [Claude Code CLI](https://claude.com/claude-code) | `claude` on PATH, logged in |
| [Obsidian](https://obsidian.md) 1.9 or later | for Bases |

**Permissions:** Microphone only.

## Install by hand

```bash
git clone https://github.com/cdiak/foodOS.git
cd foodOS
FOODOS_VAULT="$HOME/Notes" FOODOS_FOLDER="Nutrition" ./install.sh
```

Clone it anywhere. The clone is only build source; `install.sh` copies the binary and assets into `~/.local`, so you can delete the clone afterward. Run `./install.sh` with no `FOODOS_VAULT` to list your Obsidian vaults. Re-running it later reuses the saved vault. To move foodOS to another vault, run it again with a new `FOODOS_VAULT`.

## The vault side

| File | Job |
| --- | --- |
| `<folder>/Meals/` | One note per meal. Frontmatter holds the totals. The body holds an item table, the assumptions, and what you said. |
| `<folder>/Calorie Counter.base` | Views: Today, Today vs targets, Last 7 days, All meals, Pending. |
| `<folder>/Food profile.md` | About you, your targets, usual foods, and portion habits. The agent reads it on every meal. |

Each meal note carries these properties: `date`, `time`, `meal` (breakfast, lunch, dinner, snack, drink), `calories`, `protein_g`, `carbs_g`, `fat_g`, `fiber_g`, `sugar_g`, `sat_fat_g`, `sodium_mg`, `confidence`, and `status`.

The base's target summaries start at the FDA Daily Values for a 2,000 kcal diet. Change them in the base's `summaries:` block to match your profile.

## Rules

- **The agent estimates. Swift adds.** Totals are always the exact sum of the item rows.
- **No data loss.** A pending note with the raw transcript is written before the agent runs. If the agent fails, the note stays and shows in the "Pending" view.
- **One dictation can hold several meals.** "Last night I had X, and this morning Y" makes two notes with the right dates.
- **Your profile wins.** Say "my coffee" and foodOS uses your profile's row for it, exactly.

## Use

1. Press **⌥⇧F**. Speak: "For lunch I had a turkey sandwich on rye and a medium apple."
2. Press **⌥⇧F** again. A Glass sound means the meal is logged. Basso means it failed. Check the log.
3. Press **⌥⇧F** during **◍** to cancel. The pending note stays.

To fix a meal, edit its note. To teach foodOS a food, add a row to the food profile.

Test without the mic:

```bash
~/.local/bin/foodos --log "two scrambled eggs and toast for breakfast"
```

## Configuration

`install.sh` writes `~/.config/foodos/config` as `KEY=VALUE` lines. Edit it and run `launchctl kickstart -k "gui/$(id -u)/com.cdiak.foodos"`, or re-run `./install.sh`. Environment variables override the file.

| Variable | Default | Meaning |
|----------|---------|---------|
| `FOODOS_VAULT` | none — required | Obsidian vault root |
| `FOODOS_FOLDER` | `Nutrition` | folder inside the vault for meals, the base, and the profile |
| `FOODOS_MODEL` | `sonnet` | model passed to `claude --model` |
| `FOODOS_TIMEOUT` | `120` | agent timeout, seconds |
| `WHISPER_CLI` | auto-detected | path to `whisper-cli` |
| `WHISPER_MODEL` | auto-detected | path to a GGML model |

Log: `~/Library/Logs/foodos.log`. Uninstall: `./uninstall.sh` (your meal notes stay).

## Caveats

Estimates come from a language model, not a lab. They are close for common foods and stated portions, and rougher for restaurant meals and vague descriptions. Each note's `confidence` and assumptions tell you which is which. This is a logging tool, not medical advice.

## License

MIT — see [LICENSE](LICENSE).
