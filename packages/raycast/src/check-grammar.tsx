import {
  Form,
  ActionPanel,
  Action,
  Detail,
  Clipboard,
  showToast,
  Toast,
  popToRoot,
  getPreferenceValues,
  openExtensionPreferences,
  Icon,
} from "@raycast/api";
import { useState, useEffect, useCallback } from "react";
import { randomUUID } from "crypto";
import {
  GrammarResult,
  Preferences,
  HistoryEntry,
  Profile,
  checkGrammar,
  buildSystemPrompt,
  fetchModels,
  ModelOption,
  DEFAULT_MODELS,
  computeWordDiff,
  diffToMarkdown,
  loadProfiles,
  getActiveProfileId,
  setActiveProfileId,
  getDefaultProfile,
  saveToHistory,
  generateText,
} from "@bex/core";
import { storage } from "./lib/raycast-storage";

const DRAFT_KEY = "draft:raycast:check";
const NO_PROFILE_VALUE = "__none__";

type RewriteIntent = "formal" | "friendly" | "shorter";

const REWRITE_INTENTS: Record<
  RewriteIntent,
  { label: string; instruction: string }
> = {
  formal: {
    label: "More Formal",
    instruction: "Rewrite to a more formal and professional tone.",
  },
  friendly: {
    label: "Friendlier",
    instruction: "Rewrite to sound warmer and friendlier.",
  },
  shorter: {
    label: "Shorter",
    instruction: "Rewrite to be shorter and more concise.",
  },
};

const REWRITE_SYSTEM_PROMPT = `You are an expert English editor.
Rewrite the given text while preserving its meaning.
Follow the requested style exactly.
Respond with rewritten text only (no markdown, no explanation).`;

