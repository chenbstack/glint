const DELETE = "\x7f";

export function isIOSInputEnvironment(navigatorLike) {
  const userAgent = navigatorLike?.userAgent || "";
  const platform = navigatorLike?.platform || "";
  const touchPoints = navigatorLike?.maxTouchPoints || 0;
  return /iPad|iPhone|iPod/.test(userAgent)
    || (platform === "MacIntel" && touchPoints > 1);
}

export function shouldUseNativeTouchInput(navigatorLike, targetWindow) {
  if (!isIOSInputEnvironment(navigatorLike)) return false;
  return targetWindow?.matchMedia?.("(hover: none) and (pointer: coarse)").matches ?? true;
}

export function installTwoFingerTerminalScrolling(
  terminal,
  target,
  WheelEventLike = WheelEvent
) {
  let touchScrollY = null;
  let touchScrollRemainder = 0;

  const reset = () => {
    touchScrollY = null;
    touchScrollRemainder = 0;
  };
  const touchCenterY = touches => (touches[0].clientY + touches[1].clientY) / 2;
  const terminalLineHeight = () => {
    const row = target.querySelector(".xterm-rows > div");
    const measured = row?.getBoundingClientRect().height;
    return measured > 0
      ? measured
      : terminal.options.fontSize * terminal.options.lineHeight;
  };
  const scrollLines = (lines, clientX, clientY) => {
    // When xterm owns scrollback, scroll it directly. Synthetic one-line wheel
    // events only move its viewport once on touch browsers, then stall.
    if (terminal.buffer.active.baseY > 0
        && terminal.modes?.mouseTrackingMode === "none") {
      terminal.scrollLines(lines);
      return;
    }

    // Full-screen TUIs may own the mouse. Preserve wheel delivery for those
    // applications so they can scroll themselves.
    const screen = target.querySelector(".xterm-screen");
    if (!screen) return;
    const direction = Math.sign(lines);
    for (let index = 0; index < Math.abs(lines); index += 1) {
      screen.dispatchEvent(new WheelEventLike("wheel", {
        bubbles: true,
        cancelable: true,
        clientX,
        clientY,
        deltaMode: WheelEventLike.DOM_DELTA_LINE,
        deltaY: direction,
      }));
    }
  };

  target.addEventListener("touchstart", event => {
    if (event.touches.length !== 2) {
      reset();
      return;
    }
    event.preventDefault();
    touchScrollY = touchCenterY(event.touches);
    touchScrollRemainder = 0;
  }, { passive: false });

  target.addEventListener("touchmove", event => {
    if (event.touches.length !== 2 || touchScrollY === null) {
      reset();
      return;
    }
    event.preventDefault();
    const nextY = touchCenterY(event.touches);
    touchScrollRemainder += touchScrollY - nextY;
    touchScrollY = nextY;

    const lineHeight = terminalLineHeight();
    const lines = Math.trunc(touchScrollRemainder / lineHeight);
    if (lines === 0) return;
    const clientX = (event.touches[0].clientX + event.touches[1].clientX) / 2;
    scrollLines(lines, clientX, nextY);
    touchScrollRemainder -= lines * lineHeight;
  }, { passive: false });

  target.addEventListener("touchend", reset);
  target.addEventListener("touchcancel", reset);
}

function pastedTextFromInput(baseline, newValue, eventData) {
  if (baseline) {
    const prefix = baseline.value.slice(0, baseline.start);
    const suffix = baseline.value.slice(baseline.end);
    if (newValue.startsWith(prefix) && newValue.endsWith(suffix)) {
      return newValue.slice(prefix.length, newValue.length - suffix.length);
    }
  }
  return typeof eventData === "string" ? eventData : newValue;
}

