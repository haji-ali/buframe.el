;;; buframe.el --- Buffer-local frames  -*- lexical-binding:t -*-

;; Copyright (C) 2025 Free Software Foundation, Inc.

;; Author: Al Haji-Ali <abdo.haji.ali@gmail.com>
;; URL: https://github.com/haji-ali/buframe
;; Version: 0.2
;; Package-Requires: ((emacs "27.1") (timeout "2.1"))
;; Keywords: buffer, frames, convenience
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Buframe provides utilities to create, manage, and update local child
;; frames, associated with a single buffer, for previews or inline overlays.
;; By default, these child frames are:
;; - Minimal (no mode-line, tool-bar, tab-bar, etc.)
;; - Non-focusable, non-disruptive, and dedicated to a buffer
;; - Dynamically positioned relative to overlays or buffer positions
;; - Automatically updated or hidden depending on buffer selection
;;
;; This package is designed to support UI components like popup
;; previews, completions, or inline annotations, without interfering
;; with normal Emacs windows or focus behaviour

;;; Code:

(require 'cl-lib)
(require 'timeout)

(defvar buframe--default-buf-parameters
  '((mode-line-format . nil)
    (header-line-format . nil)
    (tab-line-format . nil)
    (tab-bar-format . nil) ;; Emacs 28 tab-bar-format
    (frame-title-format . "")
    (truncate-lines . t)
    (cursor-in-non-selected-windows . nil)
    (cursor-type . nil)
    (show-trailing-whitespace . nil)
    (display-line-numbers . nil)
    (left-fringe-width . nil)
    (right-fringe-width . nil)
    (left-margin-width . 0)
    (right-margin-width . 0)
    (fringes-outside-margins . 0)
    (fringe-indicator-alist . nil)
    (indicate-empty-lines . nil)
    (indicate-buffer-boundaries . nil)
    (buffer-read-only . t))
  "Default child frame buffer parameters for preview frames.")

(defvar buframe--default-parameters
  '((no-accept-focus . t)
    (no-focus-on-map . t)
    (min-width . t)
    (min-height . t)
    (border-width . 0)
    (outer-border-width . 0)
    (internal-border-width . 1)
    (child-frame-border-width . 1)
    (left-fringe . 0)
    (right-fringe . 0)
    (vertical-scroll-bars . nil)
    (horizontal-scroll-bars . nil)
    (menu-bar-lines . 0)
    (tool-bar-lines . 0)
    (tab-bar-lines . 0)
    (no-other-frame . t)
    (unsplittable . t)
    (undecorated . t)
    (cursor-type . nil)
    (no-special-glyphs . t)
    (desktop-dont-save . t))
  "Default child frame parameters for preview frames.")

(defvar buframe-update-debounce-delay 0.5
  "Delay in seconds before debounced frame update functions run.")

