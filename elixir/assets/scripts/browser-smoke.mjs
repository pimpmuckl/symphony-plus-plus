#!/usr/bin/env node
/* global console, process */
import { existsSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";

const args = process.argv.slice(2);
const url = option("url") || process.env.BROWSER_SMOKE_URL || "http://127.0.0.1:5173";
const outputDir = path.resolve(option("output-dir") || "output/playwright");
const screenshot = path.join(outputDir, "browser-smoke.png");
const headless = !flag("headed");
const errors = [];
const failures = [];

await mkdir(outputDir, { recursive: true });

const browser = await launchBrowser();

try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("requestfailed", (request) => recordFailure(`${request.method()} ${request.url()} ${request.failure()?.errorText || ""}`));
  page.on("response", (response) => {
    if (isFailedAppResponse(response)) recordFailure(`${response.status()} ${response.url()}`);
  });

  const mainResponse = await page.goto(url, { waitUntil: "domcontentloaded", timeout: 30_000 });
  if (mainResponse && !mainResponse.ok()) recordFailure(`${mainResponse.status()} ${mainResponse.url()}`);
  await page.waitForLoadState("networkidle", { timeout: 5_000 }).catch(() => {});
  await page.locator("body").waitFor({ timeout: 10_000 });

  const title = await page.title();
  const bodyText = (await page.locator("body").innerText()).trim();
  if (!bodyText) errors.push("Page body is empty");

  await page.screenshot({ path: screenshot, fullPage: true });
  finish({ title });
} finally {
  await browser.close();
}

async function launchBrowser() {
  const executablePath = browserExecutablePath();
  return chromium.launch({
    headless,
    ...(executablePath ? { executablePath } : {}),
  });
}

function finish({ title }) {
  const result = { url, title, screenshot, errors, failures };

  if (errors.length || failures.length) {
    console.error(JSON.stringify(result, null, 2));
    process.exitCode = 1;
    return;
  }

  console.log(JSON.stringify({ ok: true, url, title, screenshot }, null, 2));
}

function isFailedAppResponse(response) {
  if (response.status() < 400) return false;

  const appResourceTypes = new Set(["document", "script", "stylesheet", "fetch", "xhr"]);
  return appResourceTypes.has(response.request().resourceType());
}

function recordFailure(message) {
  if (!failures.includes(message)) failures.push(message);
}

function option(name) {
  const key = `--${name}`;
  const valueIndex = args.indexOf(key);
  if (valueIndex !== -1) return args[valueIndex + 1];

  const prefix = `${key}=`;
  return args.find((arg) => arg.startsWith(prefix))?.slice(prefix.length);
}

function flag(name) {
  return args.includes(`--${name}`);
}

function browserExecutablePath() {
  const explicit = option("browser") || process.env.PLAYWRIGHT_BROWSER_PATH;
  if (explicit) return explicit;

  return browserCandidates().find((candidate) => existsSync(candidate));
}

function browserCandidates() {
  switch (os.platform()) {
    case "win32":
      return [
        "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
        "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
        "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
        "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
      ];
    case "darwin":
      return [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
      ];
    default:
      return ["/usr/bin/google-chrome", "/usr/bin/google-chrome-stable", "/usr/bin/chromium", "/usr/bin/chromium-browser", "/snap/bin/chromium"];
  }
}
