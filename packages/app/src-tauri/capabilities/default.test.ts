import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";

type CapabilityPermission =
  | string
  | {
      identifier: string;
      allow?: Array<{ path: string }>;
    };

describe("default capabilities", () => {
  it("allows .bex root directory and recursive paths for fs access", () => {
    const json = JSON.parse(
      readFileSync(new URL("./default.json", import.meta.url), "utf-8"),
    ) as { permissions: CapabilityPermission[] };

    const fsPermissionIds = [
      "fs:allow-read-text-file",
      "fs:allow-write-text-file",
      "fs:allow-exists",
      "fs:allow-mkdir",
    ];

    for (const permissionId of fsPermissionIds) {
      const permission = json.permissions.find(
        (entry): entry is Exclude<CapabilityPermission, string> =>
          typeof entry !== "string" && entry.identifier === permissionId,
      );

      expect(permission, `${permissionId} should exist`).toBeTruthy();
      const paths = (permission?.allow || []).map((entry) => entry.path);

      expect(paths).toContain("$HOME/.bex");
      expect(paths).toContain("$HOME/.bex/**");
    }
  });
});
