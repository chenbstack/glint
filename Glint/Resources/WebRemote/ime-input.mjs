const DELETE = "\x7f";

export function isIOSInputEnvironment(navigatorLike) {
  const userAgent = navigatorLike?.userAgent || "";
  const platform = navigatorLike?.platform || "";
  const touchPoints = navigatorLike?.maxTouchPoints || 0;
  return /iPad|iPhone|iPod/.test(userAgent)
    || (platform === "MacIntel" && touchPoints > 1);
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
