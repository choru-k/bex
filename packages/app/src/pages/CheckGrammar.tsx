import { useState, useEffect, useCallback } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { toast } from "sonner";
import type {
  Preferences,
  GrammarResult,
  Profile,
  DiffWord,
  ModelOption,
} from "@bex/core";
import {
  checkGrammar,
  buildSystemPrompt,
  fetchModels,
  DEFAULT_MODELS,
  computeWordDiff,
  loadProfiles,
  getActiveProfileId,
  setActiveProfileId,
  getDefaultProfile,
  saveToHistory,
  generateText,
} from "@bex/core";
import { storage } from "@/lib/tauri-storage";
import { parsePreferences } from "@/lib/app-theme";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { DiffView } from "@/components/DiffView";
import {
  Loader2,
  SpellCheck,
  Copy,
  Check,
  Sparkles,
  RotateCcw,
  Settings2,
} from "lucide-react";

const PREFS_KEY = "preferences";
const DRAFT_KEY = "draft:check";
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

interface HistoryNavigationState {
  draftText?: string;
}

function validatePreferences(prefs: Preferences | null): string | null {
  if (!prefs) return "Configure your provider and API key in Settings.";

  switch (prefs.provider) {
    case "openai":
      return prefs.openaiApiKey
        ? null
        : "OpenAI API key is missing. Add it in Settings.";
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
  return `Processing is sent to your ${prefs.provider} cloud model.`;
}

export default function CheckGrammar() {
  const navigate = useNavigate();
  const location = useLocation();

  const [input, setInput] = useState("");
  const [result, setResult] = useState<GrammarResult | null>(null);
  const [diff, setDiff] = useState<DiffWord[]>([]);
  const [loading, setLoading] = useState(false);
  const [copied, setCopied] = useState(false);
  const [showOnlyChanges, setShowOnlyChanges] = useState(false);
  const [rewritingIntent, setRewritingIntent] = useState<RewriteIntent | null>(
    null,
  );

  // Preferences
  const [prefs, setPrefs] = useState<Preferences | null>(null);
  const [model, setModel] = useState("");
  const [models, setModels] = useState<ModelOption[]>([]);
  const [loadingModels, setLoadingModels] = useState(false);
  const [modelError, setModelError] = useState<string | null>(null);

  // Profiles
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [activeProfileId, setActiveProfileState] = useState<string>("");
  const [profileError, setProfileError] = useState<string | null>(null);

  const setupError = validatePreferences(prefs);

  // Load preferences + draft on mount
  useEffect(() => {
    (async () => {
      const [rawPrefs, draftInput] = await Promise.all([
        storage.getItem<unknown>(PREFS_KEY),
        storage.getItem<string>(DRAFT_KEY),
      ]);

      const p = parsePreferences(rawPrefs);
      if (p) {
        setPrefs(p);
        setModel(p.model || DEFAULT_MODELS[p.provider]);
      }

      if (draftInput) {
        setInput(draftInput);
      }
    })();
  }, []);

  // Load profiles
  const refreshProfiles = useCallback(async () => {
    try {
      const profileList = await loadProfiles(storage);
      setProfiles(profileList);
      setProfileError(null);

      const activeId = await getActiveProfileId(storage);
      if (activeId && profileList.some((p) => p.id === activeId)) {
        setActiveProfileState(activeId);
      } else {
        const def = getDefaultProfile(profileList);
        setActiveProfileState(def?.id || "");
      }
    } catch {
      setProfiles([]);
      setProfileError("Could not load profiles.");
    }
  }, []);

  useEffect(() => {
    void refreshProfiles();
  }, [refreshProfiles]);

  // Fetch models
  const refreshModels = useCallback(async () => {
    if (!prefs) {
      setModels([]);
      setModelError(null);
      return;
    }

    setLoadingModels(true);
    try {
      const fetched = await fetchModels(prefs.provider, prefs);
      setModels(fetched);

      if (fetched.length > 0 && !fetched.some((m) => m.id === model)) {
        setModel(fetched[0].id);
      }
      if (!model && fetched.length === 0) {
        setModel(DEFAULT_MODELS[prefs.provider]);
      }

      if (fetched.length === 0 && !setupError) {
        setModelError("Could not fetch model list. Using default model.");
      } else {
        setModelError(null);
      }
    } catch {
      setModels([]);
      setModelError("Could not fetch model list. Check network/API access.");
      if (!model) {
        setModel(DEFAULT_MODELS[prefs.provider]);
      }
    } finally {
      setLoadingModels(false);
    }
  }, [prefs, model, setupError]);

  useEffect(() => {
    void refreshModels();
  }, [refreshModels]);

  // Load text passed from history -> check page
  useEffect(() => {
    const state = location.state as HistoryNavigationState | null;
    if (!state?.draftText) return;

    setInput(state.draftText);
    setResult(null);
    setDiff([]);
    toast.success("Loaded text from history");
    navigate(location.pathname, { replace: true, state: null });
  }, [location.state, location.pathname, navigate]);

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
      toast.error("Please enter some text to check");
      return;
    }

    if (setupError) {
      toast.error(setupError);
      return;
    }

    if (!prefs) {
      toast.error("Please configure your settings first");
      return;
    }

    setLoading(true);
    setResult(null);
    setDiff([]);
    setShowOnlyChanges(false);

    try {
      const activeProfile = profiles.find((p) => p.id === activeProfileId);
      const systemPrompt = buildSystemPrompt(activeProfile?.prompt);
      const selectedModel = model || DEFAULT_MODELS[prefs.provider];
      const checkPrefs: Preferences = { ...prefs, model: selectedModel };

      const grammarResult = await checkGrammar(
        input,
        checkPrefs,
        undefined,
        systemPrompt,
      );

      setResult(grammarResult);
      setDiff(computeWordDiff(input, grammarResult.corrected));

      // Save to history (non-blocking to avoid interrupting the user)
      const entry = {
        id: crypto.randomUUID(),
        original: input,
        corrected: grammarResult.corrected,
        explanation: grammarResult.explanation,
        provider: prefs.provider,
        model: selectedModel,
        timestamp: new Date().toISOString(),
        profileName: activeProfile?.name,
      };
      void saveToHistory(storage, entry);

      toast.success("Grammar check complete");
    } catch (err) {
      toast.error(
        `Check failed: ${err instanceof Error ? err.message : "Unknown error"}`,
      );
    } finally {
      setLoading(false);
    }
  }, [input, setupError, prefs, profiles, activeProfileId, model]);

  const handleCopy = useCallback(async () => {
    if (!result) return;
    await navigator.clipboard.writeText(result.corrected);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, [result]);

  const handleReplaceInput = useCallback(() => {
    if (!result) return;
    setInput(result.corrected);
    setResult(null);
    setDiff([]);
    setShowOnlyChanges(false);
    toast.success("Replaced input with corrected text");
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
        const selectedModel = model || DEFAULT_MODELS[prefs.provider];
        const checkPrefs: Preferences = { ...prefs, model: selectedModel };
        const rewriteInstruction = REWRITE_INTENTS[intent].instruction;

        const rewritten = await generateText(
          `${REWRITE_SYSTEM_PROMPT}\n\nRewrite request: ${rewriteInstruction}`,
          result.corrected,
          checkPrefs,
        );

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
    [result, prefs, model, setupError, input],
  );

  const handleProfileChange = useCallback(async (id: string) => {
    if (id === NO_PROFILE_VALUE) {
      setActiveProfileState("");
      await setActiveProfileId(storage, "");
      return;
    }

    setActiveProfileState(id);
    await setActiveProfileId(storage, id);
  }, []);

  // Keyboard shortcuts
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      const meta = e.metaKey || e.ctrlKey;

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
    <div className="flex h-full flex-col gap-4">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-bold">Check Grammar</h2>
          <p className="text-muted-foreground leading-relaxed">
            Enter text and get AI-powered grammar corrections.
          </p>
        </div>
      </div>

      <div className="rounded-md border bg-muted/40 px-3 py-2 text-xs text-muted-foreground">
        AI-generated edits may contain mistakes. Review before sending. {getProcessingDisclosure(prefs)}
      </div>

      {setupError && (
        <Card className="border-destructive/40">
          <CardContent className="flex items-center justify-between gap-3 p-4">
            <div>
              <p className="text-sm font-medium">Setup required</p>
              <p className="text-sm leading-relaxed text-muted-foreground">{setupError}</p>
            </div>
            <Button
              variant="outline"
              size="sm"
              className="gap-2"
              onClick={() => navigate("/settings")}
            >
              <Settings2 className="h-4 w-4" />
              Open Settings
            </Button>
          </CardContent>
        </Card>
      )}

      {/* Controls row */}
      <div className="flex flex-wrap gap-3">
        <div className="w-56 space-y-1">
          <Label className="block text-xs">Model</Label>
          <Select value={model} onValueChange={setModel}>
            <SelectTrigger className="h-8 text-xs">
              {loadingModels ? (
                <Loader2 className="h-3 w-3 animate-spin" />
              ) : (
                <SelectValue placeholder="Select model" />
              )}
            </SelectTrigger>
            <SelectContent>
              {models.map((m) => (
                <SelectItem key={m.id} value={m.id}>
                  {m.name}
                </SelectItem>
              ))}
              {models.length === 0 && prefs && (
                <SelectItem value={DEFAULT_MODELS[prefs.provider]}>
                  {DEFAULT_MODELS[prefs.provider]} (default)
                </SelectItem>
              )}
            </SelectContent>
          </Select>
          {modelError && (
            <div className="flex items-center gap-2">
              <p className="text-xs text-muted-foreground">{modelError}</p>
              <Button
                variant="ghost"
                size="sm"
                className="h-7 px-2 text-xs"
                onClick={() => void refreshModels()}
              >
                <RotateCcw className="h-3 w-3" />
                Retry
              </Button>
            </div>
          )}
        </div>

        <div className="w-56 space-y-1">
          <Label className="block text-xs">Profile</Label>
          <Select
            value={activeProfileId || NO_PROFILE_VALUE}
            onValueChange={handleProfileChange}
          >
            <SelectTrigger className="h-8 text-xs">
              <SelectValue placeholder="No profile" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value={NO_PROFILE_VALUE}>No profile</SelectItem>
              {profiles.map((p) => (
                <SelectItem key={p.id} value={p.id}>
                  {p.name}
                  {p.isDefault ? " (default)" : ""}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          {profileError && (
            <div className="flex items-center gap-2">
              <p className="text-xs text-muted-foreground">{profileError}</p>
              <Button
                variant="ghost"
                size="sm"
                className="h-7 px-2 text-xs"
                onClick={() => void refreshProfiles()}
              >
                <RotateCcw className="h-3 w-3" />
                Retry
              </Button>
            </div>
          )}
        </div>

        <div className="flex items-end">
          <Button
            onClick={handleCheck}
            disabled={loading || !!setupError || !input.trim() || !!rewritingIntent}
            className="gap-2"
            size="sm"
          >
            {loading ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
              <SpellCheck className="h-4 w-4" />
            )}
            {loading ? "Checking..." : "Check"}
          </Button>
        </div>
      </div>

      <p className="text-xs text-muted-foreground">
        Shortcuts: ⌘/Ctrl+Enter Check · ⌘/Ctrl+Shift+C Copy · ⌘/Ctrl+R Re-check
      </p>

      {/* Split pane */}
      <div className="grid min-h-0 flex-1 grid-cols-2 gap-4">
        {/* Input */}
        <div className="flex flex-col gap-2">
          <Label>Input</Label>
          <Textarea
            value={input}
            onChange={(e) => setInput(e.target.value)}
            placeholder="Type or paste your text here..."
            className="flex-1 resize-none"
          />
        </div>

        {/* Output */}
        <div className="flex min-h-0 flex-col gap-2">
          <div className="flex items-center justify-between">
            <Label>Result</Label>
            {result && (
              <div className="flex items-center gap-2">
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={handleReplaceInput}
                  className="h-7 gap-1 text-xs"
                >
                  Use as Input
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
              </div>
            )}
          </div>

          {loading && (
            <div className="flex flex-1 items-center justify-center">
              <div className="flex flex-col items-center gap-2 text-muted-foreground">
                <Loader2 className="h-8 w-8 animate-spin" />
                <p className="text-sm">Checking grammar...</p>
              </div>
            </div>
          )}

          {!loading && result && (
            <div className="flex flex-col gap-3 overflow-auto">
              <div className="flex flex-wrap gap-2">
                {(Object.keys(REWRITE_INTENTS) as RewriteIntent[]).map(
                  (intent) => (
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
                  ),
                )}
              </div>

              <Card>
                <CardHeader className="pb-3">
                  <div className="flex items-center justify-between gap-2">
                    <CardTitle className="text-sm">Diff</CardTitle>
                    <Button
                      variant="ghost"
                      size="sm"
                      className="h-7 px-2 text-xs"
                      onClick={() => setShowOnlyChanges((v) => !v)}
                    >
                      {showOnlyChanges ? "Show full text" : "Show only changes"}
                    </Button>
                  </div>
                </CardHeader>
                <CardContent>
                  <DiffView
                    diff={diff}
                    className="text-sm"
                    showOnlyChanges={showOnlyChanges}
                  />
                </CardContent>
              </Card>

              <Card>
                <CardHeader className="pb-3">
                  <CardTitle className="text-sm">Corrected Text</CardTitle>
                </CardHeader>
                <CardContent>
                  <p className="whitespace-pre-wrap text-sm leading-relaxed">{result.corrected}</p>
                </CardContent>
              </Card>

              <Card>
                <CardHeader className="pb-3">
                  <CardTitle className="text-sm">Explanation</CardTitle>
                </CardHeader>
                <CardContent>
                  <p className="text-sm leading-relaxed text-muted-foreground">
                    {result.explanation}
                  </p>
                </CardContent>
              </Card>
            </div>
          )}

          {!loading && !result && (
            <div className="flex flex-1 items-center justify-center rounded-md border border-dashed">
              <p className="text-sm leading-relaxed text-muted-foreground">
                {setupError
                  ? "Finish setup to start checking grammar"
                  : "Results will appear here"}
              </p>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
