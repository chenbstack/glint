import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(new URL("../Glint/Resources/WebRemote/web-remote.js", import.meta.url), "utf8");
// Execute the shipped handlers with a small DOM/transport fixture. No copy of
// their request matching or state transitions lives in this test harness.
function shippedFunction(name) {
  const start = source.indexOf(`function ${name}(`);
  assert.notEqual(start, -1);
  const end = source.indexOf("\nfunction ", start + 1);
  return source.slice(start, end < 0 ? undefined : end);
}
function harness() {
  const sent = [];
  function element() {
    return {
      hidden: false, textContent: "", children: [], handlers: {}, srcdoc: "",
      classList: { add() {}, remove() {} },
      addEventListener(type, handler) { this.handlers[type] = handler; },
      removeAttribute(name) { delete this[name]; },
      replaceChildren() { this.children = []; },
      append(child) { this.children.push(child); },
    };
  }
  const elements = Object.fromEntries([
    "filesPanel", "filesUp", "filesLocation", "filesList", "filesPreviewName", "filesContent",
    "filesImageViewport", "filesImage", "filesHTML", "filesSourceToggle", "filesMessage", "openFiles",
    "emptyState", "terminal",
  ].map(name => [name, element()]));
  const context = vm.createContext({
    elements, sent,
    document: { createElement: element, querySelector: element },
    imageZoom: { reset() {} },
    terminal: { reset() {}, write(_data, complete) { complete?.(); }, focus() {} },
    decodeBase64: data => Buffer.from(data, "base64"),
    mobileSidebarLayout: { matches: false },
    send: message => sent.push(message), t: key => key,
    clearTimeout() {}, setStatus() {},
    applyBrand() {}, applyTheme() {}, renderState() {}, chooseInitialPane() {}, fitTerminal() {},
  });
  vm.runInContext(`
    let fileWorkspace = "", filePane = "", fileRoot = "", filePaneCwd = "";
    let fileRequestSequence = 0, fileListRequest = "", fileContentRequest = "";
    let fileDirectory = "", filePath = "", htmlSource = "", htmlSourceShown = false;
    let authenticated = true, selectedPane = "pane";
    let controllingPane = "pane", paneRetryTimer = null, paneRetryCount = 0, paneRetryLimit = 5;
    let autoFocusTerminal = false;
    let lastState = { workspaces: [{ id: "ws", panes: [{ id: "pane", cwd: "/A" }] }] };
  `, context);
  for (const name of [
    "handleMessage", "fileErrorLabel", "sandboxedHTML", "clearFilePreview", "matchesFileResponse",
    "updateFilesButton", "updateFileLocation", "openFiles", "closeFiles", "browseFiles", "renderFiles",
    "handleError", "errorLabel",
  ]) vm.runInContext(shippedFunction(name), context);
  const run = code => vm.runInContext(code, context);
  const deliver = message => context.handleMessage(JSON.stringify(message));
  const listReply = (request, root = "/A", name = "README.md") => deliver({
    ...request, type: "fileList", root, entries: [{ name, kind: "file" }], limit: 200,
  });
  const click = () => {
    elements.filesList.children[0].handlers.click();
    return sent.at(-1);
  };
  run("openFiles()");
  listReply(sent.at(-1));
  return { sent, elements, run, deliver, listReply, click };
}

test("directory listings and reads bind the root supplied by the server", () => {
  const h = harness();
  assert.equal(h.sent[0].root, "");
  const read = h.click();
  assert.equal(read.root, "/A");
  assert.ok(read.request);
  h.run('browseFiles("src")');
  assert.equal(h.sent.at(-1).root, "/A");
  assert.notEqual(h.sent.at(-1).request, read.request);
});

test("a cwd update refreshes the root and discards in-flight old contents", () => {
  const h = harness();
  const read = h.click();
  h.deliver({ type: "state", workspaces: [{ id: "ws", panes: [{ id: "pane", cwd: "/B" }] }] });
  assert.equal(h.sent.at(-1).root, "");
  assert.equal(h.sent.at(-1).path, "");
  h.deliver({ ...read, type: "fileContent", content: "old A", format: "text" });
  assert.equal(h.elements.filesContent.textContent, "");
  h.listReply(h.sent.at(-1), "/B");
  const fresh = h.click();
  assert.equal(fresh.root, "/B");
  h.deliver({ ...fresh, type: "fileContent", content: "new B", format: "text" });
  assert.equal(h.elements.filesLocation.textContent, "/B");
  assert.equal(h.elements.filesContent.textContent, "new B");
});

test("a server root-change error invalidates the old preview and discovers the new cwd", () => {
  const h = harness();
  const read = h.click();
  h.deliver({ ...read, type: "fileError", code: "file-root-changed" });
  const discovery = h.sent.at(-1);
  assert.equal(discovery.type, "listFiles");
  assert.equal(discovery.root, "");
  assert.equal(discovery.path, "");
  assert.equal(h.elements.filesList.children.length, 0);
  h.deliver({ ...read, type: "fileContent", content: "stale", format: "text" });
  assert.equal(h.elements.filesContent.textContent, "");
});

