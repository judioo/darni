// The reader view's page scripts in a real Chromium, with nothing on screen
// (docs/FEATURE-SPECS/READER-VIEW.md §10). Run through check-reader-engine.sh.
//
// It serves the reader fixture's pages on 127.0.0.1, starts the engine out
// dir's Chromium headless on a scratch profile that can reach loopback only,
// and, over the DevTools protocol, does what the engine bridge does for
// ReArcTabEvaluateScript with world 0: evaluates the script in an isolated
// world of the page. It checks the answers, that the page's own world and
// document are untouched, and writes the raw answers for the Swift side to
// sanitise (ReaderEngineAnswerTests).
//
// usage: node check-reader-engine.mjs --chromium <binary> --fixtures <dir> --profile <dir> --out <dir>

import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, index, all) => {
  if (value.startsWith("--")) pairs.push([value.slice(2), all[index + 1]]);
  return pairs;
}, []));
for (const name of ["chromium", "fixtures", "profile", "out"]) {
  if (!args[name]) { console.error(`missing --${name}`); process.exit(2); }
}
const fixture = (name) => readFileSync(join(args.fixtures, name));
const pages = { "/reader/article": "article.html", "/reader/plain": "plain.html", "/reader/hostile": "hostile.html",
                "/reader/picture-article": "picture-article.html" };
