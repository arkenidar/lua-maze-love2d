# LÖVE Maze

A small tile-based maze game built with [LÖVE](https://love2d.org/) (Lua).
Move the player to the exit to advance through a series of levels.

---

## Requirements

- [LÖVE](https://love2d.org/) 11.x (tested with 11.5)

No other dependencies are needed — the game only uses LÖVE's built-in modules.

---

## Running the game

From the project folder:

```sh
love .
```

Or point LÖVE at the project path directly:

```sh
love /path/to/lua-maze-love2d
```

On Android/iOS the game automatically runs fullscreen (see `conf.lua`).

---

## How to play

Reach the **exit** tile to advance to the next level. After the last level
the game loops back to level 1 and shows a "You win!" message.

### Controls

| Input                          | Action                |
| ------------------------------ | --------------------- |
| Mouse click / touch (tap)      | Move to an adjacent tile |
| `←` `→` `↑` `↓` (arrow keys)  | Move one tile         |
| `Esc`                          | Quit the game         |

You can only move onto adjacent (non-diagonal), non-wall tiles.

---

## Project layout

```
.
├── .vscode/              # VS Code run/debug configuration
│   ├── launch.json       #   F5 → "moonbug: Launch LÖVE"
│   ├── tasks.json        #   "love: run", "love: run (Moonbug)", "love: run (MobDebug)" tasks
│   └── extensions.json   #   recommended debugger extension
├── assets/
│   ├── map01.txt         # level 1
│   ├── map02.txt         # level 2
│   ├── map03.txt         # level 3
│   ├── P.bmp             # player tile
│   ├── -.bmp             # floor tile
│   ├── W.bmp             # wall tile
│   └── E.bmp             # exit tile
├── conf.lua              # LÖVE window configuration
├── main.lua              # game logic
├── moonbug.lua           # moonbug DAP debugger (single-file, in-process)
└── mobdebug.lua          # MobDebug remote debugger (for ZeroBrane Studio etc.)
```

---

## For developers

### How it works

All game logic lives in `main.lua`:

- `load_map(file)` — reads an ASCII map and builds the `grid` table,
  recording the player start from the `P` character.
- `try_move(tx, ty)` — shared movement logic used by both mouse and keyboard.
  Rejects non-adjacent tiles and walls; stepping onto `E` calls `next_map()`.
- `next_map()` — advances `map_current`, loading the next map file. When past
  the last map it resets to level 1 and shows the "You win!" message box.
- `love.load()` — loads the tile images, sets `tile_size` (64 px), and starts
  the first map.
- `love.draw()` — draws the grid, scaling each 32×32 tile image to `tile_size`.
- `love.update()` — handles mouse/touch movement.
- `love.keypressed(key)` — handles `Esc` (quit) and the arrow keys.

### Map format

Maps are plain text files in `assets/`. Each character is one tile:

| Char | Meaning        |
| ---- | -------------- |
| `#`  | Wall           |
| ` `  | Floor (empty)  |
| `P`  | Player start   |
| `E`  | Exit           |

Rows are the lines of the file; columns are the character positions.
Example:

```
P##   #
  # E #
# #   #
```

### Adding a new level

1. Create `assets/mapNN.txt` (e.g. `assets/map04.txt`) with a `P` and an `E`.
2. Register it in `main.lua`, in `love.load()`:

   ```lua
   map={"01","02","03","04"}
   ```

Levels are played in the order listed in `map`, then loop back to the first.

### Debugging in VS Code

The recommended setup uses the
[moonbug](https://marketplace.visualstudio.com/items?itemName=atomicptr.vscode-moonbug)
extension (it will be suggested by `.vscode/extensions.json`).

1. Install the extension.
2. Set breakpoints in `main.lua`.
3. **Run and Debug** → **"moonbug: Launch LÖVE"** → **F5**.

The launch configuration runs LÖVE with the `-moonbug` flag, which makes
`main.lua` start moonbug and wait for the debugger to attach — no other code
changes are needed:

```json
{
    "type": "moonbug",
    "request": "launch",
    "lua": "love",
    "program": "${workspaceFolder}",
    "args": ["-moonbug"],
    "host": "127.0.0.1",
    "port": 8888,
    "project_root_dir": "${workspaceFolder}"
}
```

If you prefer to start the game yourself, use the **"moonbug: Attach to LÖVE"**
configuration: run the game first (e.g. with the `love: run (Moonbug)` task),
then press **F5** to connect to moonbug on port `8888`.

> **Tip:** `love.update()` and `love.draw()` run every frame, so a breakpoint
> there stops constantly and the window appears frozen. Prefer breakpoints in
> event-driven code (`love.keypressed`, `try_move`, `next_map`, `love.load`),
> or use a conditional breakpoint.

### Debugging with moonbug (standalone)

The project ships `moonbug.lua`, the single-file DAP-powered Lua debugger.
Launch the game with the `-moonbug` flag:

```sh
love . -moonbug
```

This starts the moonbug DAP server (`main.lua` calls
`require("moonbug").listen(nil, nil, { wait = true })`) and blocks until a
DAP client attaches on `127.0.0.1:8888`. Any DAP client can connect — the
official VS Code extension (see above), `nvim-dap`, or Zed:

```lua
-- nvim-dap example
dap.adapters.moonbug = { id = "moonbug", type = "server", port = 8888 }
```

You can run this via the **`love: run (Moonbug)`** VS Code task as well.

### Debugging with MobDebug / ZeroBrane Studio

The project also ships `mobdebug.lua`. Launch the game with the `-debug` flag:

```sh
love . -debug
```

This starts the MobDebug server (`main.lua` calls `require("mobdebug").start()`),
allowing ZeroBrane Studio or another MobDebug-compatible client to attach.
You can run this via the **`love: run (MobDebug)`** VS Code task as well.

### Running VS Code tasks

- `Ctrl+Shift+B` (or *Terminal → Run Task → `love: run`*) — run the game normally.
- *Terminal → Run Task → `love: run (Moonbug)`* — run with moonbug enabled.
- *Terminal → Run Task → `love: run (MobDebug)`* — run with MobDebug enabled.
