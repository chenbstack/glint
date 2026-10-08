import { Terminal } from "/xterm.mjs";
import { FitAddon } from "/addon-fit.mjs";
import {
  installIOSIMEInputFallback,
  installIOSNativeTouchInput,
  installTwoFingerTerminalScrolling,
} from "/ime-input.mjs";
import {
  hmacSha256,
  hkdfExtractExpand,
  hkdfExpand,
  aesGcmSeal,
  aesGcmOpen,
} from "/crypto.mjs";

// Crypto labels — must match the Swift server's WebRemoteCrypto byte-for-byte.
const PROOF_LABEL = "glint-webremote/v1/proof";
const SESSION_INFO = "glint-webremote/v1/session";
const C2S_INFO = "c2s";
const S2C_INFO = "s2c";

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

function hexToBytes(hex) {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = Number.parseInt(hex.substr(i * 2, 2), 16);
  }
  return bytes;
}

function concatBytes(...parts) {
  let length = 0;
  for (const part of parts) length += part.length;
  const out = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

// 12-byte GCM nonce: 4 zero bytes + 8-byte big-endian counter (matches Swift).
function nonceFor(counter) {
  const nonce = new Uint8Array(12);
  new DataView(nonce.buffer).setBigUint64(4, BigInt(counter), false);
  return nonce;
}

function counterFromNonce(nonce) {
  return Number(new DataView(nonce.buffer, nonce.byteOffset, nonce.byteLength)
    .getBigUint64(4, false));
}

const language = (navigator.languages?.[0] || navigator.language || "en")
  .toLowerCase()
  .startsWith("zh") ? "zh" : "en";
const translations = {
  zh: {
    access_key: "访问密钥",
    access_key_help: "请在 Glint 设置 → Terminal → Web remote control 中单独复制访问密钥。",
    auto_focus_terminal: "自动聚焦",
    bad_request: "请求格式错误",
    choose_terminal_heading: "从左侧选择一个终端",
    close_new_project: "关闭新建项目",
    close_sidebar: "关闭项目与终端",
    close_terminal: "关闭终端",
    close_terminal_aria: "关闭 {name}",
    close_terminal_confirm: "“{name}”中仍有程序运行。确定要关闭并终止它吗？",
    connect_glint: "连接 Glint",
    connected: "已连接",
    connecting: "正在连接",
    create_terminal: "正在新建终端",
    disconnected: "连接已断开",
    enter_access_key: "输入访问密钥",
    existing_directory_hint: "目录必须已经存在；不会自动 git init 或 clone。",
    files: "文件",
    open_current_folder: "查看当前目录文件",
    files_up: "上一级",
    files_refresh: "刷新文件",
    files_close: "返回终端",
    files_empty: "此目录没有文件",
    files_choose: "选择文件以预览",
    files_loading: "正在读取…",
    html_preview: "页面预览",
    html_source: "源码",
    html_preview_notice: "静态预览：脚本和外部资源不会加载",
    image_too_large: "图片过大，无法生成预览",
    image_unavailable: "无法解码此图片",
    files_limited: "仅显示前 200 项",
    files_unavailable: "当前终端没有可访问的本地目录",
    file_root_changed: "终端目录已变化，正在刷新…",
    invalid_file_path: "文件路径无效或超出项目目录",
    file_unavailable: "文件或目录无法读取",
    file_too_large: "文件超过 128 KB，无法预览",
    file_not_text: "仅支持预览 UTF-8 文本文件",
    invalid_project_path: "目录不存在，或不是这台 Mac 上可访问的文件夹。",
    loading_terminal: "正在载入终端",
    last_terminal: "每个 Workspace 至少需要保留一个终端",
    mac_directory: "这台 Mac 上的目录",
    new_project: "新建项目",
    open: "打开",
    open_sidebar: "打开项目与终端",
    opening_project: "正在打开项目…",
    operation_failed: "操作失败：{code}",
    project_opened: "项目已打开。",
    projects_and_terminals: "项目与终端",
    quick_keys: "快捷键",
    reconnect: "重连",
    refresh: "刷新",
    remote_terminal: "远程终端",
    select_terminal: "选择一个终端",
    sync_description: "画面和输入会在浏览器与这台 Mac 上的 Glint 会话之间实时同步。",
    syncing_terminal: "正在同步终端画面…",
    terminal_count: "{count} 个终端",
    terminal_closed: "终端已关闭",
    terminal_created: "已新建终端",
    terminal_not_ready: "终端尚未准备好",
    terminal_ready: "终端已就绪",
    unable_connect: "无法连接",
    unauthorized: "访问密钥无效或已经失效。",
    unknown_command: "不支持的操作",
    unknown_pane: "终端已经不存在",
    unknown_workspace: "Workspace 已经不存在",
    waiting_terminal: "等待终端画面",
    workspace_archived: "归档的 Workspace 不能新建终端",
    workspace_new_terminal: "在此 Workspace 中新建终端",
    workspace_new_terminal_aria: "在 {name} 中新建终端",
  },
  en: {
    access_key: "Access key",
    access_key_help: "Copy the access key from Glint Settings → Terminal → Web remote control.",
    auto_focus_terminal: "Open keyboard after switching terminal",
    bad_request: "Invalid request",
    choose_terminal_heading: "Choose a terminal from the sidebar",
    close_new_project: "Close new project",
    close_sidebar: "Close projects and terminals",
    close_terminal: "Close terminal",
    close_terminal_aria: "Close {name}",
    close_terminal_confirm: "A process is still running in “{name}”. Close the terminal and terminate it?",
    connect_glint: "Connect to Glint",
    connected: "Connected",
    connecting: "Connecting",
    create_terminal: "Creating terminal",
    disconnected: "Disconnected",
    enter_access_key: "Enter access key",
    existing_directory_hint: "The directory must already exist; Glint will not run git init or clone.",
    files: "Files",
    open_current_folder: "Browse the current terminal folder",
    files_up: "Parent folder",
    files_refresh: "Refresh files",
    files_close: "Back to terminal",
    files_empty: "This folder is empty",
    files_choose: "Select a file to preview",
    files_loading: "Loading…",
    html_preview: "Preview",
    html_source: "Source",
    html_preview_notice: "Static preview: scripts and external resources are disabled",
    image_too_large: "This image is too large to preview",
    image_unavailable: "Unable to decode this image",
    files_limited: "Showing the first 200 items",
    files_unavailable: "This terminal has no accessible local directory",
    file_root_changed: "The terminal directory changed. Refreshing…",
    invalid_file_path: "File path is invalid or outside the workspace",
    file_unavailable: "File or folder cannot be read",
    file_too_large: "Files over 128 KB cannot be previewed",
    file_not_text: "Only UTF-8 text files can be previewed",
    invalid_project_path: "The directory does not exist or is not accessible on this Mac.",
    loading_terminal: "Loading terminal",
    last_terminal: "Each workspace must keep at least one terminal",
    mac_directory: "Directory on this Mac",
    new_project: "New project",
    open: "Open",
    open_sidebar: "Open projects and terminals",
    opening_project: "Opening project…",
    operation_failed: "Operation failed: {code}",
    project_opened: "Project opened.",
    projects_and_terminals: "Projects and terminals",
    quick_keys: "Quick keys",
    reconnect: "Reconnect",
    refresh: "Refresh",
    remote_terminal: "Remote terminal",
    select_terminal: "Select a terminal",
    sync_description: "The browser stays in sync with this Mac's live Glint session.",
    syncing_terminal: "Syncing terminal…",
    terminal_count: "{count} terminal(s)",
    terminal_closed: "Terminal closed",
    terminal_created: "Terminal created",
    terminal_not_ready: "Terminal is not ready",
    terminal_ready: "Terminal ready",
    unable_connect: "Unable to connect",
    unauthorized: "The access key is invalid or has expired.",
    unknown_command: "Unsupported operation",
    unknown_pane: "The terminal no longer exists",
    unknown_workspace: "The workspace no longer exists",
    waiting_terminal: "Waiting for terminal",
    workspace_archived: "Cannot create a terminal in an archived workspace",
    workspace_new_terminal: "Create a terminal in this workspace",
    workspace_new_terminal_aria: "Create a terminal in {name}",
  },
};

function t(key, values = {}) {
  let value = translations[language][key] || key;
  for (const [name, replacement] of Object.entries(values)) {
    value = value.replace(`{${name}}`, String(replacement));
  }
  return value;
}

function localizeDocument() {
  document.documentElement.lang = language === "zh" ? "zh-CN" : "en";
  document.querySelectorAll("[data-i18n]").forEach(element => {
    element.textContent = t(element.dataset.i18n);
  });
  document.querySelectorAll("[data-i18n-aria]").forEach(element => {
    element.setAttribute("aria-label", t(element.dataset.i18nAria));
  });
}

const elements = {
  activeLabel: document.querySelector("#active-label"),
  authDialog: document.querySelector("#auth-dialog"),
  authError: document.querySelector("#auth-error"),
  authForm: document.querySelector("#auth-form"),
  autoFocusTerminal: document.querySelector("#auto-focus-terminal"),
  brandFallback: document.querySelector("#brand-fallback"),
  brandIcon: document.querySelector("#brand-icon"),
  createClose: document.querySelector("#create-close"),
  createDialog: document.querySelector("#create-dialog"),
  createForm: document.querySelector("#create-form"),
  createMessage: document.querySelector("#create-message"),
  createProject: document.querySelector("#create-project"),
  emptyState: document.querySelector("#empty-state"),
  filesPanel: document.querySelector("#files-panel"),
  filesUp: document.querySelector("#files-up"),
  filesLocation: document.querySelector("#files-location"),
  filesRefresh: document.querySelector("#files-refresh"),
  filesClose: document.querySelector("#files-close"),
  filesList: document.querySelector("#files-list"),
  filesPreviewName: document.querySelector("#files-preview-name"),
  filesContent: document.querySelector("#files-content"),
  filesImage: document.querySelector("#files-image"),
  filesImageViewport: document.querySelector("#files-image-viewport"),
  filesHTML: document.querySelector("#files-html"),
  filesSourceToggle: document.querySelector("#files-source-toggle"),
  filesMessage: document.querySelector("#files-message"),
  openFiles: document.querySelector("#open-files"),
  projectPath: document.querySelector("#project-path"),
  reconnect: document.querySelector("#reconnect"),
  refresh: document.querySelector("#refresh"),
  sidebar: document.querySelector("#sidebar"),
  sidebarBackdrop: document.querySelector("#sidebar-backdrop"),
  sidebarClose: document.querySelector("#sidebar-close"),
  sidebarToggle: document.querySelector("#sidebar-toggle"),
  statusDot: document.querySelector("#status-dot"),
  statusText: document.querySelector("#status-text"),
  terminal: document.querySelector("#terminal"),
  tokenInput: document.querySelector("#token-input"),
  workspaceList: document.querySelector("#workspace-list"),
};
localizeDocument();

const defaultTerminalTheme = {
  background: "#0b0c11",
  foreground: "#e8e9ee",
  cursor: "#ff9a4d",
  cursorAccent: "#0b0c11",
  selectionBackground: "#5e5ce6",
  selectionForeground: "#e8e9ee",
  black: "#171923",
  red: "#ff6b73",
  green: "#53d68a",
  yellow: "#f3c969",
  blue: "#76a9ff",
  magenta: "#c792ea",
  cyan: "#63d6d1",
  white: "#e8e9ee",
  brightBlack: "#626879",
  brightRed: "#ff8b91",
  brightGreen: "#79e5a4",
  brightYellow: "#ffe08a",
  brightBlue: "#9fc2ff",
  brightMagenta: "#d8a8f2",
  brightCyan: "#8be8e3",
  brightWhite: "#ffffff",
};

const terminal = new Terminal({
  allowProposedApi: false,
  convertEol: false,
  cursorBlink: true,
  cursorStyle: "block",
  fontFamily: '"Maple Mono NF CN", "SFMono-Regular", Menlo, Monaco, "Noto Sans Mono CJK SC", "Glint Nerd Symbols", monospace',
  fontSize: matchMedia("(max-width: 480px)").matches ? 12 : 13,
  lineHeight: 1.16,
  scrollback: 5000,
  theme: defaultTerminalTheme,
});
const fitAddon = new FitAddon();
terminal.loadAddon(fitAddon);
terminal.open(elements.terminal);
const iosIMEInputFallback = installIOSIMEInputFallback(
  terminal,
  data => sendInputBytes(textEncoder.encode(data))
);
installIOSNativeTouchInput(terminal, text => terminal.paste(text));
installTwoFingerTerminalScrolling(terminal, elements.terminal);
document.fonts?.load('13px "Glint Nerd Symbols"').then(() => {
  terminal.refresh(0, terminal.rows - 1);
  fitTerminal();
});

let socket;
let reconnectTimer;
let reconnectDelay = 500;
const heartbeatInterval = 3000;
const serverSilenceTimeout = heartbeatInterval * 4;
let lastServerMessageAt = Date.now();
let authenticated = false;
let selectedPane = sessionStorage.getItem("glint-selected-pane") || "";
let lastState;
let token = loadToken();
// Challenge-response + encryption session. `pendingChallenge` is set when the
// server sends auth-challenge; once both `token` and `pendingChallenge` are
// present, `tryAuthenticate()` derives the keys and sends the proof. The token
// never leaves the browser — only its HMAC over the challenge does. `encrypted`
// flips true on the first binary frame the server sends back.
let pendingChallenge = null;
let c2sKey = null;
let s2cKey = null;
let sendCounter = 0;
let receiveCounter = 0;
let encrypted = false;
let paneRetryTimer;
let paneRetryCount = 0;
const paneRetryLimit = 40;
let controllingPane = "";
let resizeTimer;
let lastSentTerminalSize = "";
let appliedBrandSignature = "";
let appliedThemeSignature = "";
let fileWorkspace = "";
let filePane = "";
let fileRoot = "";
let filePaneCwd = "";
let fileRequestSequence = 0;
let fileListRequest = "";
let fileContentRequest = "";
let fileDirectory = "";
let filePath = "";
let htmlSource = "";
let htmlSourceShown = false;
const mobileSidebarLayout = matchMedia(
  "(max-width: 760px), (max-width: 900px) and (max-height: 520px) and (orientation: landscape)"
);
const autoFocusStorageKey = "glint-auto-focus-terminal";
const storedAutoFocus = localStorage.getItem(autoFocusStorageKey);
let autoFocusTerminal = storedAutoFocus === null
  ? !matchMedia("(hover: none) and (pointer: coarse)").matches
  : storedAutoFocus === "true";
elements.autoFocusTerminal.checked = autoFocusTerminal;

function loadToken() {
  const fragment = new URLSearchParams(location.hash.slice(1));
  const fromLink = fragment.get("token");
  if (fromLink) {
    sessionStorage.setItem("glint-session-token", fromLink);
    history.replaceState(null, "", `${location.pathname}${location.search}`);
    return fromLink;
  }
  return sessionStorage.getItem("glint-session-token") || "";
}

function websocketURL() {
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  const httpPort = Number(location.port || 43871);
  return `${scheme}//${location.hostname}:${httpPort + 1}/control`;
}

function connect() {
  clearTimeout(reconnectTimer);
  if (socket) {
    socket.close();
  }
  lastServerMessageAt = Date.now();
  authenticated = false;
  controllingPane = "";
  updateFilesButton();
  resetSession();
  setStatus("connecting", t("connecting"));
  socket = new WebSocket(websocketURL());
  const currentSocket = socket;
  socket.binaryType = "arraybuffer";
  socket.addEventListener("open", () => {
    lastServerMessageAt = Date.now();
    reconnectDelay = 500;
    // The server issues an auth-challenge as soon as the socket opens; we wait
    // for it rather than sending the token ourselves.
    if (!token) showAuth();
  });
  socket.addEventListener("message", event => {
    if (socket !== currentSocket) return;
    lastServerMessageAt = Date.now();
    const data = event.data;
    if (typeof data === "string") {
      handleMessage(data);        // plaintext: auth-challenge / handshake error
    } else {
      onEncryptedFrame(data);     // binary: encrypted frame
    }
  });
  socket.addEventListener("close", () => {
    if (socket !== currentSocket) return;
    authenticated = false;
    controllingPane = "";
    updateFilesButton();
    setStatus("error", t("disconnected"));
    reconnectTimer = setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 1.8, 8000);
  });
  socket.addEventListener("error", () => setStatus("error", t("unable_connect")));
}

