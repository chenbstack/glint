import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  IOSIMEInputFallback,
  installIOSNativeTouchInput,
  installIOSIMEInputFallback,
  isIOSInputEnvironment,
  shouldUseNativeTouchInput,
  textareaDelta,
} from "../Glint/Resources/WebRemote/ime-input.mjs";

function makeTerminal() {
  const listeners = new Map();
  return {
    textarea: {
      value: "",
      addEventListener(type, listener) {
        listeners.set(type, listener);
      },
    },
    attachCustomKeyEventHandler(handler) {
      this.keyHandler = handler;
    },
    listeners,
  };
}

function makeTouchTerminal() {
  const elementListeners = new Map();
  const rowsListeners = new Map();
  const textareaListeners = new Map();
  const classes = new Set();
  const row = { getBoundingClientRect: () => ({ height: 20 }) };
  const rows = {
    addEventListener(type, listener) { rowsListeners.set(type, listener); },
  };
  const screen = { getBoundingClientRect: () => ({ width: 800 }) };
  return {
    cols: 80,
    buffer: { active: { cursorX: 2, cursorY: 3 } },
    element: {
      classList: { add: value => classes.add(value) },
      addEventListener(type, listener) { elementListeners.set(type, listener); },
      querySelector(selector) {
        if (selector === ".xterm-screen") return screen;
        if (selector === ".xterm-rows") return rows;
        if (selector === ".xterm-rows > div") return row;
        return null;
      },
    },
    textarea: {
      value: "",
      selectionStart: 0,
      selectionEnd: 0,
      style: {},
      addEventListener(type, listener) { textareaListeners.set(type, listener); },
    },
    focusCalls: 0,
    focus() { this.focusCalls += 1; },
    onRender(listener) { this.renderListener = listener; },
    onCursorMove(listener) { this.cursorListener = listener; },
    classes,
    elementListeners,
    rowsListeners,
    textareaListeners,
  };
}

test("only enables the fallback on iPhone and iPad environments", () => {
  assert.equal(isIOSInputEnvironment({ userAgent: "Mozilla/5.0 (iPhone)", platform: "iPhone" }), true);
  assert.equal(isIOSInputEnvironment({ userAgent: "Mozilla/5.0 (iPad)", platform: "iPad" }), true);
  assert.equal(isIOSInputEnvironment({
    userAgent: "Mozilla/5.0 (Macintosh)",
    platform: "MacIntel",
    maxTouchPoints: 5,
  }), true);
  assert.equal(isIOSInputEnvironment({
    userAgent: "Mozilla/5.0 (Macintosh)",
    platform: "MacIntel",
    maxTouchPoints: 0,
  }), false);
  assert.equal(isIOSInputEnvironment({ userAgent: "Mozilla/5.0 (Linux; Android 16)" }), false);
});

test("ships native touch selection and callout styles", () => {
  const css = readFileSync(
    new URL("../Glint/Resources/WebRemote/web-remote.css", import.meta.url),
    "utf8"
  );
  assert.match(css, /\.xterm\.glint-native-touch-input/);
  assert.match(css, /-webkit-touch-callout:\s*default/);
  assert.match(css, /pointer-events:\s*auto/);
});

test("does not install any handlers outside iOS and iPadOS", () => {
  const terminal = makeTerminal();
  const fallback = installIOSIMEInputFallback(
    terminal,
    () => {},
    { userAgent: "Mozilla/5.0 (Macintosh)", platform: "MacIntel", maxTouchPoints: 0 }
  );

  assert.equal(fallback, null);
  assert.equal(terminal.keyHandler, undefined);
  assert.equal(terminal.listeners.size, 0);
});

test("enables native touch input only for coarse-pointer iOS environments", () => {
  const iphone = { userAgent: "Mozilla/5.0 (iPhone)", platform: "iPhone", maxTouchPoints: 5 };
  const desktop = { userAgent: "Mozilla/5.0 (Macintosh)", platform: "MacIntel", maxTouchPoints: 0 };
  assert.equal(shouldUseNativeTouchInput(iphone, { matchMedia: () => ({ matches: true }) }), true);
  assert.equal(shouldUseNativeTouchInput(iphone, { matchMedia: () => ({ matches: false }) }), false);
  assert.equal(shouldUseNativeTouchInput(desktop, { matchMedia: () => ({ matches: true }) }), false);
});

test("makes the iOS textarea touchable at the terminal cursor", () => {
  const terminal = makeTouchTerminal();
  const frameCallbacks = [];
  const controller = installIOSNativeTouchInput(
    terminal,
    () => {},
    { userAgent: "Mozilla/5.0 (iPhone)", platform: "iPhone", maxTouchPoints: 5 },
    {
      matchMedia: () => ({ matches: true }),
      requestAnimationFrame: callback => frameCallbacks.push(callback),
    }
  );

  assert.notEqual(controller, null);
  assert.equal(terminal.classes.has("glint-native-touch-input"), true);
  frameCallbacks.shift()();
  assert.equal(terminal.textarea.style.left, "20px");
  assert.equal(terminal.textarea.style.top, "60px");
  assert.equal(terminal.textarea.style.width, "80px");
  assert.equal(terminal.textarea.style.height, "32px");
  assert.equal(terminal.textarea.style.zIndex, "10");

  let mouseStopped = false;
  terminal.textareaListeners.get("mousedown")({
    stopPropagation() { mouseStopped = true; },
  });
  assert.equal(mouseStopped, true);
  assert.equal(terminal.focusCalls, 1);
});