test("late listings cannot replace a refreshed listing at the same path", () => {
  const h = harness();
  h.run('browseFiles("")');
  const old = h.sent.at(-1);
  h.run('browseFiles("")');
  const fresh = h.sent.at(-1);
  h.listReply(fresh, "/A", "new.txt");
  h.listReply(old, "/A", "old.txt");
  assert.match(h.elements.filesList.children[0].textContent, /new.txt/);
});

test("late reads of the same filename cannot overwrite a newer preview", () => {
  const h = harness();
  const old = h.click();
  const fresh = h.click();
  h.deliver({ ...fresh, type: "fileContent", content: "new", format: "text" });
  h.deliver({ ...old, type: "fileContent", content: "old", format: "text" });
  assert.equal(h.elements.filesContent.textContent, "new");
});

test("closing and reopening the same pane invalidates earlier responses", () => {
  const h = harness();
  const read = h.click();
  h.run("closeFiles(); openFiles()");
  h.listReply(h.sent.at(-1));
  h.click();
  h.deliver({ ...read, type: "fileContent", content: "old", format: "text" });
  assert.equal(h.elements.filesContent.textContent, "");
});

test("text, HTML and image contents from another root are never rendered", () => {
  for (const [type, format] of [["fileContent", "text"], ["fileContent", "html"], ["fileImage", null]]) {
    const h = harness();
    const read = h.click();
    h.deliver({ ...read, root: "/B", type, format, content: "wrong root", data: "cG5n" });
    assert.equal(h.elements.filesContent.textContent, "");
    assert.equal(h.elements.filesHTML.srcdoc, "");
    assert.equal(h.elements.filesImage.src, undefined);
  }
});

test("errors for an obsolete read cannot clear the current preview", () => {
  const h = harness();
  const old = h.click();
  const fresh = h.click();
  h.deliver({ ...fresh, type: "fileContent", content: "new", format: "text" });
  h.deliver({ ...old, type: "fileError", code: "file-root-changed" });
  assert.equal(h.elements.filesContent.textContent, "new");
  assert.equal(h.sent.at(-1).request, fresh.request);
});

// A rejected file operation must leave the live terminal usable and permit a
// fresh request instead of requiring a transport reconnect.
test("busy and oversized file errors allow a successful retry", () => {
  for (const [code, label] of [["file-busy", "file_busy"], ["response-too-large", "response_too_large"]]) {
    const h = harness();
    const read = h.click();
    h.deliver({ ...read, type: "fileError", code });
    assert.equal(h.elements.filesMessage.textContent, label);
    assert.equal(h.run("authenticated && controllingPane === 'pane'"), true);
    const retry = h.click();
    assert.notEqual(retry.request, read.request);
    h.deliver({ ...retry, type: "fileContent", content: "retried", format: "text" });
    assert.equal(h.elements.filesContent.textContent, "retried");
  }
});

test("coalesced send pressure releases pending file operations without disabling the terminal", () => {
  const h = harness();
  h.click();
  h.run("fileListRequest = 'pending-list'");
  h.deliver({ type: "error", code: "send-queue-busy" });
  assert.equal(h.run("fileListRequest === '' && fileContentRequest === ''"), true);
  assert.equal(h.run("authenticated && controllingPane === 'pane'"), true);
  assert.equal(h.elements.filesMessage.textContent, "send_queue_busy");
});

test("oversized snapshots stop automatic retries without closing the connection", () => {
  const h = harness();
  h.deliver({ type: "error", code: "response-too-large", pane: "pane" });
  assert.equal(h.run("authenticated && selectedPane === 'pane' && controllingPane === ''"), true);
  assert.equal(h.run("paneRetryCount === paneRetryLimit"), true);
});

for (const [label, fileErrors] of [["ordinary response pressure", 0], ["a saturated file-error queue", 32]]) {
  test(`snapshot busy after ${label} revokes old control until a successful retry`, () => {
    const h = harness();
    h.deliver({ type: "snapshot", pane: "pane", data: "b2xk" });
    const request = h.click();
    for (let index = 0; index < fileErrors; index += 1) {
      h.deliver({ ...request, type: "fileError", code: "file-busy" });
    }
    assert.equal(h.run("controllingPane"), "pane");
    h.deliver({ type: "error", code: "snapshot-busy", pane: "pane" });
    assert.equal(h.run("controllingPane"), "");
    assert.equal(h.run("authenticated"), true);
    h.deliver({ type: "snapshot", pane: "pane", data: "bmV3" });
    assert.equal(h.run("controllingPane"), "pane");
  });
}

test("a rejected snapshot for an old pane cannot revoke the newly selected pane", () => {
  const h = harness();
  h.deliver({ type: "snapshot", pane: "pane", data: "bmV3" });
  for (const code of ["snapshot-busy", "response-too-large"]) {
    h.deliver({ type: "error", code, pane: "previous-pane" });
    assert.equal(h.run("controllingPane"), "pane");
  }
});