function reconnectIfStale() {
  const stale = authenticated && Date.now() - lastServerMessageAt >= serverSilenceTimeout;
  if (!socket ||
      socket.readyState === WebSocket.CLOSING ||
      socket.readyState === WebSocket.CLOSED ||
      stale) {
    connect();
  }
}

function resetSession() {
  pendingChallenge = null;
  c2sKey = null;
  s2cKey = null;
  sendCounter = 0;
  receiveCounter = 0;
  encrypted = false;
}

/// Derive the session keys from the access key + server challenge, returning the
/// base64 HMAC proof to send. Sets c2s/s2c keys and zeroes the counters.
function deriveSession(accessKey, challengeB64) {
  const tokenKey = hexToBytes(accessKey);
  const challenge = decodeBase64(challengeB64);
  const proof = hmacSha256(
    tokenKey,
    concatBytes(textEncoder.encode(PROOF_LABEL), challenge)
  );
  const sessionKey = hkdfExtractExpand(
    tokenKey,
    challenge,
    textEncoder.encode(SESSION_INFO),
    32
  );
  c2sKey = hkdfExpand(sessionKey, textEncoder.encode(C2S_INFO), 32);
  s2cKey = hkdfExpand(sessionKey, textEncoder.encode(S2C_INFO), 32);
  sendCounter = 0;
  receiveCounter = 0;
  encrypted = false;
  return encodeBase64(proof);
}

