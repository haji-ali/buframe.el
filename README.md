# buframe.el - Buffer-local frames for Emacs

Buframe provides utilities for creating and managing lightweight child frames
associated with individual buffers. These frames are meant for inline previews,
annotations, completions, or other UI elements that should not interfere with
normal Emacs focus or window behaviour.

## Features

- Buffer-local child frames
- Minimal appearance (no mode-line, tool-bar, tab-bar, etc.)
- Non-focusable, non-disruptive
- Dynamically positioned relative to buffer content (e.g. overlays, regions)
- Automatic update and hide/show depending on buffer selection
- Debounced frame updates to avoid flicker
- Dedicated buffers configured for preview-only use

## Installation

```emacs-lisp
(use-package buframe
:straight (buframe :type git :host github :repo "haji-ali/buframe"))
```

Or manually clone and place in your `load-path`.

## Usage

Example creating a child frame next to an overlay:

```
(let ((ov (make-overlay (point) (1+ (point)))))
    (buframe-make "preview"
        (lambda (frame) (buframe-position-right-of-overlay frame ov))
        (buframe-make-buffer "preview")))
```

Frames will automatically update/hide as the buffer is selected/deselected.

## Comparison with posframe

`buframe` was inspired by [corfu](https://github.com/minad/corfu)'s frames,
which were in turn inspired by posframes. The main difference lies in the
scope and the buffer integration. Buframes are auto-updated/hidden on buffer
selection.

Buframe is better suited when frames need to *track* and *belong* to a buffer
(e.g. inline annotations or previews). Posframe is simpler when you just want
to display a popup at point.
