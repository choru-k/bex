import { useState, useEffect, useCallback, useRef } from "react";
import { useNavigate } from "react-router-dom";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { toast } from "sonner";
import type { Preferences, GrammarResult, Profile, DiffWord } from "@bex/core";
import {
  checkGrammar,
  buildSystemPrompt,
  DEFAULT_MODELS,
  computeWordDiff,
  loadProfiles,
  getActiveProfileId,
  getDefaultProfile,
  saveToHistory,
  generateText,
} from "@bex/core";
import { storage } from "@/lib/tauri-storage";
import {
  applyAppTheme,
  normalizeAppTheme,
  normalizeAppColorMode,
  parsePreferences,
  syncAppColorMode,
} from "@/lib/app-theme";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { DiffView } from "@/components/DiffView";
import {
  Loader2,
  SpellCheck,
  Copy,
  Check,
  Sparkles,
  Settings2,
} from "lucide-react";
import { Toaster } from "sonner";

const PREFS_KEY = "preferences";
const DRAFT_KEY = "draft:popup";

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

function validatePreferences(prefs: Preferences | null): string | null {
  if (!prefs) return "Configure your provider and API key in Settings.";

  switch (prefs.provider) {
    case "openai":
      return prefs.openaiApiKey
        ? null
        : "OpenAI API key is missing. Add it in Settings.";
    case "openai-codex":
      return prefs.openaiCodexRefreshToken
        ? null
        : "OpenAI Codex is not connected. Connect ChatGPT in Settings.";
    case "claude":
      return prefs.claudeApiKey
        ? null
        : "Claude API key is missing. Add it in Settings.";
    case "gemini":
      return prefs.geminiApiKey
        ? null
        : "Gemini API key is missing. Add it in Settings.";
    case "ollama":
      return null;
  }
}

function getProcessingDisclosure(prefs: Preferences | null): string {
  if (!prefs) return "Set up your provider to start grammar checks.";
  if (prefs.provider === "ollama") {
    return "Processing runs locally via Ollama.";
  }
  if (prefs.provider === "openai-codex") {
    return "Processing is sent to your ChatGPT Codex subscription.";
  }
  return `Processing is sent to your ${prefs.provider} cloud model.`;
}

