import { useState, useEffect, useCallback, useRef } from "react";
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
} from "@bex/core";
import { storage } from "@/lib/tauri-storage";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { DiffView } from "@/components/DiffView";
import { Loader2, SpellCheck, Copy, Check } from "lucide-react";
import { Toaster } from "sonner";

const PREFS_KEY = "preferences";

export default function Popup() {
  const [input, setInput] = useState("");
  const [result, setResult] = useState<GrammarResult | null>(null);
  const [diff, setDiff] = useState<DiffWord[]>([]);
  const [loading, setLoading] = useState(false);
  const [copied, setCopied] = useState(false);

  const prefsRef = useRef<Preferences | null>(null);
  const profilesRef = useRef<Profile[]>([]);
  const activeProfileIdRef = useRef<string>("");
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  // Load prefs + profiles on mount
  useEffect(() => {
    (async () => {
      const raw = await storage.getItem<string>(PREFS_KEY);
      if (raw) {
        try {
          prefsRef.current = JSON.parse(raw);
        } catch {
          // fallback
        }
      }

      const profileList = await loadProfiles(storage);
      profilesRef.current = profileList;
      const activeId = await getActiveProfileId(storage);
      if (activeId) {
        activeProfileIdRef.current = activeId;
      } else {
        const def = getDefaultProfile(profileList);
        if (def) activeProfileIdRef.current = def.id;
      }
    })();

    // Auto-focus textarea
    textareaRef.current?.focus();
  }, []);

  // Keyboard shortcuts
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        getCurrentWindow().close();
      }
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault();
        handleCheck();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  });

  const handleCheck = useCallback(async () => {
    if (!input.trim()) {
      toast.error("Enter some text to check");
      return;
    }
    const prefs = prefsRef.current;
    if (!prefs) {
      toast.error("Configure settings in the main app first");
      return;
    }

    setLoading(true);
    setResult(null);
    setDiff([]);

    try {
      const profiles = profilesRef.current;
      const activeProfile = profiles.find(
        (p) => p.id === activeProfileIdRef.current,
      );
      const systemPrompt = buildSystemPrompt(activeProfile?.prompt);
      const model = prefs.model || DEFAULT_MODELS[prefs.provider];
      const checkPrefs: Preferences = { ...prefs, model };

      const grammarResult = await checkGrammar(
        input,
        checkPrefs,
        undefined,
        systemPrompt,
      );

      setResult(grammarResult);
      setDiff(computeWordDiff(input, grammarResult.corrected));

      // Save to history
      await saveToHistory(storage, {
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
  }, [input]);

  const handleCopy = useCallback(async () => {
    if (!result) return;
    await navigator.clipboard.writeText(result.corrected);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, [result]);

  return (
    <div className="flex h-screen flex-col gap-3 p-4 overflow-hidden">
      <Toaster position="top-center" richColors />

      <div className="flex items-center justify-between">
        <h1 className="text-lg font-semibold">Quick Check</h1>
        <div className="flex gap-2">
          {result && (
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
          )}
          <Button
            onClick={handleCheck}
            disabled={loading || !input.trim()}
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

      <Textarea
        ref={textareaRef}
        value={input}
        onChange={(e) => setInput(e.target.value)}
        placeholder="Type or paste text here... (⌘+Enter to check, Esc to close)"
        className="min-h-[100px] flex-shrink-0 resize-none"
        rows={4}
      />

      <div className="flex-1 overflow-auto min-h-0">
        {loading && (
          <div className="flex h-full items-center justify-center">
            <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
          </div>
        )}

        {!loading && result && (
          <div className="flex flex-col gap-3">
            <div>
              <p className="mb-1 text-xs font-medium text-muted-foreground">
                Diff
              </p>
              <DiffView diff={diff} className="text-sm" />
            </div>

            <div>
              <p className="mb-1 text-xs font-medium text-muted-foreground">
                Corrected
              </p>
              <p className="text-sm whitespace-pre-wrap rounded-md border p-2">
                {result.corrected}
              </p>
            </div>

            {result.explanation && (
              <div>
                <p className="mb-1 text-xs font-medium text-muted-foreground">
                  Explanation
                </p>
                <p className="text-sm text-muted-foreground whitespace-pre-wrap">
                  {result.explanation}
                </p>
              </div>
            )}
          </div>
        )}

        {!loading && !result && (
          <div className="flex h-full items-center justify-center rounded-md border border-dashed">
            <p className="text-sm text-muted-foreground">
              Results will appear here
            </p>
          </div>
        )}
      </div>
    </div>
  );
}