/// Send the proof once both the access key and the challenge are known.
function tryAuthenticate() {
  if (!token || !pendingChallenge) return;
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  const proof = deriveSession(token, pendingChallenge);
  // The proof is the last plaintext frame; encryption turns on only when the
  // server's first binary reply arrives.
  send({ type: "authenticate", proof });
}

function encryptFrame(json) {
  const nonce = nonceFor(sendCounter);
  const body = aesGcmSeal(c2sKey, nonce, textEncoder.encode(json));
  const frame = new Uint8Array(nonce.length + body.length);
  frame.set(nonce, 0);
  frame.set(body, nonce.length);
  sendCounter += 1;
  return frame;
}

function decryptFrame(frame) {
  if (!s2cKey || frame.length <= 12 + 16) return null;
  const nonce = frame.subarray(0, 12);
  const body = frame.subarray(12);
  const counter = counterFromNonce(nonce);
  if (counter < receiveCounter) return null;   // replay guard
  try {
    const plain = aesGcmOpen(s2cKey, nonce, body);
    receiveCounter = counter + 1;
    return textDecoder.decode(plain);
  } catch {
    return null;
  }
}

function onEncryptedFrame(buffer) {
  const json = decryptFrame(new Uint8Array(buffer));
  if (json === null) {
    // Tamper / replay / key mismatch — drop the socket and let it reconnect.
    socket?.close();
    return;
  }
  encrypted = true;
  handleMessage(json);
}