export default function Popup() {
  const navigate = useNavigate();

  const [input, setInput] = useState("");
  const [result, setResult] = useState<GrammarResult | null>(null);
  const [diff, setDiff] = useState<DiffWord[]>([]);
  const [loading, setLoading] = useState(false);
  const [copied, setCopied] = useState(false);
  const [showOnlyChanges, setShowOnlyChanges] = useState(false);
  const [rewritingIntent, setRewritingIntent] = useState<RewriteIntent | null>(
    null,
  );

  const [prefs, setPrefs] = useState<Preferences | null>(null);
  const [prefsLoaded, setPrefsLoaded] = useState(false);
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [activeProfileId, setActiveProfileIdState] = useState("");

  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const setupError = prefsLoaded ? validatePreferences(prefs) : null;

  const persistCodexSessionIfUpdated = useCallback(
    async (nextPrefs: Preferences) => {
      if (!prefs || prefs.provider !== "openai-codex") return;
      if (nextPrefs.provider !== "openai-codex") return;

      const changed =
        nextPrefs.openaiCodexAccessToken !== prefs.openaiCodexAccessToken ||
        nextPrefs.openaiCodexRefreshToken !== prefs.openaiCodexRefreshToken ||
        nextPrefs.openaiCodexExpiresAt !== prefs.openaiCodexExpiresAt ||
        nextPrefs.openaiCodexAccountId !== prefs.openaiCodexAccountId;

      if (!changed) return;

      setPrefs(nextPrefs);
      await storage.setItem(PREFS_KEY, JSON.stringify(nextPrefs));
    },
    [prefs],
  );

  useEffect(() => {
    applyAppTheme(normalizeAppTheme(prefs?.appTheme));
    return syncAppColorMode(normalizeAppColorMode(prefs?.appColorMode));
  }, [prefs?.appTheme, prefs?.appColorMode]);

  // Load prefs + profiles + draft on mount
  useEffect(() => {
    (async () => {
      const [rawPrefs, draftInput] = await Promise.all([
        storage.getItem<unknown>(PREFS_KEY),
        storage.getItem<string>(DRAFT_KEY),
      ]);

      const parsedPrefs = parsePreferences(rawPrefs);
      if (parsedPrefs) {
        setPrefs(parsedPrefs);
      }

      if (draftInput) {
        setInput(draftInput);
      }

      try {
        const profileList = await loadProfiles(storage);
        setProfiles(profileList);
        const activeId = await getActiveProfileId(storage);
        if (activeId) {
          setActiveProfileIdState(activeId);
        } else {
          const def = getDefaultProfile(profileList);
          if (def) setActiveProfileIdState(def.id);
        }
      } catch {
        setProfiles([]);
      }

      setPrefsLoaded(true);
    })();

    textareaRef.current?.focus();
  }, []);

  // Autosave draft
  useEffect(() => {
    const timeout = setTimeout(() => {
      const persist = async () => {
        if (!input) {
          await storage.removeItem(DRAFT_KEY);
          return;
        }
        await storage.setItem(DRAFT_KEY, JSON.stringify(input));
      };
      void persist();
    }, 250);

    return () => clearTimeout(timeout);
  }, [input]);

  const handleCheck = useCallback(async () => {
    if (!input.trim()) {
      toast.error("Enter some text to check");
      return;
    }
    if (setupError) {
      toast.error(setupError);
      return;
    }
    if (!prefs) {
      toast.error("Configure settings in the main app first");
      return;
    }

    setLoading(true);
    setResult(null);
    setDiff([]);
    setShowOnlyChanges(false);

    try {
      const activeProfile = profiles.find((p) => p.id === activeProfileId);
      const systemPrompt = buildSystemPrompt(activeProfile?.prompt);
      const model = prefs.model || DEFAULT_MODELS[prefs.provider];
      const checkPrefs: Preferences = { ...prefs, model };

      const grammarResult = await checkGrammar(
        input,
        checkPrefs,
        undefined,
        systemPrompt,
      );

      await persistCodexSessionIfUpdated(checkPrefs);

      setResult(grammarResult);
      setDiff(computeWordDiff(input, grammarResult.corrected));

      // Save to history
      void saveToHistory(storage, {
        id: crypto.randomUUID(),
        original: input,
        corrected: grammarResult.corrected,
        explanation: grammarResult.explanation,
        provider: prefs.provider,
        model,
        timestamp: new Date().toISOString(),
        profileName: activeProfile?.name,
      });

      toast.success("Grammar check complete");
    } catch (err) {
      toast.error(
        `Check failed: ${err instanceof Error ? err.message : "Unknown error"}`,
      );
    } finally {
      setLoading(false);
    }
  }, [
    input,
    setupError,
    prefs,
    profiles,
    activeProfileId,
    persistCodexSessionIfUpdated,
  ]);

  const handleCopy = useCallback(async () => {
    if (!result) return;
    await navigator.clipboard.writeText(result.corrected);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, [result]);

  const handleCopyAndClose = useCallback(async () => {
    if (!result) return;
    await navigator.clipboard.writeText(result.corrected);
    getCurrentWindow().close();
  }, [result]);

  const handleRewrite = useCallback(
    async (intent: RewriteIntent) => {
      if (!result || !prefs) return;
      if (setupError) {
        toast.error(setupError);
        return;
      }

      setRewritingIntent(intent);
      try {
        const model = prefs.model || DEFAULT_MODELS[prefs.provider];
        const checkPrefs: Preferences = { ...prefs, model };
        const rewritten = await generateText(
          `${REWRITE_SYSTEM_PROMPT}\n\nRewrite request: ${REWRITE_INTENTS[intent].instruction}`,
          result.corrected,
          checkPrefs,
        );

        await persistCodexSessionIfUpdated(checkPrefs);

        const cleaned = rewritten.trim();
        if (!cleaned) throw new Error("Received empty rewrite");

        setResult({
          corrected: cleaned,
          explanation: `${result.explanation}\n\nRewrite applied: ${REWRITE_INTENTS[intent].label}`,
        });
        setDiff(computeWordDiff(input, cleaned));
        toast.success(`${REWRITE_INTENTS[intent].label} rewrite ready`);
      } catch (err) {
        toast.error(
          `Rewrite failed: ${err instanceof Error ? err.message : "Unknown error"}`,
        );
      } finally {
        setRewritingIntent(null);
      }
    },
    [result, prefs, setupError, input, persistCodexSessionIfUpdated],
  );

  // Keyboard shortcuts
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      const meta = e.metaKey || e.ctrlKey;

      if (e.key === "Escape") {
        getCurrentWindow().close();
      }

      if (meta && e.key === "Enter") {
        e.preventDefault();
        if (!loading && input.trim()) {
          void handleCheck();
        }
      }

      if (meta && e.shiftKey && e.key.toLowerCase() === "c") {
        if (!result) return;
        e.preventDefault();
        void handleCopy();
      }

      if (meta && e.key.toLowerCase() === "r") {
        e.preventDefault();
        if (!loading && input.trim()) {
          void handleCheck();
        }
      }
    };

    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [handleCheck, handleCopy, input, loading, result]);

  return (
    <div className="flex h-screen flex-col overflow-hidden">
      <div data-tauri-drag-region className="h-7 shrink-0" />
      <div className="flex min-h-0 flex-1 flex-col gap-3 p-4 pt-2">
        <Toaster position="top-center" richColors />

        <div className="flex items-center justify-between">
        <h1 className="text-lg font-semibold">Quick Check</h1>
        <div className="flex gap-2">
          {result && (
            <>
              <Button
                variant="outline"
                size="sm"
                onClick={handleCopyAndClose}
                className="h-7 gap-1 text-xs"
              >
                Copy and Close
              </Button>
              <Button
                variant="ghost"
                size="sm"
                onClick={handleCopy}
                className="h-7 gap-1 text-xs"
              >
                {copied ? (
                  <Check className="h-3 w-3" />
                ) : (
                  <Copy className="h-3 w-3" />
                )}
                {copied ? "Copied" : "Copy"}
              </Button>
            </>
          )}
          <Button
            onClick={handleCheck}
            disabled={loading || !!setupError || !input.trim() || !!rewritingIntent}
            size="sm"
            className="gap-1.5"
          >
            {loading ? (
              <Loader2 className="h-3.5 w-3.5 animate-spin" />
            ) : (
              <SpellCheck className="h-3.5 w-3.5" />
            )}
            {loading ? "Checking..." : "Check"}
          </Button>
        </div>
      </div>

      <div className="rounded-md border bg-muted/40 px-2 py-1 text-[11px] text-muted-foreground">
        AI-generated edits may contain mistakes. Review before sending. {getProcessingDisclosure(prefs)}
      </div>

      {setupError && (
        <div className="flex items-center justify-between gap-3 rounded-md border border-destructive/40 px-3 py-2">
          <div>
            <p className="text-xs font-medium">Setup required</p>
            <p className="text-xs leading-relaxed text-muted-foreground">{setupError}</p>
          </div>
          <Button
            variant="outline"
            size="sm"
            className="h-7 gap-1 text-xs"
            onClick={() => navigate("/settings")}
          >
            <Settings2 className="h-3 w-3" />
            Open Settings
          </Button>
        </div>
      )}

      <Textarea
        ref={textareaRef}
        value={input}
        onChange={(e) => setInput(e.target.value)}
        placeholder="Type or paste text here... (⌘+Enter to check, ⌘+⇧+C to copy, Esc to close)"
        className="min-h-[100px] flex-shrink-0 resize-none"
        rows={4}
      />

      <div className="min-h-0 flex-1 overflow-auto">
        {loading && (
          <div className="flex h-full items-center justify-center">
            <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
          </div>
        )}

        {!loading && result && (
          <div className="flex flex-col gap-3">
            <div className="flex flex-wrap gap-2">
              {(Object.keys(REWRITE_INTENTS) as RewriteIntent[]).map((intent) => (
                <Button
                  key={intent}
                  size="sm"
                  variant="outline"
                  className="h-7 gap-1 text-xs"
                  disabled={!!rewritingIntent}
                  onClick={() => void handleRewrite(intent)}
                >
                  {rewritingIntent === intent ? (
                    <Loader2 className="h-3 w-3 animate-spin" />
                  ) : (
                    <Sparkles className="h-3 w-3" />
                  )}
                  {REWRITE_INTENTS[intent].label}
                </Button>
              ))}
              <Button
                variant="ghost"
                size="sm"
                className="h-7 px-2 text-xs"
                onClick={() => setShowOnlyChanges((v) => !v)}
              >
                {showOnlyChanges ? "Show full text" : "Show only changes"}
              </Button>
            </div>

            <div>
              <p className="mb-1 text-xs font-medium text-muted-foreground">Diff</p>
              <DiffView diff={diff} className="text-sm" showOnlyChanges={showOnlyChanges} />
            </div>

            <div>
              <p className="mb-1 text-xs font-medium text-muted-foreground">
                Corrected
              </p>
              <p className="rounded-md border p-2 text-sm leading-relaxed whitespace-pre-wrap">
                {result.corrected}
              </p>
            </div>

            {result.explanation && (
              <div>
                <p className="mb-1 text-xs font-medium text-muted-foreground">
                  Explanation
                </p>
                <p className="whitespace-pre-wrap text-sm leading-relaxed text-muted-foreground">
                  {result.explanation}
                </p>
              </div>
            )}
          </div>
        )}

        {!loading && !result && (
          <div className="flex h-full items-center justify-center rounded-md border border-dashed">
            <p className="text-sm leading-relaxed text-muted-foreground">
              {setupError ? "Finish setup to start checking grammar" : "Results will appear here"}
            </p>
          </div>
        )}
      </div>
    </div>
  </div>
  );
}
