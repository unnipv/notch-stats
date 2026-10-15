#!/usr/bin/env node
// NotchStats installer / launcher.
//
//   bunx notch-stats
//   npx notch-stats
//
// Downloads the latest release .app, installs it to /Applications and opens it.

const { execFileSync } = require("node:child_process");
const { mkdtempSync, rmSync, existsSync, cpSync } = require("node:fs");
const { tmpdir, homedir } = require("node:os");
const { join } = require("node:path");

const REPO = process.env.NOTCHSTATS_REPO || "unnipv/notch-stats";
const APP_NAME = "NotchStats";
const ASSET = `${APP_NAME}.zip`;

const say = (message) => console.log(`\x1b[1;36m==>\x1b[0m ${message}`);
const die = (message) => {
  console.error(`\x1b[1;31merror:\x1b[0m ${message}`);
  process.exit(1);
};

async function main() {
  if (process.platform !== "darwin") die("NotchStats is macOS only.");

  say(`Finding the latest release of ${REPO}`);
  const response = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
    headers: { "User-Agent": "notch-stats-cli" },
  });
  if (!response.ok) die(`GitHub API returned ${response.status}`);
  const release = await response.json();

  const asset = (release.assets || []).find((item) => item.name === ASSET);
  if (!asset) die(`No ${ASSET} asset in the latest release.`);

  const work = mkdtempSync(join(tmpdir(), "notch-stats-"));
  try {
    say(`Downloading ${ASSET}`);
    const download = await fetch(asset.browser_download_url);
    if (!download.ok) die(`Download failed: ${download.status}`);
    const archive = join(work, ASSET);
    cpSync(Buffer.from(await download.arrayBuffer()), archive);

    say("Unpacking");
    const unpacked = join(work, "unpacked");
    execFileSync("ditto", ["-x", "-k", archive, unpacked]);

    const source = join(unpacked, `${APP_NAME}.app`);
    if (!existsSync(source)) die(`Could not find ${APP_NAME}.app in the archive.`);

    const preferred = "/Applications";
    const destination = isWritable(preferred) ? preferred : join(homedir(), "Applications");
    const target = join(destination, `${APP_NAME}.app`);

    say(`Installing to ${destination}`);
    rmSync(target, { recursive: true, force: true });
    cpSync(source, target, { recursive: true });

    execFileSync("xattr", ["-dr", "com.apple.quarantine", target], { stdio: "ignore" });

    say("Launching");
    execFileSync("open", [target]);
    say("Installed. Look for the pill in your notch.");
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

function isWritable(directory) {
  try {
    require("node:fs").accessSync(directory, require("node:fs").constants.W_OK);
    return true;
  } catch {
    return false;
  }
}

main().catch((error) => die(error.message));
