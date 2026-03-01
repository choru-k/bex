import {
  Clipboard,
  Detail,
  LaunchType,
  launchCommand,
  showToast,
  Toast,
} from "@raycast/api";
import { useEffect, useState } from "react";
import { storage } from "./lib/raycast-storage";

const DRAFT_KEY = "draft:raycast:check";

export default function QuickCheckClipboard() {
  const [message, setMessage] = useState("Preparing clipboard text...");

  useEffect(() => {
    (async () => {
      const clipboardText = (await Clipboard.readText())?.trim() || "";

      if (!clipboardText) {
        setMessage("Clipboard is empty. Add text first, then run this command again.");
        await showToast({
          style: Toast.Style.Failure,
          title: "Clipboard is empty",
        });
        return;
      }

      await storage.setItem(DRAFT_KEY, clipboardText);
      setMessage("Opening Check Grammar with clipboard text...");

      await launchCommand({
        name: "check-grammar",
        type: LaunchType.UserInitiated,
      });
    })();
  }, []);

  return <Detail markdown={`## Quick Check Clipboard\n\n${message}`} />;
}
