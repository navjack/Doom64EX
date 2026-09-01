# macOS port notes — Doom64EX

Builds and runs on Apple Silicon. Installed as `Doom64EX.app`. This is a 2016-era C++ source port
(SDL2 + **OpenGL 1.4 fixed-function**), not an N64Recomp project, so none of the rt64/Metal notes
apply here.

## Build

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DPNG_PNG_INCLUDE_DIR=/opt/homebrew/opt/libpng/include .
cmake --build build -j8
./tools/make_macos_app.sh
```

## Data files

Generated from your own ROM, into `~/Library/Application Support/doom64ex/`:

```bash
./build/doom64ex.app/Contents/MacOS/doom64ex -wadgen "/path/to/Doom 64 (U) [!].z64"
cp build/doom64ex.pk3 "$HOME/Library/Application Support/doom64ex/"
```

That directory ends up holding `doom64.wad`, `doomsnd.sf2`, `doom64ex.pk3` and `config.cfg`. The
pk3 lives there rather than in the bundle because `codesign` rejects non-Mach-O files in
`Contents/MacOS`, and the WAD has to be there anyway.

## Build fixes

**CMake policy** — the project declares `cmake_minimum_required` below 3.5, which modern CMake
refuses. Pass `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`.

**Bundled fluidsynth vs modern clang** — `fluidsynth/CMakeLists.txt` used `-Wall -Werror`, and
current clang errors on `-Wunused-but-set-variable` and
`-Wsingle-bit-bitfield-constant-conversion`. Dropped `-Werror` from that line. Note this must be
fixed *in fluidsynth's own CMakeLists*: passing `-Wno-error` via `CMAKE_C_FLAGS` does not work,
because the subproject appends `-Werror` afterwards.

**libpng header/library mismatch** — CMake found `png.h` in
`/Library/Frameworks/Mono.framework/Headers` while linking Homebrew's libpng 1.6.58.
`png_create_write_struct` returns NULL on a version-string mismatch, so **`-wadgen` failed** with
`Png_Create: Failed getting png_ptr` after decompressing every map. Fixed by pinning
`PNG_PNG_INCLUDE_DIR`.

## Source fixes

**`src/engine/wad/ZipWad.cc` — the important one.** `find()` sized its inflate output buffer from
the **LocalFileHeader**:

```cpp
String cache(header.uncompressed, 0);
zs.avail_out = header.uncompressed;
```

This pk3 is produced by `cmake -E tar --format=zip`, and libarchive writes entries with *data
descriptors* (general-purpose bit 3), which leave the local header's sizes as **0** — the real
sizes exist only in the central directory. So `avail_out` was 0, the inflate loop exited
immediately, and the guard that should have caught it (`avail_out != 0` -> "truncated") passed
because 0 == 0. **Every pk3 lump silently returned empty.**

Consequences: `MAPINFO` parsed to zero maps, so `P_GetMapInfo()` returned NULL for every map, and
`g_game.cc:914` responds by setting `gameaction = ga_title` — starting a new game bounced back to
the menu with nothing logged. `ANIMDEFS` and `SKYDEFS` were empty too, so the title logo map did
not load either.

Fixed by using `info.size`, which the reader already stores from the central directory, and adding
a direct-copy path for stored (non-deflated) entries, which would otherwise be fed to inflate.

**`src/engine/system/SdlVideo.cc` — HiDPI and window handling.**
- Added `SDL_WINDOW_ALLOW_HIGHDPI`. Without it macOS gives a 1x backing store and scales the
  window up, so on a 2x display a 1920x1080 window covers a whole 3840x2160 panel and a 3840x2160
  request needs a 7680x4320 backing store — offscreen and impossible to grab.
- Added `SDL_WINDOW_RESIZABLE` in windowed mode, plus a `SDL_WINDOWEVENT_SIZE_CHANGED` handler
  (there was none — only focus/enter/leave) that re-reads the drawable and persists the size.
- Viewport now uses `SDL_GL_GetDrawableSize()` (pixels) rather than `SDL_GetWindowSize()` (points).
- Windowed size is clamped to `SDL_GetDisplayUsableBounds`, so a stale 4K value can no longer
  strand the window offscreen.

`current_mode()` deliberately still reports **points**, because the Alt+Enter fullscreen toggle
does `mode = current_mode(); set_mode(mode)` — returning pixels there would recreate the window at
twice the requested size and reintroduce the bug.

**`src/engine/system/i_video.cc`** — `I_InitScreen` no longer overwrites `video_width`/`video_height`
with the logical mode size. `GL_CalcViewSize()` derives `ViewWidth` from `video_width`, so
assigning points there left the game rendering into the bottom-left quadrant of a double-sized
framebuffer. The video backend stores the drawable size; this now only falls back if unset.

## Design decision: render resolution scope

Windowed mode takes its render size from the window itself (the viewport follows the drawable), so
the configured resolution only bounds the *initial* window. The resolution setting is meaningful
for **exclusive fullscreen** only — borderless is the desktop size by definition, so a picker
there could not do anything.

## Not implemented: 1x/2x/4x supersampling

Would require offscreen render targets. The engine draws straight to the default framebuffer and
the bundled `glad` loader exposes **zero** framebuffer entry points, so this means extending the GL
loader, building an offscreen render path, and reworking the `glCopyTexSubImage2D` screen-wipe
effect that reads back from the framebuffer. A project, not a patch. Note that on a 2x display the
HiDPI fix already yields an effective 2x over logical points.

## On "why not Metal"

Apple's desktop OpenGL driver is itself implemented on top of Metal, so these GL calls already
reach the GPU through Metal; the cost is the deprecated GL front-end. A real Metal port would mean
rewriting the renderer — `dgl.h` is a large wrapper over immediate-mode `glBegin`/`glEnd`-era GL
1.4, which has no mechanical translation to Metal.

## Other notes

**Dual SDL2.** Upstream links the executable against `/Library/Frameworks/SDL2.framework` while
Homebrew's `libSDL2_net` pulls in sdl2-compat, so two different SDL2s were loaded into one process.
`tools/make_macos_app.sh` retargets the executable onto sdl2-compat and vendors a single SDL2.

**Gtk3 warning.** `Gtk3: Could not load libDoom64EX-gtk3.so` at startup is expected on macOS and
harmless — that is the Linux native-UI plugin.
