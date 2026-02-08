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
import { useState, useEffect } from "react";
import { randomUUID } from "crypto";
import { GrammarResult, Preferences, HistoryEntry, Profile } from "./llm/types";
import { checkGrammar, buildSystemPrompt } from "./llm/provider";
import { fetchModels, ModelOption, DEFAULT_MODELS } from "./llm/models";
import { computeWordDiff, diffToMarkdown } from "./lib/diff";
import {
  loadProfiles,
  getActiveProfileId,
  setActiveProfileId,
  getDefaultProfile,
} from "./lib/profiles";

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
  provider: string,
  model: string,
  profileName?: string,
) {
  const raw = await LocalStorage.getItem<string>("history");
  let entries: HistoryEntry[];
  try {
    entries = raw ? JSON.parse(raw) : [];
  } catch {
    entries = [];
  }
  entries.unshift({
    id: randomUUID(),
    original,
    corrected: result.corrected,
    explanation: result.explanation,
    provider,
    model,
    timestamp: new Date().toISOString(),
    profileName,
  });
  if (entries.length > 500) entries.length = 500;
  await LocalStorage.setItem("history", JSON.stringify(entries));
}

export default function CheckGrammar() {
  const [result, setResult] = useState<GrammarResult | null>(null);
  const [original, setOriginal] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [models, setModels] = useState<ModelOption[]>([]);
  const [selectedModel, setSelectedModel] = useState("");
  const [modelsLoading, setModelsLoading] = useState(true);
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [selectedProfileId, setSelectedProfileId] = useState("");
  const prefs = getPreferenceValues<Preferences>();

  useEffect(() => {
    (async () => {
      setModelsLoading(true);
      const fetched = await fetchModels(prefs.provider, prefs);
      setModels(fetched);

      const lastModel = await LocalStorage.getItem<string>(
        `lastModel:${prefs.provider}`,
      );
      const defaultModel = DEFAULT_MODELS[prefs.provider];

      if (lastModel && fetched.some((m) => m.id === lastModel)) {
        setSelectedModel(lastModel);
      } else if (fetched.some((m) => m.id === defaultModel)) {
        setSelectedModel(defaultModel);
      } else if (fetched.length > 0) {
        setSelectedModel(fetched[0].id);
      } else {
        setSelectedModel(defaultModel);
      }

      const loadedProfiles = await loadProfiles();
      setProfiles(loadedProfiles);

      const activeId = await getActiveProfileId();
      if (activeId && loadedProfiles.some((p) => p.id === activeId)) {
        setSelectedProfileId(activeId);
      } else {
        const defaultProfile = getDefaultProfile(loadedProfiles);
        setSelectedProfileId(defaultProfile?.id || "");
      }

      setModelsLoading(false);
    })();
  }, []);

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

    const model = selectedModel || DEFAULT_MODELS[prefs.provider];
    await LocalStorage.setItem(`lastModel:${prefs.provider}`, model);

    const selectedProfile = profiles.find((p) => p.id === selectedProfileId);
    if (selectedProfileId) {
      await setActiveProfileId(selectedProfileId);
    }
    const systemPrompt = buildSystemPrompt(selectedProfile?.prompt);

    const prefsWithModel = { ...prefs, model };

    const toast = await showToast({
      style: Toast.Style.Animated,
      title: `Checking with ${prefs.provider} (${model})...`,
    });

    const controller = new AbortController();
    const timeout = setTimeout(
      () => controller.abort(),
      getTimeoutMs(prefs.provider),
    );

    try {
      const grammarResult = await checkGrammar(
        text,
        prefsWithModel,
        controller.signal,
        systemPrompt,
      );
      clearTimeout(timeout);
      toast.style = Toast.Style.Success;
      toast.title = "Grammar checked!";
      try {
        await saveToHistory(
          text,
          grammarResult,
          prefs.provider,
          model,
          selectedProfile?.name,
        );
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
        isLoading={isLoading || modelsLoading}
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
        <Form.Dropdown
          id="model"
          title="Model"
          value={selectedModel}
          onChange={setSelectedModel}
        >
          {models.length > 0 ? (
            models.map((m) => (
              <Form.Dropdown.Item key={m.id} value={m.id} title={m.name} />
            ))
          ) : (
            <Form.Dropdown.Item
              key={DEFAULT_MODELS[prefs.provider]}
              value={DEFAULT_MODELS[prefs.provider]}
              title={DEFAULT_MODELS[prefs.provider]}
            />
          )}
        </Form.Dropdown>
        <Form.Dropdown
          id="profile"
          title="Profile"
          value={selectedProfileId}
          onChange={setSelectedProfileId}
        >
          <Form.Dropdown.Item key="none" value="" title="No Profile" />
          {profiles.map((p) => (
            <Form.Dropdown.Item key={p.id} value={p.id} title={p.name} />
          ))}
        </Form.Dropdown>
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
