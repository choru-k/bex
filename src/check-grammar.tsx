import {
  Form,
  ActionPanel,
  Action,
  Detail,
  Clipboard,
  LocalStorage,
  showToast,
  Toast,
  popToRoot,
  getPreferenceValues,
  openExtensionPreferences,
  Icon,
} from "@raycast/api";
import { useState } from "react";
import { GrammarResult, Preferences, HistoryEntry } from "./llm/types";
import { checkGrammar } from "./llm/provider";
import { computeWordDiff, diffToMarkdown } from "./lib/diff";

function validatePreferences(prefs: Preferences): string | null {
  switch (prefs.provider) {
    case "openai":
      return prefs.openaiApiKey ? null : "OpenAI API key not set.";
    case "claude":
      return prefs.claudeApiKey ? null : "Claude API key not set.";
    case "gemini":
      return prefs.geminiApiKey ? null : "Gemini API key not set.";
    case "ollama":
      return null;
  }
}

function getTimeoutMs(provider: string): number {
  return provider === "ollama" ? 30000 : 10000;
}

async function saveToHistory(
  original: string,
  result: GrammarResult,
  prefs: Preferences,
) {
  const raw = await LocalStorage.getItem<string>("history");
  let entries: HistoryEntry[];
  try {
    entries = raw ? JSON.parse(raw) : [];
  } catch {
    entries = [];
  }
  entries.unshift({
    id: crypto.randomUUID(),
    original,
    corrected: result.corrected,
    explanation: result.explanation,
    provider: prefs.provider,
    model: prefs.model || "default",
    timestamp: new Date().toISOString(),
  });
  if (entries.length > 500) entries.length = 500;
  await LocalStorage.setItem("history", JSON.stringify(entries));
}

export default function CheckGrammar() {
  const [result, setResult] = useState<GrammarResult | null>(null);
  const [original, setOriginal] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const prefs = getPreferenceValues<Preferences>();

  async function handleSubmit(values: { text: string }) {
    const text = values.text.trim();
    if (!text) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Please enter some text to check.",
      });
      return;
    }

    const validationError = validatePreferences(prefs);
    if (validationError) {
      await showToast({
        style: Toast.Style.Failure,
        title: validationError,
        primaryAction: {
          title: "Open Preferences",
          onAction: () => openExtensionPreferences(),
        },
      });
      return;
    }

    setIsLoading(true);
    setOriginal(text);

    const toast = await showToast({
      style: Toast.Style.Animated,
      title: `Checking with ${prefs.provider}...`,
    });

    const controller = new AbortController();
    const timeout = setTimeout(
      () => controller.abort(),
      getTimeoutMs(prefs.provider),
    );

    try {
      const grammarResult = await checkGrammar(text, prefs, controller.signal);
      clearTimeout(timeout);
      toast.style = Toast.Style.Success;
      toast.title = "Grammar checked!";
      try {
        await saveToHistory(text, grammarResult, prefs);
      } catch {
        /* history save failure shouldn't block main flow */
      }
      setResult(grammarResult);
    } catch (err) {
      clearTimeout(timeout);
      const message =
        err instanceof Error
          ? err.name === "AbortError"
            ? "Request timed out. Check your connection or try again."
            : err.message
          : "Unknown error occurred.";
      toast.style = Toast.Style.Failure;
      toast.title = "Error";
      toast.message = message;
    } finally {
      setIsLoading(false);
    }
  }

  // Form view (input)
  if (!result) {
    return (
      <Form
        isLoading={isLoading}
        actions={
          <ActionPanel>
            <Action.SubmitForm
              title="Check Grammar"
              onSubmit={handleSubmit}
              icon={Icon.Check}
            />
          </ActionPanel>
        }
      >
        <Form.TextArea
          id="text"
          title="Text to Check"
          placeholder="Type or paste your English text here..."
          autoFocus
        />
      </Form>
    );
  }

  // "No changes needed" case
  if (original === result.corrected) {
    return (
      <Detail
        markdown={`## Your text looks good!\n\nNo grammar or expression changes needed.\n\n> ${original}`}
        actions={
          <ActionPanel>
            <Action
              title="Check Again"
              icon={Icon.ArrowCounterClockwise}
              onAction={() => {
                setResult(null);
                setOriginal("");
              }}
            />
            <Action.CopyToClipboard title="Copy Text" content={original} />
          </ActionPanel>
        }
      />
    );
  }

  // Result view with diff
  const diffMd = diffToMarkdown(computeWordDiff(original, result.corrected));

  return (
    <Detail
      markdown={`## Corrected\n${result.corrected}\n\n## Changes\n${diffMd}\n\n## Explanation\n${result.explanation}`}
      actions={
        <ActionPanel>
          <Action
            title="Paste to App"
            icon={Icon.Clipboard}
            onAction={async () => {
              await Clipboard.paste(result.corrected);
              await popToRoot();
            }}
          />
          <Action.CopyToClipboard
            title="Copy to Clipboard"
            content={result.corrected}
            shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
          />
          <Action
            title="Check Again"
            icon={Icon.ArrowCounterClockwise}
            shortcut={{ modifiers: ["cmd"], key: "r" }}
            onAction={() => {
              setResult(null);
              setOriginal("");
            }}
          />
        </ActionPanel>
      }
    />
  );
}