function send(message) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  const json = JSON.stringify(message);
  if (encrypted && c2sKey) {
    socket.send(encryptFrame(json));
  } else {
    socket.send(json);
  }
}

function handleMessage(raw) {
  let message;
  try {
    message = JSON.parse(raw);
  } catch {
    return;
  }
  switch (message.type) {
    case "auth-challenge":
      pendingChallenge = message.challenge;
      tryAuthenticate();
      break;
    case "authenticated":
      authenticated = true;
      updateFilesButton();
      setStatus("connected", t("connected"));
      if (elements.authDialog.open) elements.authDialog.close();
      elements.authError.textContent = "";
      break;
    case "state":
      lastState = message;
      applyBrand(message.brand);
      applyTheme(message.theme);
      renderState(message);
      chooseInitialPane(message);
      updateFilesButton();
      if (filePane) {
        const pane = message.workspaces.find(item => item.id === fileWorkspace)
          ?.panes?.find(pane => pane.id === filePane);
        if (!pane) {
          closeFiles();
        } else if ((pane.cwd || "") !== filePaneCwd) {
          filePaneCwd = pane.cwd || "";
          fileRoot = "";
          browseFiles("");
        }
      }
      break;
    case "fileList":
      if (matchesFileResponse(message, fileListRequest, fileDirectory)
          && (!fileRoot || message.root === fileRoot)) {
        fileListRequest = "";
        fileRoot = message.root || "";
        updateFileLocation();
        renderFiles(message.entries || [], message.limit);
      }
      break;
    case "fileContent":
      if (matchesFileResponse(message, fileContentRequest, filePath) && message.root === fileRoot) {
        fileContentRequest = "";
        if (message.format === "html") {
          htmlSource = message.content;
          htmlSourceShown = false;
          elements.filesHTML.srcdoc = sandboxedHTML(message.content);
          elements.filesHTML.hidden = false;
          elements.filesContent.hidden = true;
          elements.filesSourceToggle.hidden = false;
          elements.filesSourceToggle.textContent = t("html_source");
          elements.filesMessage.textContent = t("html_preview_notice");
        } else {
          elements.filesContent.textContent = message.content;
          elements.filesMessage.textContent = "";
        }
      }
      break;
    case "fileImage":
      if (matchesFileResponse(message, fileContentRequest, filePath) && message.root === fileRoot) {
        fileContentRequest = "";
        elements.filesImage.src = `data:image/png;base64,${message.data}`;
        elements.filesImage.alt = elements.filesPreviewName.textContent;
        imageZoom.reset();
        elements.filesImageViewport.hidden = false;
        elements.filesContent.hidden = true;
        elements.filesMessage.textContent = "";
      }
      break;
    case "fileError": {
      const reading = matchesFileResponse(message, fileContentRequest, filePath);
      const listing = matchesFileResponse(message, fileListRequest, fileDirectory);
      if (!reading && !listing) break;
      if (message.code === "file-root-changed") {
        fileRoot = "";
        browseFiles("");
        break;
      }
      if (reading) {
        fileContentRequest = "";
        clearFilePreview();
      } else {
        fileListRequest = "";
        elements.filesList.replaceChildren();
      }
      elements.filesMessage.textContent = fileErrorLabel(message.code);
      break;
    }
    case "snapshot":
      if (message.pane !== selectedPane) return;
      clearTimeout(paneRetryTimer);
      paneRetryCount = 0;
      terminal.reset();
      terminal.write(decodeBase64(message.data), () => {
        controllingPane = message.pane;
        fitTerminal();
        if (autoFocusTerminal) terminal.focus();
      });
      elements.emptyState.classList.add("hidden");
      elements.terminal.classList.add("visible");
      break;
    case "output":
      if (message.pane === selectedPane) terminal.write(decodeBase64(message.data));
      break;
    case "projectCreated":
      elements.projectPath.value = "";
      elements.createDialog.close();
      selectedPane = "";
      controllingPane = "";
      updateFilesButton();
      sessionStorage.removeItem("glint-selected-pane");
      setSidebarOpen(false);
      setStatus("connected", t("project_opened"));
      break;
    case "terminalCreated":
      setStatus("connected", t("terminal_created"));
      selectPane(message.pane);
      break;
    case "terminalCloseConfirmation": {
      const pane = lastState?.workspaces
        .flatMap(workspace => workspace.panes || [])
        .find(item => item.id === message.pane);
      const name = pane?.title || "Terminal";
      if (window.confirm(t("close_terminal_confirm", { name }))) {
        send({ type: "closeTerminal", pane: message.pane, confirmed: true });
      }
      break;
    }
    case "terminalClosed":
      if (message.pane === selectedPane) {
        if (filePane === selectedPane) closeFiles();
        selectedPane = "";
        controllingPane = "";
        clearTimeout(paneRetryTimer);
        paneRetryCount = 0;
        sessionStorage.removeItem("glint-selected-pane");
        terminal.reset();
        elements.terminal.classList.remove("visible");
        elements.emptyState.classList.remove("hidden");
        elements.activeLabel.textContent = t("select_terminal");
        updateFilesButton();
      }
      setStatus("connected", t("terminal_closed"));
      break;
    case "error":
      handleError(message.code);
      break;
  }
}

