import { useState, useEffect, useCallback } from "react";
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
} from "@bex/core";
import { storage } from "@/lib/tauri-storage";
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
import { Loader2, SpellCheck, Copy, Check } from "lucide-react";

const PREFS_KEY = "preferences";

export default function CheckGrammar() {
  const [input, setInput] = useState("");
  const [result, setResult] = useState<GrammarResult | null>(null);
  const [diff, setDiff] = useState<DiffWord[]>([]);
  const [loading, setLoading] = useState(false);
  const [copied, setCopied] = useState(false);

  // Preferences
  const [prefs, setPrefs] = useState<Preferences | null>(null);
  const [model, setModel] = useState("");
  const [models, setModels] = useState<ModelOption[]>([]);
  const [loadingModels, setLoadingModels] = useState(false);

  // Profiles
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [activeProfileId, setActiveProfileState] = useState<string>("");

  // Load preferences + profiles on mount
  useEffect(() => {
    (async () => {
      const raw = await storage.getItem<string>(PREFS_KEY);
      if (raw) {
        try {
          const p: Preferences = JSON.parse(raw);
          setPrefs(p);
          setModel(p.model || DEFAULT_MODELS[p.provider]);
        } catch {
          // fallback
        }
      }

      const profileList = await loadProfiles(storage);
      setProfiles(profileList);
      const activeId = await getActiveProfileId(storage);
      if (activeId) {
        setActiveProfileState(activeId);
      } else {
        const def = getDefaultProfile(profileList);
        if (def) setActiveProfileState(def.id);
      }
    })();
  }, []);

  // Fetch models when prefs load
  useEffect(() => {
    if (!prefs) return;
    setLoadingModels(true);
    fetchModels(prefs.provider, prefs)
      .then((result) => {
        setModels(result);
        if (result.length > 0 && !result.some((m) => m.id === model)) {
          setModel(result[0].id);
        }
      })
      .catch(() => setModels([]))
      .finally(() => setLoadingModels(false));
  }, [prefs, model]);

  const handleCheck = useCallback(async () => {
    if (!input.trim()) {
      toast.error("Please enter some text to check");
      return;
    }
    if (!prefs) {
      toast.error("Please configure your settings first");
      return;
    }

    setLoading(true);
    setResult(null);
    setDiff([]);

    try {
      const activeProfile = profiles.find((p) => p.id === activeProfileId);
      const systemPrompt = buildSystemPrompt(activeProfile?.prompt);
      const checkPrefs: Preferences = { ...prefs, model };

      const grammarResult = await checkGrammar(
        input,
        checkPrefs,
        undefined,
        systemPrompt,
      );

      setResult(grammarResult);
      const wordDiff = computeWordDiff(input, grammarResult.corrected);
      setDiff(wordDiff);

      // Save to history
      const entry = {
        id: crypto.randomUUID(),
        original: input,
        corrected: grammarResult.corrected,
        explanation: grammarResult.explanation,
        provider: prefs.provider,
        model,
        timestamp: new Date().toISOString(),
        profileName: activeProfile?.name,
      };
      await saveToHistory(storage, entry);

      toast.success("Grammar check complete");
    } catch (err) {
      toast.error(
        `Check failed: ${err instanceof Error ? err.message : "Unknown error"}`,
      );
    } finally {
      setLoading(false);
    }
  }, [input, prefs, model, profiles, activeProfileId]);

  const handleCopy = useCallback(async () => {
    if (!result) return;
    await navigator.clipboard.writeText(result.corrected);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, [result]);

  const handleProfileChange = useCallback(
    async (id: string) => {
      setActiveProfileState(id);
      if (id) {
        await setActiveProfileId(storage, id);
      }
    },
    [],
  );

  return (
    <div className="flex h-full flex-col gap-4">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-bold">Check Grammar</h2>
          <p className="text-muted-foreground">
            Enter text and get AI-powered grammar corrections.
          </p>
        </div>
      </div>

      {/* Controls row */}
      <div className="flex gap-3">
        <div className="w-48">
          <Label className="mb-1 block text-xs">Model</Label>
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
        </div>

        <div className="w-48">
          <Label className="mb-1 block text-xs">Profile</Label>
          <Select value={activeProfileId} onValueChange={handleProfileChange}>
            <SelectTrigger className="h-8 text-xs">
              <SelectValue placeholder="No profile" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="none">No profile</SelectItem>
              {profiles.map((p) => (
                <SelectItem key={p.id} value={p.id}>
                  {p.name}
                  {p.isDefault ? " (default)" : ""}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        <div className="flex items-end">
          <Button
            onClick={handleCheck}
            disabled={loading || !input.trim()}
            className="gap-2"
            size="sm"
          >
            {loading ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
              <SpellCheck className="h-4 w-4" />
            )}
            {loading ? "Checking..." : "Check Grammar"}
          </Button>
        </div>
      </div>

      {/* Split pane */}
      <div className="grid flex-1 grid-cols-2 gap-4 min-h-0">
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
        <div className="flex flex-col gap-2 min-h-0">
          <div className="flex items-center justify-between">
            <Label>Result</Label>
            {result && (
              <Button
                variant="ghost"
                size="sm"
                onClick={handleCopy}
                className="h-6 gap-1 text-xs"
              >
                {copied ? (
                  <Check className="h-3 w-3" />
                ) : (
                  <Copy className="h-3 w-3" />
                )}
                {copied ? "Copied" : "Copy"}
              </Button>
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
              <Card>
                <CardHeader className="pb-2">
                  <CardTitle className="text-sm">Diff</CardTitle>
                </CardHeader>
                <CardContent>
                  <DiffView diff={diff} className="text-sm" />
                </CardContent>
              </Card>

              <Card>
                <CardHeader className="pb-2">
                  <CardTitle className="text-sm">Corrected Text</CardTitle>
                </CardHeader>
                <CardContent>
                  <p className="text-sm whitespace-pre-wrap">
                    {result.corrected}
                  </p>
                </CardContent>
              </Card>

              <Card>
                <CardHeader className="pb-2">
                  <CardTitle className="text-sm">Explanation</CardTitle>
                </CardHeader>
                <CardContent>
                  <p className="text-sm text-muted-foreground">
                    {result.explanation}
                  </p>
                </CardContent>
              </Card>
            </div>
          )}

          {!loading && !result && (
            <div className="flex flex-1 items-center justify-center rounded-md border border-dashed">
              <p className="text-sm text-muted-foreground">
                Results will appear here
              </p>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
