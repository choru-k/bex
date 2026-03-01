import {
  List,
  ActionPanel,
  Action,
  Detail,
  confirmAlert,
  Alert,
  Icon,
  showToast,
  Toast,
  launchCommand,
  LaunchType,
} from "@raycast/api";
import { useState, useEffect } from "react";
import {
  HistoryEntry,
  computeWordDiff,
  diffToMarkdown,
  loadHistory,
  deleteHistoryEntry,
  clearHistory,
} from "@bex/core";
import { storage } from "./lib/raycast-storage";

const DRAFT_KEY = "draft:raycast:check";
const ALL_PROVIDERS = "__all__";

function truncate(text: string, maxLen: number): string {
  return text.length > maxLen ? text.slice(0, maxLen) + "..." : text;
}

function timeAgo(isoString: string): string {
  const diff = Date.now() - new Date(isoString).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days === 1) return "yesterday";
  if (days < 30) return `${days}d ago`;
  return new Date(isoString).toLocaleDateString();
}

async function openAsNewInput(text: string) {
  await storage.setItem(DRAFT_KEY, text);
  await launchCommand({
    name: "check-grammar",
    type: LaunchType.UserInitiated,
  });
}

function EntryDetail({ entry }: { entry: HistoryEntry }) {
  const diff = computeWordDiff(entry.original, entry.corrected);
  const diffMd = diffToMarkdown(diff);

  const markdown = `## Original
${entry.original}

## Corrected
${entry.corrected}

## Changes
${diffMd}

## Explanation
${entry.explanation}

---
*${entry.provider} · ${entry.model}${entry.profileName ? ` · ${entry.profileName}` : ""} · ${new Date(entry.timestamp).toLocaleString()}*`;

  return (
    <Detail
      markdown={markdown}
      actions={
        <ActionPanel>
          <Action
            title="Use as New Input"
            icon={Icon.ArrowRight}
            onAction={() => void openAsNewInput(entry.corrected)}
          />
          <Action.CopyToClipboard
            title="Copy Corrected"
            content={entry.corrected}
          />
          <Action.CopyToClipboard
            title="Copy Original"
            content={entry.original}
            shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
          />
        </ActionPanel>
      }
    />
  );
}

export default function History() {
  const [entries, setEntries] = useState<HistoryEntry[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [providerFilter, setProviderFilter] = useState(ALL_PROVIDERS);

  useEffect(() => {
    (async () => {
      try {
        const loaded = await loadHistory(storage);
        setEntries(loaded);
      } catch {
        await showToast({
          style: Toast.Style.Failure,
          title: "Failed to load history",
        });
      }
      setIsLoading(false);
    })();
  }, []);

  const providers = Array.from(new Set(entries.map((entry) => entry.provider))).sort();
  const filteredEntries = entries.filter((entry) => {
    if (providerFilter === ALL_PROVIDERS) return true;
    return entry.provider === providerFilter;
  });

  if (!isLoading && entries.length === 0) {
    return (
      <List>
        <List.EmptyView
          title="No corrections yet"
          description="Use 'Check Grammar' to start improving your English!"
        />
      </List>
    );
  }

  return (
    <List
      isLoading={isLoading}
      searchBarAccessory={
        <List.Dropdown
          tooltip="Filter by provider"
          value={providerFilter}
          onChange={setProviderFilter}
        >
          <List.Dropdown.Item title="All Providers" value={ALL_PROVIDERS} />
          {providers.map((provider) => (
            <List.Dropdown.Item
              key={provider}
              title={provider}
              value={provider}
            />
          ))}
        </List.Dropdown>
      }
    >
      {filteredEntries.map((entry) => (
        <List.Item
          key={entry.id}
          title={truncate(entry.original, 60)}
          subtitle={truncate(entry.corrected, 40)}
          accessories={[
            ...(entry.profileName ? [{ tag: entry.profileName }] : []),
            { text: entry.provider },
            { text: timeAgo(entry.timestamp) },
          ]}
          actions={
            <ActionPanel>
              <Action.Push
                title="View Details"
                target={<EntryDetail entry={entry} />}
              />
              <Action
                title="Use as New Input"
                icon={Icon.ArrowRight}
                onAction={() => void openAsNewInput(entry.corrected)}
              />
              <Action.CopyToClipboard
                title="Copy Corrected"
                content={entry.corrected}
              />
              <Action.CopyToClipboard
                title="Copy Original"
                content={entry.original}
                shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
              />
              <Action
                title="Delete Entry"
                style={Action.Style.Destructive}
                icon={Icon.Trash}
                shortcut={{ modifiers: ["ctrl"], key: "x" }}
                onAction={async () => {
                  const updated = entries.filter((e) => e.id !== entry.id);
                  setEntries(updated);
                  try {
                    await deleteHistoryEntry(storage, entry.id);
                  } catch {
                    await showToast({
                      style: Toast.Style.Failure,
                      title: "Failed to save history",
                    });
                  }
                }}
              />
              <Action
                title="Clear All History"
                style={Action.Style.Destructive}
                icon={Icon.Trash}
                shortcut={{ modifiers: ["cmd", "shift"], key: "backspace" }}
                onAction={async () => {
                  if (
                    await confirmAlert({
                      title: "Clear all history?",
                      message: "This cannot be undone.",
                      primaryAction: {
                        title: "Clear",
                        style: Alert.ActionStyle.Destructive,
                      },
                    })
                  ) {
                    setEntries([]);
                    try {
                      await clearHistory(storage);
                    } catch {
                      await showToast({
                        style: Toast.Style.Failure,
                        title: "Failed to clear history",
                      });
                    }
                  }
                }}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