function applyBrand(brand) {
  if (!brand || typeof brand.preset !== "string" ||
      typeof brand.dataURL !== "string" ||
      !brand.dataURL.startsWith("data:image/png;base64,")) return;
  if (brand.preset === appliedBrandSignature) return;
  appliedBrandSignature = brand.preset;
  elements.brandIcon.src = brand.dataURL;
  elements.brandIcon.hidden = false;
  elements.brandFallback.hidden = true;
}

function applyTheme(theme) {
  if (!theme || !Array.isArray(theme.palette) || theme.palette.length !== 16) return;
  const colors = [
    theme.background,
    theme.foreground,
    theme.cursor,
    theme.selectionBackground,
    theme.selectionForeground,
    ...theme.palette,
  ];
  if (!colors.every(color => /^#[0-9a-f]{6}$/i.test(color))) return;

  const chrome = theme.chrome || {};
  const signature = [
    theme.id,
    theme.dark,
    ...colors,
    chrome.window,
    chrome.pane,
    chrome.sidebar,
    chrome.text1,
    chrome.text3,
    chrome.text4,
    chrome.accent,
  ].join("|");
  if (signature === appliedThemeSignature) return;
  appliedThemeSignature = signature;

  const root = document.documentElement;
  root.dataset.theme = theme.dark ? "dark" : "light";
  root.style.setProperty("--bg", chrome.window || theme.background);
  root.style.setProperty("--panel", chrome.sidebar || theme.background);
  root.style.setProperty("--panel-2", chrome.pane || theme.background);
  root.style.setProperty("--terminal-bg", theme.background);
  root.style.setProperty("--text", chrome.text1 || theme.foreground);
  root.style.setProperty("--muted", chrome.text3 || theme.foreground);
  root.style.setProperty("--faint", chrome.text4 || theme.foreground);
  root.style.setProperty("--accent", chrome.accent || theme.cursor);
  root.style.setProperty("--accent-2", theme.palette[1]);

  terminal.options.theme = {
    background: theme.background,
    foreground: theme.foreground,
    cursor: theme.cursor,
    cursorAccent: theme.background,
    selectionBackground: theme.selectionBackground,
    selectionForeground: theme.selectionForeground,
    black: theme.palette[0],
    red: theme.palette[1],
    green: theme.palette[2],
    yellow: theme.palette[3],
    blue: theme.palette[4],
    magenta: theme.palette[5],
    cyan: theme.palette[6],
    white: theme.palette[7],
    brightBlack: theme.palette[8],
    brightRed: theme.palette[9],
    brightGreen: theme.palette[10],
    brightYellow: theme.palette[11],
    brightBlue: theme.palette[12],
    brightMagenta: theme.palette[13],
    brightCyan: theme.palette[14],
    brightWhite: theme.palette[15],
  };
}

function handleError(code) {
  if (code === "unauthorized") {
    authenticated = false;
    updateFilesButton();
    token = "";
    encrypted = false;          // proof failed; we're still in the handshake
    sessionStorage.removeItem("glint-session-token");
    elements.authError.textContent = t("unauthorized");
    showAuth();
    return;
  }
  if (code === "pane-not-ready" && selectedPane) {
    paneRetryCount += 1;
    if (paneRetryCount > paneRetryLimit) {
      clearTimeout(paneRetryTimer);
      setStatus("error", t("terminal_not_ready"));
      return;
    }
    clearTimeout(paneRetryTimer);
    paneRetryTimer = setTimeout(sendPaneSelection, 250);
    return;
  }
  if (code === "invalid-project-path") {
    setCreateMessage(t("invalid_project_path"), "error");
    return;
  }
  setStatus("error", errorLabel(code));
}

function errorLabel(code) {
  const labels = {
    "bad-request": t("bad_request"),
    "unknown-pane": t("unknown_pane"),
    "unknown-workspace": t("unknown_workspace"),
    "workspace-archived": t("workspace_archived"),
    "last-terminal": t("last_terminal"),
    "terminal-not-ready": t("terminal_not_ready"),
    "unknown-command": t("unknown_command"),
  };
  return labels[code] || t("operation_failed", { code });
}

function fileErrorLabel(code) {
  return t({
    "files-unavailable": "files_unavailable",
    "file-root-changed": "file_root_changed",
    "invalid-file-path": "invalid_file_path",
    "file-unavailable": "file_unavailable",
    "file-too-large": "file_too_large",
    "file-not-text": "file_not_text",
    "image-too-large": "image_too_large",
    "image-unavailable": "image_unavailable",
  }[code] || "file_unavailable");
}

function sandboxedHTML(html) {
  const policy = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; base-uri 'none'; form-action 'none'; navigate-to 'none'">`;
  const doctype = /^\s*<!doctype[^>]*>/i.exec(html);
  return doctype
    ? `${doctype[0]}${policy}${html.slice(doctype[0].length)}`
    : `${policy}${html}`;
}

function installImageZoom(viewport, image) {
  let scale = 1;
  let offsetX = 0;
  let offsetY = 0;
  let gesture = null;
  let safariGestureScale = 1;
  const maxScale = 6;
  const clamp = (value, lower, upper) => Math.min(upper, Math.max(lower, value));
  const center = touches => ({
    x: (touches[0].clientX + touches[1].clientX) / 2,
    y: (touches[0].clientY + touches[1].clientY) / 2,
  });
  const distance = touches => Math.hypot(
    touches[0].clientX - touches[1].clientX,
    touches[0].clientY - touches[1].clientY
  );

  function apply() {
    const maxX = Math.max(0, (image.offsetWidth * scale - viewport.clientWidth) / 2);
    const maxY = Math.max(0, (image.offsetHeight * scale - viewport.clientHeight) / 2);
    offsetX = clamp(offsetX, -maxX, maxX);
    offsetY = clamp(offsetY, -maxY, maxY);
    image.style.setProperty("--zoom", scale);
    image.style.setProperty("--pan-x", `${offsetX}px`);
    image.style.setProperty("--pan-y", `${offsetY}px`);
  }

  function pointFromClient(clientX, clientY) {
    const rect = viewport.getBoundingClientRect();
    return { x: clientX - rect.left - rect.width / 2,
             y: clientY - rect.top - rect.height / 2 };
  }

  function zoomAt(clientX, clientY, nextScale) {
    const point = pointFromClient(clientX, clientY);
    const ratio = nextScale / scale;
    offsetX = point.x - (point.x - offsetX) * ratio;
    offsetY = point.y - (point.y - offsetY) * ratio;
    scale = nextScale;
    apply();
  }

  function startGesture(touches) {
    if (touches.length >= 2) {
      const middle = center(touches);
      const point = pointFromClient(middle.x, middle.y);
      gesture = {
        kind: "pinch", distance: Math.max(1, distance(touches)), startScale: scale,
        imageX: (point.x - offsetX) / scale,
        imageY: (point.y - offsetY) / scale,
      };
    } else if (touches.length === 1 && scale > 1) {
      gesture = {
        kind: "pan", x: touches[0].clientX, y: touches[0].clientY,
        offsetX, offsetY,
      };
    } else {
      gesture = null;
    }
  }

  viewport.addEventListener("touchstart", event => {
    startGesture(event.touches);
    if (gesture) event.preventDefault();
  }, { passive: false });
  viewport.addEventListener("touchmove", event => {
    if (event.touches.length >= 2) {
      if (gesture?.kind !== "pinch") startGesture(event.touches);
      const middle = center(event.touches);
      const point = pointFromClient(middle.x, middle.y);
      scale = clamp(gesture.startScale * distance(event.touches) / gesture.distance, 1, maxScale);
      offsetX = point.x - gesture.imageX * scale;
      offsetY = point.y - gesture.imageY * scale;
      apply();
      event.preventDefault();
    } else if (event.touches.length === 1 && gesture?.kind === "pan") {
      offsetX = gesture.offsetX + event.touches[0].clientX - gesture.x;
      offsetY = gesture.offsetY + event.touches[0].clientY - gesture.y;
      apply();
      event.preventDefault();
    }
  }, { passive: false });
  const finishTouch = event => startGesture(event.touches);
  viewport.addEventListener("touchend", finishTouch);
  viewport.addEventListener("touchcancel", finishTouch);
  viewport.addEventListener("dblclick", () => reset());
  viewport.addEventListener("wheel", event => {
    if (!event.ctrlKey) return;
    event.preventDefault();
    zoomAt(event.clientX, event.clientY,
      clamp(scale * Math.exp(-event.deltaY * 0.01), 1, maxScale));
  }, { passive: false });
  viewport.addEventListener("gesturestart", event => {
    event.preventDefault();
    safariGestureScale = scale;
  }, { passive: false });
  viewport.addEventListener("gesturechange", event => {
    event.preventDefault();
    if (gesture?.kind === "pinch") return;
    const rect = viewport.getBoundingClientRect();
    zoomAt(event.clientX || rect.left + rect.width / 2,
      event.clientY || rect.top + rect.height / 2,
      clamp(safariGestureScale * event.scale, 1, maxScale));
  }, { passive: false });
  window.addEventListener("resize", apply);

  function reset() {
    scale = 1;
    offsetX = 0;
    offsetY = 0;
    gesture = null;
    apply();
  }
  return { reset };
}

const imageZoom = installImageZoom(elements.filesImageViewport, elements.filesImage);

function clearFilePreview() {
  htmlSource = "";
  htmlSourceShown = false;
  elements.filesContent.textContent = "";
  elements.filesContent.hidden = false;
  elements.filesImageViewport.hidden = true;
  elements.filesImage.removeAttribute("src");
  imageZoom.reset();
  elements.filesHTML.hidden = true;
  elements.filesHTML.srcdoc = "";
  elements.filesSourceToggle.hidden = true;
}

function matchesFileResponse(message, request, path) {
  return !!request && message.request === request && message.workspace === fileWorkspace
    && message.pane === filePane && message.path === path;
}

function updateFilesButton() {
  elements.openFiles.hidden = !authenticated || !selectedPane;
}

function updateFileLocation() {
  elements.filesLocation.textContent = fileRoot
    ? `${fileRoot}${fileDirectory ? `/${fileDirectory}` : ""}`
    : (fileDirectory ? `/${fileDirectory}` : "/");
}

function openFiles() {
  if (!authenticated || !selectedPane) return;
  const workspace = lastState?.workspaces.find(item =>
    item.panes?.some(pane => pane.id === selectedPane));
  if (!workspace) return;
  fileWorkspace = workspace.id;
  filePane = selectedPane;
  filePaneCwd = workspace.panes.find(pane => pane.id === selectedPane)?.cwd || "";
  fileRoot = "";
  fileDirectory = "";
  filePath = "";
  elements.filesPanel.hidden = false;
  document.querySelector(".terminal-panel").classList.add("show-files");
  elements.filesPreviewName.textContent = "";
  clearFilePreview();
  elements.filesMessage.textContent = t("files_choose");
  browseFiles("");
  if (mobileSidebarLayout.matches) setSidebarOpen(false);
}

function closeFiles() {
  fileWorkspace = "";
  filePane = "";
  fileRoot = "";
  filePaneCwd = "";
  fileListRequest = "";
  fileContentRequest = "";
  filePath = "";
  clearFilePreview();
  elements.filesPanel.hidden = true;
  document.querySelector(".terminal-panel").classList.remove("show-files");
  fitTerminal();
}

function browseFiles(path) {
  fileDirectory = path;
  filePath = "";
  fileContentRequest = "";
  fileListRequest = String(++fileRequestSequence);
  updateFileLocation();
  elements.filesUp.disabled = !path;
  elements.filesList.replaceChildren();
  elements.filesPreviewName.textContent = "";
  clearFilePreview();
  elements.filesMessage.textContent = t("files_loading");
  send({ type: "listFiles", workspace: fileWorkspace, pane: filePane, path, root: fileRoot, request: fileListRequest });
}

function renderFiles(entries, limit) {
  elements.filesList.replaceChildren();
  for (const entry of entries) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "file-entry";
    button.disabled = entry.kind === "link";
    button.textContent = `${entry.kind === "directory" ? "▸" : entry.kind === "link" ? "↗" : "▤"}  ${entry.name}`;
    button.addEventListener("click", () => {
      const path = fileDirectory ? `${fileDirectory}/${entry.name}` : entry.name;
      if (entry.kind === "directory") {
        browseFiles(path);
      } else {
        filePath = path;
        elements.filesPreviewName.textContent = entry.name;
        clearFilePreview();
        elements.filesMessage.textContent = t("files_loading");
        fileContentRequest = String(++fileRequestSequence);
        send({ type: "readFile", workspace: fileWorkspace, pane: filePane, path, root: fileRoot, request: fileContentRequest });
      }
    });
    elements.filesList.append(button);
  }
  elements.filesMessage.textContent = entries.length ? t("files_choose") : t("files_empty");
  if (entries.length >= limit) {
    const note = document.createElement("p");
    note.className = "files-list-note";
    note.textContent = t("files_limited");
    elements.filesList.append(note);
  }
}

function chooseInitialPane(state) {
  const panes = state.workspaces.flatMap(workspace => workspace.panes || []);
  const remembered = panes.find(pane => pane.id === selectedPane);
  const preferred = remembered || panes.find(pane => pane.selected) || panes[0];
  if (preferred && preferred.id !== selectedPane) {
    selectPane(preferred.id);
  } else if (preferred && controllingPane !== preferred.id) {
    selectPane(preferred.id);
  }
}

function renderState(state) {
  elements.workspaceList.replaceChildren();
  for (const workspace of state.workspaces) {
    const panes = workspace.panes || [];
    const group = document.createElement("div");
    group.className = "workspace-group";

    const title = document.createElement("div");
    title.className = "workspace-title";
    const color = document.createElement("span");
    color.className = "workspace-color";
    color.style.backgroundColor = `#${workspace.accent}`;
    const name = document.createElement("span");
    name.textContent = workspace.name;
    const count = document.createElement("span");
    count.className = "terminal-count";
    count.textContent = String(panes.length);
    count.title = t("terminal_count", { count: panes.length });
    title.append(color, name, count);
    if (workspace.archived) {
      const archived = document.createElement("span");
      archived.className = "archived";
      archived.textContent = "ARCHIVED";
      title.append(archived);
    } else {
      const addTerminal = document.createElement("button");
      addTerminal.type = "button";
      addTerminal.className = "workspace-new-terminal";
      addTerminal.textContent = "+";
      addTerminal.title = t("workspace_new_terminal");
      addTerminal.setAttribute("aria-label", t("workspace_new_terminal_aria", { name: workspace.name }));
      addTerminal.addEventListener("click", () => {
        setStatus("connecting", t("create_terminal"));
        send({ type: "createTerminal", workspace: workspace.id });
      });
      title.append(addTerminal);
    }
    group.append(title);

    const paneList = document.createElement("div");
    paneList.className = "workspace-pane-list";
    for (const pane of panes) {
      const row = document.createElement("div");
      row.className = "pane-row";
      const button = document.createElement("button");
      button.type = "button";
      button.className = `pane-button${pane.id === selectedPane ? " active" : ""}`;
      button.addEventListener("click", () => selectPane(pane.id));

      const icon = document.createElement("span");
      icon.className = "pane-icon";
      icon.textContent = ">_";
      const copy = document.createElement("span");
      copy.className = "pane-copy";
      const paneTitle = document.createElement("strong");
      paneTitle.textContent = pane.title || "Terminal";
      const cwd = document.createElement("span");
      cwd.textContent = pane.cwd || (pane.ready ? t("terminal_ready") : t("waiting_terminal"));
      copy.append(paneTitle, cwd);
      button.append(icon, copy);
      if (pane.agent) {
        const badge = document.createElement("span");
        badge.className = "agent-badge";
        badge.textContent = pane.agent;
        button.append(badge);
      }
      const closeButton = document.createElement("button");
      closeButton.type = "button";
      closeButton.className = "pane-close-terminal";
      closeButton.textContent = "×";
      closeButton.title = t("close_terminal");
      closeButton.setAttribute(
        "aria-label",
        t("close_terminal_aria", { name: pane.title || "Terminal" })
      );
      closeButton.addEventListener("click", () => {
        send({ type: "closeTerminal", pane: pane.id, confirmed: false });
      });
      row.append(button, closeButton);
      paneList.append(row);
    }
    group.append(paneList);
    elements.workspaceList.append(group);
  }
}

function selectPane(pane) {
  if (filePane) closeFiles();
  selectedPane = pane;
  updateFilesButton();
  controllingPane = "";
  clearTimeout(paneRetryTimer);
  paneRetryCount = 0;
  sessionStorage.setItem("glint-selected-pane", pane);
  if (lastState) {
    const workspace = lastState.workspaces.find(item => item.panes?.some(value => value.id === pane));
    const selected = workspace?.panes.find(value => value.id === pane);
    elements.activeLabel.textContent = workspace
      ? `${workspace.name} · ${selected?.title || "Terminal"}`
      : t("loading_terminal");
    renderState(lastState);
  }
  elements.emptyState.classList.add("hidden");
  elements.terminal.classList.add("visible");
  terminal.reset();
  terminal.write(`\x1b[2m${t("syncing_terminal")}\x1b[0m`);
  sendPaneSelection();
  if (mobileSidebarLayout.matches) setSidebarOpen(false);
}

function sendPaneSelection() {
  if (!selectedPane) return;
  fitTerminal(false);
  const size = terminalSize();
  lastSentTerminalSize = `${size.columns}x${size.rows}`;
  send({ type: "select", pane: selectedPane, columns: size.columns, rows: size.rows });
}

function sendInputBytes(bytes) {
  if (!authenticated || !selectedPane || !bytes.length) return;
  send({ type: "input", pane: selectedPane, data: encodeBase64(bytes) });
}

terminal.onData(data => {
  iosIMEInputFallback?.noteTerminalData(data);
  sendInputBytes(textEncoder.encode(data));
});
terminal.onBinary(data => {
  const bytes = Uint8Array.from(data, character => character.charCodeAt(0) & 0xff);
  sendInputBytes(bytes);
});

elements.createProject.addEventListener("click", () => {
  setCreateMessage(t("existing_directory_hint"), "");
  elements.createDialog.showModal();
  requestAnimationFrame(() => elements.projectPath.focus());
});
elements.createClose.addEventListener("click", () => elements.createDialog.close());

elements.createForm.addEventListener("submit", event => {
  event.preventDefault();
  const path = elements.projectPath.value.trim();
  if (!path) return;
  setCreateMessage(t("opening_project"), "");
  send({ type: "createProject", path });
});

elements.authForm.addEventListener("submit", event => {
  event.preventDefault();
  token = elements.tokenInput.value.trim();
  if (!token) return;
  sessionStorage.setItem("glint-session-token", token);
  elements.authError.textContent = "";
  if (socket?.readyState === WebSocket.OPEN) {
    // Challenge may already be in hand; otherwise tryAuthenticate waits for it.
    tryAuthenticate();
  } else {
    connect();
  }
});

elements.reconnect.addEventListener("click", connect);
elements.refresh.addEventListener("click", () => send({ type: "list" }));
elements.openFiles.addEventListener("click", openFiles);
elements.filesUp.addEventListener("click", () => {
  browseFiles(fileDirectory.split("/").slice(0, -1).join("/"));
});
elements.filesRefresh.addEventListener("click", () => browseFiles(fileDirectory));
elements.filesClose.addEventListener("click", closeFiles);
elements.filesSourceToggle.addEventListener("click", () => {
  htmlSourceShown = !htmlSourceShown;
  elements.filesContent.textContent = htmlSource;
  elements.filesContent.hidden = !htmlSourceShown;
  elements.filesHTML.hidden = htmlSourceShown;
  elements.filesSourceToggle.textContent = t(htmlSourceShown ? "html_preview" : "html_source");
  elements.filesMessage.textContent = htmlSourceShown ? "" : t("html_preview_notice");
});
elements.filesHTML.title = t("html_preview");
[ ["filesUp", "files_up"], ["filesRefresh", "files_refresh"], ["filesClose", "files_close"] ]
  .forEach(([element, label]) => elements[element].setAttribute("aria-label", t(label)));
elements.autoFocusTerminal.addEventListener("change", () => {
  autoFocusTerminal = elements.autoFocusTerminal.checked;
  localStorage.setItem(autoFocusStorageKey, String(autoFocusTerminal));
});
elements.sidebarToggle.addEventListener("click", () => setSidebarOpen(true));
elements.sidebarClose.addEventListener("click", () => setSidebarOpen(false));
elements.sidebarBackdrop.addEventListener("click", () => setSidebarOpen(false));
mobileSidebarLayout.addEventListener("change", event => {
  if (!event.matches) setSidebarOpen(false);
});
document.addEventListener("keydown", event => {
  if (event.key === "Escape" && elements.sidebar.classList.contains("open")) {
    setSidebarOpen(false);
  }
});
setSidebarOpen(false);
document.querySelectorAll("[data-input]").forEach(button => {
  button.addEventListener("pointerdown", event => event.preventDefault());
  button.addEventListener("click", () => {
    terminal.focus();
    const hex = button.dataset.input;
    const bytes = new Uint8Array(hex.match(/.{2}/g).map(value => Number.parseInt(value, 16)));
    sendInputBytes(bytes);
    requestAnimationFrame(() => terminal.focus());
  });
});

function showAuth() {
  if (!elements.authDialog.open) elements.authDialog.showModal();
  elements.tokenInput.value = "";
  setTimeout(() => elements.tokenInput.focus(), 0);
}

function setStatus(state, text) {
  elements.statusDot.className = `status-dot ${state}`;
  elements.statusText.textContent = text;
}

function setCreateMessage(text, tone) {
  elements.createMessage.className = `form-message ${tone}`.trim();
  elements.createMessage.textContent = text;
}

function setSidebarOpen(open) {
  elements.sidebar.classList.toggle("open", open);
  elements.sidebarBackdrop.classList.toggle("open", open);
  elements.sidebarToggle.setAttribute("aria-expanded", String(open));
  const hidden = mobileSidebarLayout.matches && !open;
  elements.sidebar.inert = hidden;
  elements.sidebar.setAttribute("aria-hidden", String(hidden));
}

function terminalSize() {
  return { columns: terminal.cols, rows: terminal.rows };
}

function fitTerminal(notifyRemote = true) {
  if (!elements.terminal.classList.contains("visible")) return;
  try { fitAddon.fit(); } catch { /* Layout can be between mobile rotations. */ }
  if (notifyRemote) scheduleTerminalResize();
}

function scheduleTerminalResize() {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    if (!authenticated || controllingPane !== selectedPane) return;
    const size = terminalSize();
    const key = `${size.columns}x${size.rows}`;
    if (key === lastSentTerminalSize) return;
    lastSentTerminalSize = key;
    send({
      type: "resize",
      pane: selectedPane,
      columns: size.columns,
      rows: size.rows,
    });
  }, 120);
}

