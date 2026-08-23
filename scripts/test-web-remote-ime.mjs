import assert from "node:assert/strict";
import test from "node:test";
import {
  IOSIMEInputFallback,
  installIOSIMEInputFallback,
  isIOSInputEnvironment,
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