export function installIOSNativeTouchInput(
  terminal,
  pasteText,
  navigatorLike = navigator,
  targetWindow = window
) {
  if (!shouldUseNativeTouchInput(navigatorLike, targetWindow)
      || !terminal.element
      || !terminal.textarea) return null;

  const screen = terminal.element.querySelector(".xterm-screen");
  const rows = terminal.element.querySelector(".xterm-rows");
  if (!screen || !rows) return null;

  const textarea = terminal.textarea;
  let pendingPaste = null;
  terminal.element.classList.add("glint-native-touch-input");

  const syncTextarea = () => {
    const row = terminal.element.querySelector(".xterm-rows > div");
    const measuredHeight = row?.getBoundingClientRect().height;
    const cellHeight = measuredHeight > 0
      ? measuredHeight
      : (terminal.options?.fontSize || 13) * (terminal.options?.lineHeight || 1);
    const screenWidth = screen.getBoundingClientRect().width;
    const cellWidth = terminal.cols > 0 ? screenWidth / terminal.cols : 0;
    const cursor = terminal.buffer.active;
    textarea.style.left = `${cursor.cursorX * cellWidth}px`;
    textarea.style.top = `${cursor.cursorY * cellHeight}px`;
    textarea.style.width = `${Math.max(cellWidth, 80)}px`;
    textarea.style.height = `${Math.max(cellHeight, 32)}px`;
    textarea.style.lineHeight = `${cellHeight}px`;
    textarea.style.zIndex = "10";
  };

  terminal.onRender?.(syncTextarea);
  terminal.onCursorMove?.(syncTextarea);
  if (targetWindow.requestAnimationFrame) targetWindow.requestAnimationFrame(syncTextarea);
  else syncTextarea();

  const handleNativeMouseDown = event => {
    if (terminal.modes?.mouseTrackingMode
        && terminal.modes.mouseTrackingMode !== "none") return;
    event.stopPropagation();
    terminal.focus();
  };
  rows.addEventListener("mousedown", handleNativeMouseDown, { capture: true });
  textarea.addEventListener("mousedown", handleNativeMouseDown, { capture: true });

  textarea.addEventListener("paste", event => {
    // Let xterm consume ClipboardEvent data, but stop WebKit from also inserting
    // the same text into the helper textarea and producing a second input event.
    if (event.clipboardData) event.preventDefault();
  }, { capture: true });

  textarea.addEventListener("beforeinput", event => {
    if (event.inputType !== "insertFromPaste") return;
    const start = textarea.selectionStart ?? textarea.value.length;
    const end = textarea.selectionEnd ?? start;
    pendingPaste = { value: textarea.value, start: Math.min(start, end), end: Math.max(start, end) };
  }, { capture: true });

  textarea.addEventListener("input", event => {
    if (event.inputType !== "insertFromPaste") return;
    const text = pastedTextFromInput(pendingPaste, textarea.value, event.data);
    pendingPaste = null;
    textarea.value = "";
    event.stopImmediatePropagation();
    if (text) pasteText(text);
  }, { capture: true });

  return { syncTextarea };
}

export function textareaDelta(oldValue, newValue) {
  if (oldValue === newValue) return "";
  if (newValue.length < oldValue.length) return DELETE;

  let prefixLength = 0;
  while (prefixLength < oldValue.length
      && prefixLength < newValue.length
      && oldValue.charCodeAt(prefixLength) === newValue.charCodeAt(prefixLength)) {
    prefixLength += 1;
  }
  return DELETE.repeat(oldValue.length - prefixLength) + newValue.slice(prefixLength);
}

export class IOSIMEInputFallback {
  constructor(textarea, emit, schedule = callback => setTimeout(callback, 0)) {
    this.textarea = textarea;
    this.emit = emit;
    this.schedule = schedule;
    this.pending229Baseline = null;
    this.pendingCompositionCommit = null;
    this.compositionGeneration = 0;
  }

  handleKeyDown(event) {
    if (event.keyCode !== 229 || event.isComposing) return false;
    if (this.pending229Baseline === null) this.pending229Baseline = this.textarea.value;
    return true;
  }

  handleKeyUp() {
    if (this.pending229Baseline === null) return;
    const baseline = this.pending229Baseline;
    this.pending229Baseline = null;
    const payload = textareaDelta(baseline, this.textarea.value);
    if (payload) this.emit(payload);
  }

  handleCompositionStart() {
    this.pending229Baseline = null;
    this.pendingCompositionCommit = null;
    this.compositionGeneration += 1;
  }

  handleCompositionEnd(event) {
    if (!event.data) return;
    const commit = event.data;
    const generation = ++this.compositionGeneration;
    this.pendingCompositionCommit = commit;
    // xterm registered its compositionend listener first, so its zero-delay
    // send runs before this fallback. noteTerminalData cancels us when it did.
    this.schedule(() => {
      if (this.compositionGeneration !== generation
          || this.pendingCompositionCommit !== commit) return;
      this.pendingCompositionCommit = null;
      this.emit(commit);
    });
  }

  noteTerminalData() {
    this.pending229Baseline = null;
    this.pendingCompositionCommit = null;
    this.compositionGeneration += 1;
  }

  shouldOwnInputEvent(event) {
    return this.pending229Baseline !== null && !event.isComposing;
  }
}

export function installIOSIMEInputFallback(terminal, emit, navigatorLike = navigator) {
  if (!isIOSInputEnvironment(navigatorLike) || !terminal.textarea) return null;

  const fallback = new IOSIMEInputFallback(terminal.textarea, emit);
  terminal.attachCustomKeyEventHandler(event => {
    // iOS exposes IME punctuation only after keydown. Keep xterm from taking
    // its one-shot keydown snapshot; handle the final textarea value at keyup.
    if (event.type === "keydown" && fallback.handleKeyDown(event)) return false;
    if (event.type === "keyup") fallback.handleKeyUp(event);
    return true;
  });
  terminal.textarea.addEventListener("input", event => {
    // This fallback owns only the intercepted non-composition 229 cycle.
    // Real composition events continue through xterm unchanged.
    if (fallback.shouldOwnInputEvent(event)) event.stopImmediatePropagation();
  }, { capture: true });
  terminal.textarea.addEventListener("compositionstart", () => fallback.handleCompositionStart());
  terminal.textarea.addEventListener("compositionend", event => fallback.handleCompositionEnd(event));
  return fallback;
}
