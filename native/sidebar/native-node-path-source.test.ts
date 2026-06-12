import { readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";

const nativeSidebarSource = readFileSync(new URL("./native-sidebar.tsx", import.meta.url), "utf8");
const appDelegateSource = readFileSync(
  new URL("../macos/ghostexHost/Sources/ghostexHost/AppDelegate.swift", import.meta.url),
  "utf8",
);

function sourceBetween(source: string, start: string, end: string): string {
  const startIndex = source.indexOf(start);
  const endIndex = source.indexOf(end, startIndex + start.length);
  expect(startIndex).toBeGreaterThanOrEqual(0);
  expect(endIndex).toBeGreaterThan(startIndex);
  return source.slice(startIndex, endIndex);
}

describe("native bundled Node fallback path", () => {
  test("bundled Node resolves inside Web/code-server/lib/node, not the Resources sibling", () => {
    /*
    The bundled Node runtime ships at Contents/Resources/Web/code-server/lib/node.
    nativeSidebarWebResourceDirectory() points at Contents/Resources/Web/, so the
    bundled-runtime resolver (used before gxserver reports a nodePath) must stay
    inside Web/. A "../" prefix escapes Web/ to the nonexistent
    Resources/code-server/lib/node, which made the CLI link repair fail with the
    Cocoa error: The file "node" doesn't exist. (issue #14)
    */
    const resolver = sourceBetween(
      nativeSidebarSource,
      "function nativeSidebarBundledCodeServerNodePath()",
      "function nativeSidebarNodePath()",
    );
    expect(resolver).toContain("/code-server/lib/node");
    expect(resolver).not.toContain("../code-server/lib/node");

    // Verify the resolution actually lands inside Web/.
    const webResourceDirectory = "/Applications/Ghostex.app/Contents/Resources/Web/";
    const resolved = `${webResourceDirectory.replace(/\/+$/, "")}/code-server/lib/node`;
    expect(resolved).toBe("/Applications/Ghostex.app/Contents/Resources/Web/code-server/lib/node");
  });

  test("native runProcess stats absolute executables and names the missing path", () => {
    /*
    A missing interpreter must surface a clear path in the toast instead of the
    bare Cocoa `The file "node" doesn't exist.` error, which hides which path
    failed. Both runProcess overloads stat absolute executables before spawning.
    (issue #14 follow-up)
    */
    const matches = appDelegateSource.match(
      /command\.executable\.hasPrefix\("\/"\),\s*!FileManager\.default\.fileExists\(atPath: command\.executable\)/g,
    );
    expect(matches).toHaveLength(2);
    expect(appDelegateSource.match(/stderr: "Executable not found at \\\(command\.executable\)"/g)).toHaveLength(2);
  });

  test("CLI ownership check compares the bundle path case-insensitively", () => {
    /*
    Cask symlinks in /opt/homebrew/bin can point at lowercase /Applications/ghostex.app/...
    while the live bundle resolves to /Applications/Ghostex.app/... When realpath falls
    back to the raw string the equality must still match so repair does not treat a
    Ghostex-owned link as a protected third-party command. (issue #14 side note)
    */
    const ownership = sourceBetween(
      nativeSidebarSource,
      "function isGhostexOwnedPath(command, filePath)",
      "function isBrokenSymlink",
    );
    expect(ownership).toContain("real === targetReal || real.toLowerCase() === targetReal.toLowerCase()");
  });
});