function validatePreferences(prefs: Preferences): string | null {
  switch (prefs.provider) {
    case "openai":
      return prefs.openaiApiKey ? null : "OpenAI API key not set.";
    case "openai-codex":
      return "OpenAI Codex is available in the desktop app only.";
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

function getProcessingDisclosure(prefs: Preferences): string {
  if (prefs.provider === "ollama") {
    return "Processing runs locally via Ollama.";
  }
  if (prefs.provider === "openai-codex") {
    return "OpenAI Codex is currently desktop-only in Bex.";
  }
  return `Processing is sent to your ${prefs.provider} cloud model.`;
}

export default function CheckGrammar() {
  const prefs = getPreferenceValues<Preferences>();

  const [result, setResult] = useState<GrammarResult | null>(null);
  const [original, setOriginal] = useState("");
  const [inputDraft, setInputDraft] = useState("");
  const [isLoading, setIsLoading] = useState(false);

  const [models, setModels] = useState<ModelOption[]>([]);
  const [selectedModel, setSelectedModel] = useState("");
  const [modelsLoading, setModelsLoading] = useState(true);
  const [modelsError, setModelsError] = useState<string | null>(null);

  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [selectedProfileId, setSelectedProfileId] = useState("");
  const [profilesError, setProfilesError] = useState<string | null>(null);

  const [rewriteLoading, setRewriteLoading] = useState<RewriteIntent | null>(
    null,
  );

  const setupError = validatePreferences(prefs);

  const refreshContext = useCallback(async () => {
    setModelsLoading(true);
    setModelsError(null);
    setProfilesError(null);

    try {
      const fetched = await fetchModels(prefs.provider, prefs);
      setModels(fetched);

      const lastModel = await storage.getItem<string>(
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

      if (fetched.length === 0 && !setupError) {
        setModelsError("Could not fetch model list. Using provider default.");
      }
    } catch {
      setModels([]);
      setModelsError("Could not fetch model list. Check network/API access.");
      setSelectedModel(DEFAULT_MODELS[prefs.provider]);
    }

    try {
      const loadedProfiles = await loadProfiles(storage);
      setProfiles(loadedProfiles);

      const activeId = await getActiveProfileId(storage);
      if (activeId && loadedProfiles.some((p) => p.id === activeId)) {
        setSelectedProfileId(activeId);
      } else {
        const defaultProfile = getDefaultProfile(loadedProfiles);
        setSelectedProfileId(defaultProfile?.id || "");
      }
    } catch {
      setProfiles([]);
      setProfilesError("Could not load profiles.");
    } finally {
      setModelsLoading(false);
    }
  }, [prefs, setupError]);

  // Initial load + refresh on provider changes
  useEffect(() => {
    void refreshContext();
  }, [refreshContext]);

  // Restore autosaved draft
  useEffect(() => {
    (async () => {
      const draft = await storage.getItem<string>(DRAFT_KEY);
      if (!draft) return;

      try {
        const parsed = JSON.parse(draft);
        setInputDraft(typeof parsed === "string" ? parsed : draft);
      } catch {
        setInputDraft(draft);
      }
    })();
  }, []);

  // Autosave draft while typing
  useEffect(() => {
    const timeout = setTimeout(() => {
      const persist = async () => {
        if (!inputDraft) {
          await storage.removeItem(DRAFT_KEY);
          return;
        }
        await storage.setItem(DRAFT_KEY, inputDraft);
      };
      void persist();
    }, 250);

    return () => clearTimeout(timeout);
  }, [inputDraft]);

  async function handleSubmit(values: { text: string }) {
    const text = (values.text || inputDraft).trim();
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
    setInputDraft(text);

    const model = selectedModel || DEFAULT_MODELS[prefs.provider];
    await storage.setItem(`lastModel:${prefs.provider}`, model);

    const selectedProfile = profiles.find((p) => p.id === selectedProfileId);
    await setActiveProfileId(storage, selectedProfileId || "");
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
        const entry: HistoryEntry = {
          id: randomUUID(),
          original: text,
          corrected: grammarResult.corrected,
          explanation: grammarResult.explanation,
          provider: prefs.provider,
          model,
          timestamp: new Date().toISOString(),
          profileName: selectedProfile?.name,
        };
        await saveToHistory(storage, entry);
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

  async function handleRewrite(intent: RewriteIntent) {
    if (!result) return;
    if (setupError) {
      await showToast({
        style: Toast.Style.Failure,
        title: setupError,
      });
      return;
    }

    setRewriteLoading(intent);

    const model = selectedModel || DEFAULT_MODELS[prefs.provider];
    const prefsWithModel = { ...prefs, model };

    const toast = await showToast({
      style: Toast.Style.Animated,
      title: `Rewriting: ${REWRITE_INTENTS[intent].label}...`,
    });

    try {
      const rewritten = await generateText(
        `${REWRITE_SYSTEM_PROMPT}\n\nRewrite request: ${REWRITE_INTENTS[intent].instruction}`,
        result.corrected,
        prefsWithModel,
      );

      const cleaned = rewritten.trim();
      if (!cleaned) throw new Error("Received empty rewrite");

      setResult({
        corrected: cleaned,
        explanation: `${result.explanation}\n\nRewrite applied: ${REWRITE_INTENTS[intent].label}`,
      });

      toast.style = Toast.Style.Success;
      toast.title = `${REWRITE_INTENTS[intent].label} rewrite ready`;
    } catch (err) {
      toast.style = Toast.Style.Failure;
      toast.title = "Rewrite failed";
      toast.message = err instanceof Error ? err.message : String(err);
    } finally {
      setRewriteLoading(null);
    }
  }

  async function handleClearDraft() {
    setInputDraft("");
    await storage.removeItem(DRAFT_KEY);
    await showToast({
      style: Toast.Style.Success,
      title: "Draft cleared",
    });
  }

  // Form view (input)
  if (!result) {
    return (
      <Form
        isLoading={isLoading || modelsLoading}
        actions={
          <ActionPanel>
            {setupError ? (
              <Action
                title="Open Preferences"
                icon={Icon.Gear}
                onAction={() => openExtensionPreferences()}
              />
            ) : (
              <Action.SubmitForm
                title="Check Grammar"
                onSubmit={handleSubmit}
                icon={Icon.Check}
              />
            )}
            <Action
              title="Retry Loading"
              icon={Icon.ArrowClockwise}
              onAction={() => void refreshContext()}
            />
            <Action
              title="Clear Draft"
              icon={Icon.XMarkCircle}
              shortcut={{ modifiers: ["cmd", "shift"], key: "x" }}
              onAction={() => void handleClearDraft()}
            />
          </ActionPanel>
        }
      >
        <Form.Description
          text={`AI-generated edits may contain mistakes. Review before sending. ${getProcessingDisclosure(prefs)}`}
        />
        {setupError && (
          <Form.Description
            text={`Setup required: ${setupError} Open Extension Preferences to continue.`}
          />
        )}
        {modelsError && <Form.Description text={modelsError} />}
        {profilesError && <Form.Description text={profilesError} />}

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
          value={selectedProfileId || NO_PROFILE_VALUE}
          onChange={(value) => {
            setSelectedProfileId(value === NO_PROFILE_VALUE ? "" : value);
          }}
        >
          <Form.Dropdown.Item key={NO_PROFILE_VALUE} value={NO_PROFILE_VALUE} title="No Profile" />
          {profiles.map((p) => (
            <Form.Dropdown.Item key={p.id} value={p.id} title={p.name} />
          ))}
        </Form.Dropdown>

        <Form.TextArea
          id="text"
          title="Text to Check"
          placeholder="Type or paste your English text here..."
          value={inputDraft}
          onChange={setInputDraft}
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
              title="Paste to App"
              icon={Icon.Clipboard}
              onAction={async () => {
                await Clipboard.paste(original);
                await popToRoot();
              }}
            />
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
          {(Object.keys(REWRITE_INTENTS) as RewriteIntent[]).map((intent) => (
            <Action
              key={intent}
              title={
                rewriteLoading === intent
                  ? `Rewriting: ${REWRITE_INTENTS[intent].label}...`
                  : `Rewrite: ${REWRITE_INTENTS[intent].label}`
              }
              icon={Icon.Stars}
              onAction={() => void handleRewrite(intent)}
            />
          ))}
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