test("routes native insertFromPaste text once and clears the helper textarea", () => {
  const terminal = makeTouchTerminal();
  const pasted = [];
  installIOSNativeTouchInput(
    terminal,
    value => pasted.push(value),
    { userAgent: "Mozilla/5.0 (iPhone)", platform: "iPhone", maxTouchPoints: 5 },
    { matchMedia: () => ({ matches: true }), requestAnimationFrame: () => {} }
  );

  terminal.textarea.value = "old";
  terminal.textarea.selectionStart = 3;
  terminal.textarea.selectionEnd = 3;
  terminal.textareaListeners.get("beforeinput")({ inputType: "insertFromPaste" });
  terminal.textarea.value = "old粘贴";
  let inputStopped = false;
  terminal.textareaListeners.get("input")({
    inputType: "insertFromPaste",
    data: null,
    stopImmediatePropagation() { inputStopped = true; },
  });

  assert.equal(inputStopped, true);
  assert.deepEqual(pasted, ["粘贴"]);
  assert.equal(terminal.textarea.value, "");
});

test("prevents native insertion when xterm can handle ClipboardEvent data", () => {
  const terminal = makeTouchTerminal();
  const pasted = [];
  installIOSNativeTouchInput(
    terminal,
    value => pasted.push(value),
    { userAgent: "Mozilla/5.0 (iPhone)", platform: "iPhone", maxTouchPoints: 5 },
    { matchMedia: () => ({ matches: true }), requestAnimationFrame: () => {} }
  );

  let prevented = false;
  terminal.textareaListeners.get("paste")({
    clipboardData: { getData: () => "native" },
    preventDefault() { prevented = true; },
  });

  assert.equal(prevented, true);
  assert.deepEqual(pasted, []);
});

test("installs an iOS-only key handler that owns deferred 229 input", () => {
  const terminal = makeTerminal();
  const emitted = [];
  installIOSIMEInputFallback(
    terminal,
    value => emitted.push(value),
    { userAgent: "Mozilla/5.0 (iPhone)", platform: "iPhone", maxTouchPoints: 5 }
  );

  assert.equal(terminal.keyHandler({ type: "keydown", keyCode: 229, isComposing: false }), false);
  terminal.textarea.value = "，";
  let inputStopped = false;
  terminal.listeners.get("input")({
    isComposing: false,
    stopImmediatePropagation() { inputStopped = true; },
  });
  assert.equal(inputStopped, true);
  assert.equal(terminal.keyHandler({ type: "keyup", keyCode: 0, isComposing: false }), true);
  assert.deepEqual(emitted, ["，"]);
});

test("computes the minimal terminal payload for iOS textarea changes", () => {
  assert.equal(textareaDelta("", "，"), "，");
  assert.equal(textareaDelta("hello ", "hello。"), "\x7f。");
  assert.equal(textareaDelta("unchanged", "unchanged"), "");
  assert.equal(textareaDelta("abc", "ab"), "\x7f");
});

test("emits punctuation that only becomes visible at keyup", () => {
  const textarea = { value: "" };
  const emitted = [];
  const fallback = new IOSIMEInputFallback(textarea, value => emitted.push(value));

  assert.equal(fallback.handleKeyDown({ keyCode: 229, isComposing: false }), true);
  textarea.value = "，";
  fallback.handleKeyUp({ keyCode: 0 });

  assert.deepEqual(emitted, ["，"]);
});

test("emits delete plus replacement for the double-space Chinese period conversion", () => {
  const textarea = { value: "hello " };
  const emitted = [];
  const fallback = new IOSIMEInputFallback(textarea, value => emitted.push(value));

  fallback.handleKeyDown({ keyCode: 229, isComposing: false });
  textarea.value = "hello。";
  fallback.handleKeyUp({ keyCode: 32 });

  assert.deepEqual(emitted, ["\x7f。"]);
});

test("does not intercept ordinary keys or active compositions", () => {
  const textarea = { value: "" };
  const fallback = new IOSIMEInputFallback(textarea, () => {});

  assert.equal(fallback.handleKeyDown({ keyCode: 65, isComposing: false }), false);
  assert.equal(fallback.handleKeyDown({ keyCode: 229, isComposing: true }), false);
});

test("cancels the 229 fallback when a real composition starts", () => {
  const textarea = { value: "" };
  const emitted = [];
  const fallback = new IOSIMEInputFallback(textarea, value => emitted.push(value));

  fallback.handleKeyDown({ keyCode: 229, isComposing: false });
  fallback.handleCompositionStart();
  textarea.value = "你";
  fallback.handleKeyUp({ keyCode: 0 });

  assert.deepEqual(emitted, []);
});

test("does not duplicate data already emitted by xterm", () => {
  const textarea = { value: "" };
  const emitted = [];
  const fallback = new IOSIMEInputFallback(textarea, value => emitted.push(value));

  fallback.handleKeyDown({ keyCode: 229, isComposing: false });
  textarea.value = "！";
  fallback.noteTerminalData("！");
  fallback.handleKeyUp({ keyCode: 0 });

  assert.deepEqual(emitted, []);
});

test("falls back to compositionend data only when xterm emits nothing", () => {
  const textarea = { value: "你" };
  const emitted = [];
  const scheduled = [];
  const fallback = new IOSIMEInputFallback(
    textarea,
    value => emitted.push(value),
    callback => scheduled.push(callback)
  );

  fallback.handleCompositionEnd({ data: "你" });
  assert.deepEqual(emitted, []);
  scheduled.shift()();
  assert.deepEqual(emitted, ["你"]);
});

test("cancels the composition fallback when xterm already emitted", () => {
  const textarea = { value: "你" };
  const emitted = [];
  const scheduled = [];
  const fallback = new IOSIMEInputFallback(
    textarea,
    value => emitted.push(value),
    callback => scheduled.push(callback)
  );

  fallback.handleCompositionEnd({ data: "你" });
  fallback.noteTerminalData("你");
  scheduled.shift()();

  assert.deepEqual(emitted, []);
});