function syncVisualViewport() {
  const viewport = window.visualViewport;
  const height = Math.max(1, Math.round(viewport?.height || window.innerHeight));
  const offsetTop = Math.max(0, Math.round(viewport?.offsetTop || 0));
  document.documentElement.style.setProperty("--visual-viewport-height", `${height}px`);
  document.documentElement.style.setProperty("--visual-viewport-offset-top", `${offsetTop}px`);
}

function decodeBase64(value) {
  const binary = atob(value);
  return Uint8Array.from(binary, character => character.charCodeAt(0));
}

function encodeBase64(bytes) {
  let binary = "";
  const chunkSize = 8192;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  return btoa(binary);
}

window.addEventListener("resize", syncVisualViewport);
window.addEventListener("online", connect);
window.addEventListener("pageshow", reconnectIfStale);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") reconnectIfStale();
});
window.visualViewport?.addEventListener("resize", syncVisualViewport);
window.visualViewport?.addEventListener("scroll", syncVisualViewport);
new ResizeObserver(fitTerminal).observe(elements.terminal);
syncVisualViewport();
setInterval(() => {
  if (!authenticated) return;
  if (Date.now() - lastServerMessageAt >= serverSilenceTimeout) {
    connect();
    return;
  }
  send({ type: "list" });
}, heartbeatInterval);

connect();