const pictureRequests = {};
const beacons = {};
let failures = 0;
function check(ok, what) {
  console.log(`${ok ? "PASS" : "FAIL"} ${what}`);
  if (!ok) failures += 1;
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const server = createServer((request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  if (url.pathname === "/reader/beacon") {
    const id = url.searchParams.get("id") ?? "unnamed";
    beacons[id] = (beacons[id] ?? 0) + 1;
    response.writeHead(200, { "Content-Type": "image/gif", "Cache-Control": "no-store" });
    return response.end(Buffer.from("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7", "base64"));
  }
  // The <picture> article's images, counted: the check below says which were asked for.
  const pictureArticleImage = url.pathname.startsWith("/reader/picture-") && url.pathname.endsWith(".png");
  if (pictureArticleImage) pictureRequests[url.pathname] = (pictureRequests[url.pathname] ?? 0) + 1;
  if (url.pathname === "/reader/picture.png" || pictureArticleImage) {
    response.writeHead(200, { "Content-Type": "image/png", "Cache-Control": "no-store" });
    return response.end(fixture("picture.png"));
  }
  if (pages[url.pathname]) {
    response.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
    return response.end(fixture(pages[url.pathname]));
  }
  response.writeHead(404, { "Content-Type": "text/plain" });
  response.end("not found");
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const base = `http://127.0.0.1:${server.address().port}`;

mkdirSync(args.profile, { recursive: true });
mkdirSync(args.out, { recursive: true });
const browser = spawn(args.chromium, [
  "--headless=new", `--user-data-dir=${args.profile}`, "--no-first-run", "--no-default-browser-check", "--use-mock-keychain",
  "--remote-debugging-port=0", "--remote-allow-origins=*", "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
  "--disable-background-networking", "--disable-component-update", "--disable-sync", "about:blank",
], { stdio: "ignore", env: { ...process.env, BREAKPAD_DUMP_LOCATION: join(args.profile, "crashes") } });
let exitCode = 1;
try {
  const portFile = join(args.profile, "DevToolsActivePort");
  for (let i = 0; i < 300 && !existsSync(portFile); i++) await sleep(100);
  if (!existsSync(portFile)) throw new Error("Chromium did not open its DevTools port");
  const port = readFileSync(portFile, "utf8").split("\n")[0].trim();
  const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
  console.log(`engine: ${version.Browser}`);
  let targets = [];
  for (let i = 0; i < 50 && !targets.some((t) => t.type === "page"); i++) {
    targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    await sleep(100);
  }
  const socket = new WebSocket(targets.find((t) => t.type === "page").webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  let nextID = 1;
  const pending = new Map();
  const waiters = [];
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id);
      pending.delete(message.id);
      return message.error ? reject(new Error(JSON.stringify(message.error))) : resolve(message.result);
    }
    for (const waiter of [...waiters]) {
      if (waiter.method === message.method) { waiters.splice(waiters.indexOf(waiter), 1); waiter.resolve(message.params); }
    }
  };
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = nextID++;
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });
  const event = (method) => new Promise((resolve) => waiters.push({ method, resolve }));
  await send("Page.enable");
  await send("Runtime.enable");

  async function load(path) {
    const loaded = event("Page.loadEventFired");
    await send("Page.navigate", { url: base + path });
    await loaded;
    await sleep(700);
  }
  // As the bridge does: an isolated world of the main frame, evaluated by context id.
  async function isolated(expression) {
    const tree = await send("Page.getFrameTree");
    const world = await send("Page.createIsolatedWorld", { frameId: tree.frameTree.frame.id, worldName: "rearc.boost.check.reader" });
    const result = await send("Runtime.evaluate", { expression, contextId: world.executionContextId, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error("the script threw: " + JSON.stringify(result.exceptionDetails).slice(0, 600));
    return result.result.value;
  }
  async function page(expression) {
    const result = await send("Runtime.evaluate", { expression, returnByValue: true });
    return result.result.value;
  }
  const detection = fixture("detection.js").toString("utf8");
  const extraction = fixture("extraction.js").toString("utf8");
  const names = (node, into = new Set()) => {
    if (node && typeof node === "object") { into.add((node.ns ? "foreign " : "") + node.t); (node.c ?? []).forEach((c) => names(c, into)); }
    return into;
  };

  await load("/reader/article");
  const before = await page("document.documentElement.outerHTML");
  check(JSON.parse(await isolated(detection)).article === true, "the article is judged an article");
  const articleText = await isolated(extraction);
  check(typeof articleText === "string", "the extraction script answers with text");
  const article = JSON.parse(articleText);
  check(article.ok === true && article.title === "The Keeper of Skerry Light" && article.byline === "Marit Halvorsen" && article.siteName === "The Coastal Review",
        `title, byline and site: ${article.title} / ${article.byline} / ${article.siteName}`);
  const found = names(article.content);
  check(["p", "h2", "blockquote", "ul", "li", "table", "tr", "td", "pre", "code", "figure", "img", "figcaption", "a"].every((n) => found.has(n)),
        `the article's structure came across: ${[...found].sort().join(" ")}`);
  check(Array.isArray(article.loaded) && article.loaded.includes(base + "/reader/picture.png"), `the page's loaded picture is listed: ${JSON.stringify(article.loaded)}`);
  check(await page("typeof Readability + '/' + typeof isProbablyReaderable + '/' + typeof walk + '/' + typeof module") === "undefined/undefined/undefined/undefined",
        "nothing of the scripts is in the page's own world");
  check(await page("document.documentElement.outerHTML") === before, "the page's document is unchanged");
  writeFileSync(join(args.out, "article.json"), JSON.stringify({ url: base + "/reader/article", answer: articleText }));

  await load("/reader/plain");
  check(JSON.parse(await isolated(detection)).article === false, "the page that is no article is judged not one");

  await load("/reader/hostile");
  check((beacons["body-script"] ?? 0) > 0 && (beacons["img-onerror"] ?? 0) > 0 && (beacons["body-onload"] ?? 0) > 0,
        `the hostile page's payloads are live in the page itself: ${JSON.stringify(beacons)}`);
  const settled = JSON.stringify(beacons);
  const hostileText = await isolated(extraction);
  const hostile = JSON.parse(hostileText);
  check(hostile.ok === true && JSON.stringify(hostile.content).includes("harbour-text-survives"), "the hostile article is extracted");
  await sleep(1200);
  check(JSON.stringify(beacons) === settled, "extraction made the page ask for nothing (the copy of the document loads and runs nothing)");
  writeFileSync(join(args.out, "hostile.json"), JSON.stringify({ url: base + "/reader/hostile", answer: hostileText }));
  // A <picture>: the page shows its second <source>; the first and the <img>'s own src are never loaded.
  await load("/reader/picture-article");
  const pictureText = await isolated(extraction);
  const pictured = JSON.parse(pictureText);
  const shownImages = [];
  const findImages = (node) => {
    if (node && typeof node === "object") { if (node.t === "img") shownImages.push(node); (node.c ?? []).forEach(findImages); }
  };
  findImages(pictured.content);
  check(pictured.ok === true && shownImages.length === 1 && typeof shownImages[0].cs === "string"
        && shownImages[0].cs.startsWith(base + "/reader/picture-shown.png") && pictured.loaded.includes(shownImages[0].cs),
        `the <picture>'s image carries the URL the page showed: ${JSON.stringify(shownImages)} loaded ${JSON.stringify(pictured.loaded)}`);
  check(!pictureRequests["/reader/picture-unused-source.png"] && !pictureRequests["/reader/picture-fallback.png"],
        `the page asked for no other source: ${JSON.stringify(pictureRequests)}`);
  writeFileSync(join(args.out, "picture.json"), JSON.stringify({ url: base + "/reader/picture-article", answer: pictureText }));

  socket.close();
  exitCode = failures === 0 ? 0 : 1;
} catch (error) {
  console.log(`FAIL ${error.message}`);
} finally {
  browser.kill("SIGTERM");
  server.close();
}
console.log(failures === 0 && exitCode === 0 ? "check-reader-engine: all passed" : "check-reader-engine: FAILED");
process.exit(exitCode);