(defvar buframe--frame-mouse-ignore-map
  (let ((map (make-sparse-keymap)))
    (dotimes (i 7)
      (dolist (k '(mouse down-mouse drag-mouse double-mouse triple-mouse))
        (define-key map (kbd (format "<%s-%s>" k (1+ i))) #'ignore)))
    (when (boundp 'mouse-wheel--installed-bindings-alist)
      (pcase-dolist
          (`(,key . ,fun) mouse-wheel--installed-bindings-alist)
        ;; TODO.
        ;; (define-key map key #'buframe--forward-event)
        (define-key map key #'ignore)))
    map)
  "Ignore all mouse clicks.")

(defun buframe--region-bbox (start end window)
  "Smallest frame-pixel bbox of the VISIBLE part of START..END in WINDOW.
Return (LEFT TOP WIDTH HEIGHT) or nil."
  (let* ((rs (max start (window-start window)))
         (re (min end (window-end window t)))
         (edges (window-inside-pixel-edges window))
         minx miny maxx maxy)
    (when (< rs re)
      (save-excursion
        (with-current-buffer (window-buffer window)
          (goto-char rs)
          (while (< (point) re)
            (let* ((bol (point))
                   (next (progn (vertical-motion 1 window) (point)))
                   (seg-start (max rs bol))
                   (seg-end   (min re next)))
              (when (< seg-start seg-end)
                (let* ((pos-in-window
	                (pos-visible-in-window-p seg-start window t))
                       (abs
                        (cons (+ (nth 0 edges) (nth 0 pos-in-window))
	                      (+ (nth 1 edges) (nth 1 pos-in-window))))
                       (x     (car abs))
                       (y     (cdr abs))
                       (sz    (window-text-pixel-size window seg-start seg-end))
                       (w     (car sz))
                       (h     (cdr sz))
                       (rx    (+ x w))
                       (by    (+ y h)))
                  (setq minx (if minx (min minx x) x)
                        miny (if miny (min miny y) y)
                        maxx (if maxx (max maxx rx) rx)
                        maxy (if maxy (max maxy by) by))))
              (goto-char next))))))
    (when minx
      (list minx miny (- maxx minx) (- maxy miny)))))

(defun buframe-position-right-of-overlay (frame ov &optional location)
  "Return pixel position (X . Y) for FRAME, placed to the right of overlay OV.
Tries LOCATION first, then fallbacks.  Skips if frame would overlap point."
  (when-let* ((buffer (overlay-buffer ov))
              ;; When there are mutliple windows, `get-buffer-window'
              ;; returns the selected window if it showing the buffer.
              (window (get-buffer-window buffer 'visible))
              (bbox (buframe--region-bbox (overlay-start ov)
                                          (overlay-end ov)
                                          window))
              (parent (frame-parent frame))
              (fw (frame-pixel-width frame))
              (fh (frame-pixel-height frame)))
    (cl-labels
        ((calc (loc)
           (let ((x 0) y)
             (pcase loc
               ('middle
                ;; middle: horizontal right edge, vertical centre
                (setq x (+ (nth 0 bbox) (nth 2 bbox))
                      y (+ (nth 1 bbox) (/ (nth 3 bbox) 2))))
               ('top
                (setq x (+ (nth 0 bbox))
                      y (- (nth 1 bbox) fh)))
               ('bottom
                (setq x (+ (nth 0 bbox))
                      y (+ (nth 1 bbox) (nth 3 bbox)))))
	     ;; if you are loading cl-lib, you can use cl-incf here as well:
             (cl-incf x (if (eq loc 'middle) (default-font-width) 0))
             (cl-incf y (+ (or (frame-parameter frame 'tab-line-height) 0)
                           (or (frame-parameter frame 'header-line-height) 0)
                           (or (and (eq loc 'middle) (- (/ fh 2))) 0)))
             (let* (;;; To clamp to parent frame
                    ;; (px 0) (py 0)
                    ;;(cw (frame-pixel-width parent))
                    ;;(ch (frame-pixel-height parent))
                    ;; Clamp to screen
                    (parent-pos (frame-position parent))
                    (px (+ (car parent-pos) x))
                    (py (+ (cdr parent-pos) y))
                    (cw (x-display-pixel-width))
                    (ch (x-display-pixel-height)))
               (setq px (max 0 (min px (- cw fw))))
               (setq py (max 0 (min py (- ch fh))))
               (cons (max 0 (- px (car parent-pos)))
                     (max 0 (- py (cdr parent-pos)))))))
         (overlap-area (pos)
           (when (and pos bbox)
             (let* ((ox (nth 0 bbox))
                    (oy (nth 1 bbox))
                    (ow (nth 2 bbox))
                    (oh (nth 3 bbox))
                    ;; frame rectangle
                    (rx (car pos)) (ry (cdr pos))
                    (rx2 (+ rx fw)) (by2 (+ ry fh))
                    (rx-ov (+ ox ow)) (by-ov (+ oy oh))
                    (lx (max rx ox)) (ty (max ry oy))
                    (rx-int (min rx2 rx-ov)) (by-int (min by2 by-ov)))
               (if (or (<= rx-int lx) (<= by-int ty))
                   0
                 (* (- rx-int lx) (- by-int ty)))))))
      (let ((order (pcase (or location 'middle)
                     ('top    '(top middle bottom))
                     ('bottom '(bottom middle top))
                     ('middle '(middle bottom top))))
            best-pos best-overlap)
        (catch 'done
          (dolist (loc order)
            (when-let* ((pos (calc loc)))
              (let ((ov (overlap-area pos)))
                (when (eq ov 0)
                  (throw 'done pos))
                (when (or (null best-overlap) (< ov best-overlap))
                  (setq best-pos pos
                        best-overlap ov)))))
          best-pos)))))

;;;###autoload
(defun buframe-make-buffer (name &optional locals)
  "Return a buffer with NAME configured for preview frames.
LOCALS are local variables which are set in the buffer after
creation in addition to `buframe--default-buf-parameters'."
  (let ((fr face-remapping-alist)
        (ls line-spacing)
        (buffer (get-buffer-create name)))
    (with-current-buffer buffer
      ;;; XXX HACK from corfu install mouse ignore map
      (use-local-map buframe--frame-mouse-ignore-map)
      (dolist (vars (list buframe--default-buf-parameters locals))
        (pcase-dolist (`(,sym . ,val) vars)
          (set (make-local-variable sym) val)))
      (setq-local face-remapping-alist (copy-tree fr)
                  line-spacing ls)
      buffer)))

(defun buframe--find (&optional frame-or-name buffer parent noerror)
  "Return frame displaying BUFFER with PARENT.
FRAME-OR-NAME can be a frame object or name.
If BUFFER is non-nil, restrict search to that buffer.
If PARENT is non-nil, restrict to frames with that parent.
If NOERROR is nil and no frame is found, signal an error."
  (or
   (if (framep frame-or-name)
       (and (frame-parameter frame-or-name 'buframe)
            frame-or-name)
     (cl-find-if
      (lambda (frame)
        (when-let* ((buffer-info (frame-parameter frame 'buframe)))
          (and
           (or (null frame-or-name)
               (equal (frame-parameter frame 'name) frame-or-name))
           (or (null parent)
               (eq (frame-parent frame) parent))
           (or (null buffer)
               (equal (buffer-name buffer) (plist-get buffer-info :buf-name))
               (eq buffer (plist-get buffer-info :buf))))))
      (frame-list)))
   (unless noerror
     (error "Frame not found"))))

;;;###autoload
(cl-defun buframe-make (frame-or-name
                        fn-pos
                        buffer
                        &optional
                        (parent-buffer (window-buffer))
                        (parent-frame (window-frame))
                        parameters)
  "Create or reuse a child FRAME displaying BUFFER, positioned using FN-POS.

By default, the frame is configured to be minimal, dedicated,
non-focusable, and properly sized to its buffer.  Positioning is
delegated to FN-POS.  If an existing child frame matching FRAME-OR-NAME
and BUFFER exists, it is reused; otherwise, a new one is created.

FRAME-OR-NAME is either the frame to reuse or its name.
FN-POS is a function called with the frame and overlay/position,
returning (X . Y).
BUFFER is the buffer to display in the child frame.
Optional PARENT-BUFFER and PARENT-FRAME default to the current
buffer and frame.
PARAMETERS is an alist of frame parameters overriding the
defaults."
  (let* ((window-min-height 1)
         (window-min-width 1)
         (inhibit-redisplay t)
         ;; The following is a hack from posframe and from corfu
         ;; (x-gtk-resize-child-frames corfu--gtk-resize-child-frames)
         (before-make-frame-hook)
         (after-make-frame-functions)
         (frame (buframe--find frame-or-name buffer nil t))
         (frm-params (cl-copy-list buframe--default-parameters)))
    (dolist (pair parameters frm-params)
      (setf (alist-get (car pair) frm-params nil t #'equal) (cdr pair)))

    (setq buffer (or (get-buffer buffer) buffer))
    (unless (and (bufferp buffer) (buffer-live-p buffer))
      (setq buffer (buframe-make-buffer buffer)))

    (if (and (frame-live-p frame)
             (eq (frame-parent frame)
                 (and (not (bound-and-true-p exwm--connection))
                      parent-frame))
             ;; If there is more than one window, `frame-root-window' may
             ;; return nil.  Recreate the frame in this case.
             (window-live-p (frame-root-window frame)))
        (progn
          ;; TODO: Should this always be done? Seems to be an overkill
          ;; if the buffer does not display images. But some images get
          ;; out-of-cache requiring this and it needs to be done before
          ;; fitting/updating.
          (clear-image-cache frame)
          (force-window-update (frame-root-window frame)))
      (when frame (delete-frame frame))
      (setq frame (make-frame
                   `((name . ,frame-or-name)
                     (parent-frame . ,parent-frame)
                     (minibuffer . nil)
                     ;; (minibuffer . ,(minibuffer-window parent))
                     (width . 0) (height . 0) (visibility . nil)
                     ,@frm-params))))
    ;; Reset frame parameters if they changed.  For example `tool-bar-mode'
    ;; overrides the parameter `tool-bar-lines' for every frame, including child
    ;; frames.  The child frame API is a pleasure to work with.  It is full of
    ;; lovely surprises.
    (let* ((is (frame-parameters frame))
           (should frm-params)
           (diff (cl-loop for p in should for (k . v) = p
                          unless (equal (alist-get k is) v) collect p)))
      (when diff (modify-frame-parameters frame diff)))

    (let ((win (frame-root-window frame)))
      (unless (eq (window-buffer win) buffer)
        (set-window-buffer win buffer))
      ;; Disallow selection of root window (gh:minad/corfu#63)
      (set-window-parameter win 'no-delete-other-windows t)
      (set-window-parameter win 'no-other-window t)
      ;; Mark window as dedicated to prevent frame reuse (gh:minad/corfu#60)
      (set-window-dedicated-p win t)
      ;; Reset view to show the full frame.
      (set-window-hscroll win 0)
      (set-window-vscroll win 0))
    (set-frame-parameter frame
                         'buframe
                         (list
                          :buf-name (buffer-name buffer)
                          :buf buffer
                          :parent-buffer parent-buffer
                          :fn-pos fn-pos))
    (redirect-frame-focus frame parent-frame)
    (fit-frame-to-buffer frame)
    (buframe-update frame)
    ;; Unparent child frame if EXWM is used, otherwise EXWM buffers are drawn on
    ;; top of the Corfu child frame.
    (when (and (bound-and-true-p exwm--connection) (frame-parent frame))
      (set-frame-parameter frame 'parent-frame nil))

    frame))

(defun buframe-update (frame-or-name)
  "Reposition and show FRAME-OR-NAME using its stored positioning function.
Also ensure frame is made visible."
  (let* ((frame (buframe--find frame-or-name))
         (info (frame-parameter frame-or-name 'buframe))
         (fn-pos (plist-get info :fn-pos)))
    (when (and frame
               (frame-live-p frame)
               (not (buframe-disabled-p frame)))
      (with-current-buffer (plist-get info :parent-buffer)
        (if-let* ((pos (funcall fn-pos frame)))
            (pcase-let ((`(,px . ,py) (frame-position frame))
                        (`(,x . ,y) pos))
              (unless (and (= x px) (= y py))
                (set-frame-position frame x y))
              (unless (frame-visible-p frame)
                (make-frame-visible frame)
                (add-hook 'post-command-hook 'buframe-autohide)
                (add-hook 'post-command-hook 'buframe-autoupdate--debounced nil t)))
          (buframe-hide frame))))))

(defun buframe-disabled-p (frame-or-name)
  "Return non-nil if FRAME-OR-NAME is disabled."
  (let ((frm (buframe--find frame-or-name)))
    (plist-get (frame-parameter frm 'buframe) :disabled)))

(defun buframe-disable (frame-or-name &optional enable)
  "Disable and hide FRAME-OR-NAME.
If ENABLE is non-nil, re-enable and show it."
  (when-let* ((frm (buframe--find frame-or-name))
	      ((frame-live-p frm)))
    (set-frame-parameter
     frm 'buframe
     (plist-put
      (frame-parameter frm 'buframe)
      :disabled
      (not enable)))
    (if enable
        (buframe-update frm)
      (buframe-hide frm))))

(defun buframe-hide (frame-or-name)
  "Make FRAME-OR-NAME invisible."
  (when-let* ((frm (buframe--find frame-or-name))
	      ((and (frame-live-p frm)
		    (frame-visible-p frm))))
    (make-frame-invisible frm))
  (unless
      (cl-find-if
       (lambda (frame)
         (and (frame-parameter frame 'buframe)
              (frame-live-p frame)
              (frame-visible-p frame)))
       (frame-list))
    (remove-hook 'post-command-hook 'buframe-autohide)))

(defun buframe-autohide (&optional frame-or-name)
  "Hide FRAME-OR-NAME if its parent buffer is not selected."
  (buframe--auto* frame-or-name 'buframe-hide 'not-parent))

(defun buframe-autoupdate (&optional frame-or-name)
  "Update FRAME-OR-NAME if its parent buffer is currently selected."
  (buframe--auto* frame-or-name 'buframe-update 'parent))

(defalias 'buframe-autoupdate--debounced (timeout-debounced-func
                                          'buframe-autoupdate
                                          'buframe-update-debounce-delay))

(defun buframe--auto* (frame-or-name fn buffer)
  "Run FN on FRAME-OR-NAME based on BUFFER selection rules.

If FRAME-OR-NAME is nil, run FN on all buframes.
BUFFER can be:
  \\='parent      – run only if parent buffer is current
  \\='not-parent  – run only if parent buffer is not current
  a buffer     – run only if BUFFER is current."
  (if frame-or-name
      (when-let* ((frame (buframe--find frame-or-name)))
        (let ((is-parent (eq (window-buffer)
                             (plist-get (frame-parameter frame 'buframe)
                                        :parent-buffer))))
          (when (or (and (eq buffer 'parent) is-parent)
                    (and (eq buffer 'not-parent) (not is-parent))
                    (eq (window-buffer) buffer))
            ;; If buffer is not selected, we should hide the frame
            (funcall fn frame))))
    (dolist (frame (frame-list))
      (when-let* ((buffer-info (frame-parameter frame 'buframe)))
        (buframe--auto* frame fn buffer)))))

(provide 'buframe)
;;; buframe.el ends here
