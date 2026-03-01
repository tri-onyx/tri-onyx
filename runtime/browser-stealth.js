// Browser stealth patches — injected as an initScript before any page
// scripts execute.  Hides common headless/automation signals that bot
// detectors check for.

(() => {
  // ---- navigator.plugins ------------------------------------------------
  // Headless Chromium ships with an empty plugin array.  Inject the three
  // plugins a regular desktop Chrome exposes.

  const pluginData = [
    {
      name: "PDF Viewer",
      description: "Portable Document Format",
      filename: "internal-pdf-viewer",
      mimeTypes: [
        { type: "application/pdf", suffixes: "pdf", description: "Portable Document Format" },
      ],
    },
    {
      name: "Chrome PDF Viewer",
      description: "Portable Document Format",
      filename: "internal-pdf-viewer",
      mimeTypes: [
        { type: "application/pdf", suffixes: "pdf", description: "Portable Document Format" },
      ],
    },
    {
      name: "Chromium PDF Viewer",
      description: "Portable Document Format",
      filename: "internal-pdf-viewer",
      mimeTypes: [
        { type: "application/pdf", suffixes: "pdf", description: "Portable Document Format" },
      ],
    },
  ];

  const makeMimeType = (mt) => {
    const obj = Object.create(MimeType.prototype);
    Object.defineProperties(obj, {
      type:        { get: () => mt.type },
      suffixes:    { get: () => mt.suffixes },
      description: { get: () => mt.description },
      enabledPlugin: { get: () => null },
    });
    return obj;
  };

  const makePlugin = (p) => {
    const mimes = p.mimeTypes.map(makeMimeType);
    const obj = Object.create(Plugin.prototype);
    Object.defineProperties(obj, {
      name:        { get: () => p.name },
      description: { get: () => p.description },
      filename:    { get: () => p.filename },
      length:      { get: () => mimes.length },
    });
    mimes.forEach((m, i) => {
      Object.defineProperty(obj, i, { get: () => m });
    });
    obj.item = (index) => mimes[index] || null;
    obj.namedItem = (name) => mimes.find((m) => m.type === name) || null;
    return obj;
  };

  const fakePlugins = pluginData.map(makePlugin);
  const pluginArray = Object.create(PluginArray.prototype);
  fakePlugins.forEach((p, i) => {
    Object.defineProperty(pluginArray, i, { get: () => p });
    Object.defineProperty(pluginArray, p.name, { get: () => p });
  });
  Object.defineProperty(pluginArray, "length", { get: () => fakePlugins.length });
  pluginArray.item = (index) => fakePlugins[index] || null;
  pluginArray.namedItem = (name) => fakePlugins.find((p) => p.name === name) || null;
  pluginArray.refresh = () => {};

  Object.defineProperty(navigator, "plugins", { get: () => pluginArray });

  // ---- window.chrome ----------------------------------------------------
  // Headless Chromium omits the `window.chrome` object that real Chrome has.

  if (!window.chrome) {
    window.chrome = {};
  }
  if (!window.chrome.runtime) {
    window.chrome.runtime = {
      connect: () => {},
      sendMessage: () => {},
      onMessage: { addListener: () => {}, removeListener: () => {} },
    };
  }
  if (!window.chrome.loadTimes) {
    window.chrome.loadTimes = () => ({
      commitLoadTime: Date.now() / 1000,
      connectionInfo: "h2",
      finishDocumentLoadTime: Date.now() / 1000,
      finishLoadTime: Date.now() / 1000,
      firstPaintAfterLoadTime: 0,
      firstPaintTime: Date.now() / 1000,
      navigationType: "Other",
      npnNegotiatedProtocol: "h2",
      requestTime: Date.now() / 1000 - 0.3,
      startLoadTime: Date.now() / 1000 - 0.3,
      wasAlternateProtocolAvailable: false,
      wasFetchedViaSpdy: true,
      wasNpnNegotiated: true,
    });
  }
  if (!window.chrome.csi) {
    window.chrome.csi = () => ({
      onloadT: Date.now(),
      pageT: Date.now() - performance.timing.navigationStart,
      startE: performance.timing.navigationStart,
      tpidr: 0,
    });
  }

  // ---- navigator.permissions.query --------------------------------------
  // Fix notification permission to return "default" instead of throwing.

  const originalQuery = navigator.permissions.query.bind(navigator.permissions);
  navigator.permissions.query = (parameters) => {
    if (parameters.name === "notifications") {
      return Promise.resolve({ state: Notification.permission });
    }
    return originalQuery(parameters);
  };

  // ---- Hardware fingerprint ---------------------------------------------
  // Headless defaults to 0 or 1 for these; real browsers report actual hw.

  Object.defineProperty(navigator, "hardwareConcurrency", { get: () => 4 });
  Object.defineProperty(navigator, "deviceMemory", { get: () => 8 });

  // ---- Function.prototype.toString masking ------------------------------
  // Bot detectors call toString() on patched functions expecting
  // "function <name>() { [native code] }".  Wrap toString to lie for any
  // function we've replaced.

  const patchedFns = new Set([
    navigator.permissions.query,
    ...(window.chrome.loadTimes ? [window.chrome.loadTimes] : []),
    ...(window.chrome.csi ? [window.chrome.csi] : []),
  ]);

  const originalToString = Function.prototype.toString;
  Function.prototype.toString = function () {
    if (patchedFns.has(this)) {
      return `function ${this.name || ""}() { [native code] }`;
    }
    return originalToString.call(this);
  };
  // Hide our toString patch itself.
  patchedFns.add(Function.prototype.toString);
})();
