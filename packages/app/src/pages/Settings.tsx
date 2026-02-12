import { useState, useEffect, useCallback } from "react";
import { toast } from "sonner";
import type { LlmProvider, Preferences, ModelOption } from "@bex/core";
import { fetchModels, DEFAULT_MODELS } from "@bex/core";
import { storage } from "@/lib/tauri-storage";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Card,
  CardContent,
  CardDescription,
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
import { Loader2, Eye, EyeOff, Save } from "lucide-react";

const PREFS_KEY = "preferences";
const PROVIDERS: { value: LlmProvider; label: string }[] = [
  { value: "openai", label: "OpenAI" },
  { value: "claude", label: "Claude (Anthropic)" },
  { value: "gemini", label: "Gemini (Google)" },
  { value: "ollama", label: "Ollama (Local)" },
];

export default function Settings() {
  const [provider, setProvider] = useState<LlmProvider>("openai");
  const [openaiApiKey, setOpenaiApiKey] = useState("");
  const [claudeApiKey, setClaudeApiKey] = useState("");
  const [geminiApiKey, setGeminiApiKey] = useState("");
  const [ollamaUrl, setOllamaUrl] = useState("http://localhost:11434");
  const [model, setModel] = useState("");
  const [models, setModels] = useState<ModelOption[]>([]);
  const [loadingModels, setLoadingModels] = useState(false);
  const [saving, setSaving] = useState(false);
  const [showKeys, setShowKeys] = useState<Record<string, boolean>>({});
  const [loaded, setLoaded] = useState(false);

  // Load preferences on mount
  useEffect(() => {
    (async () => {
      const raw = await storage.getItem<string>(PREFS_KEY);
      if (raw) {
        try {
          const prefs: Preferences = JSON.parse(raw);
          setProvider(prefs.provider || "openai");
          setOpenaiApiKey(prefs.openaiApiKey || "");
          setClaudeApiKey(prefs.claudeApiKey || "");
          setGeminiApiKey(prefs.geminiApiKey || "");
          setOllamaUrl(prefs.ollamaUrl || "http://localhost:11434");
          setModel(prefs.model || "");
        } catch {
          // ignore malformed prefs
        }
      }
      setLoaded(true);
    })();
  }, []);

  const buildPrefs = useCallback((): Preferences => {
    return {
      provider,
      openaiApiKey: openaiApiKey || undefined,
      claudeApiKey: claudeApiKey || undefined,
      geminiApiKey: geminiApiKey || undefined,
      ollamaUrl: ollamaUrl || undefined,
      model: model || undefined,
    };
  }, [provider, openaiApiKey, claudeApiKey, geminiApiKey, ollamaUrl, model]);

  // Fetch models when provider or keys change
  useEffect(() => {
    if (!loaded) return;
    const prefs = buildPrefs();
    setLoadingModels(true);
    fetchModels(provider, prefs)
      .then((result) => {
        setModels(result);
        if (!model || !result.some((m) => m.id === model)) {
          setModel(DEFAULT_MODELS[provider]);
        }
      })
      .catch(() => setModels([]))
      .finally(() => setLoadingModels(false));
  }, [provider, openaiApiKey, claudeApiKey, geminiApiKey, ollamaUrl, loaded, buildPrefs, model]);

  const handleSave = async () => {
    setSaving(true);
    try {
      const prefs = buildPrefs();
      await storage.setItem(PREFS_KEY, JSON.stringify(prefs));
      toast.success("Settings saved");
    } catch (err) {
      toast.error(
        `Failed to save: ${err instanceof Error ? err.message : "Unknown error"}`,
      );
    } finally {
      setSaving(false);
    }
  };

  const toggleKeyVisibility = (key: string) => {
    setShowKeys((prev) => ({ ...prev, [key]: !prev[key] }));
  };

  return (
    <div className="max-w-2xl space-y-6">
      <div>
        <h2 className="text-2xl font-bold">Settings</h2>
        <p className="text-muted-foreground">
          Configure your LLM provider, API keys, and default model.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>LLM Provider</CardTitle>
          <CardDescription>
            Select which AI service to use for grammar checking.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label>Provider</Label>
            <Select
              value={provider}
              onValueChange={(v) => setProvider(v as LlmProvider)}
            >
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {PROVIDERS.map((p) => (
                  <SelectItem key={p.value} value={p.value}>
                    {p.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          {provider === "openai" && (
            <div className="space-y-2">
              <Label>OpenAI API Key</Label>
              <div className="flex gap-2">
                <Input
                  type={showKeys["openai"] ? "text" : "password"}
                  value={openaiApiKey}
                  onChange={(e) => setOpenaiApiKey(e.target.value)}
                  placeholder="sk-..."
                />
                <Button
                  variant="outline"
                  size="icon"
                  onClick={() => toggleKeyVisibility("openai")}
                >
                  {showKeys["openai"] ? (
                    <EyeOff className="h-4 w-4" />
                  ) : (
                    <Eye className="h-4 w-4" />
                  )}
                </Button>
              </div>
            </div>
          )}

          {provider === "claude" && (
            <div className="space-y-2">
              <Label>Anthropic API Key</Label>
              <div className="flex gap-2">
                <Input
                  type={showKeys["claude"] ? "text" : "password"}
                  value={claudeApiKey}
                  onChange={(e) => setClaudeApiKey(e.target.value)}
                  placeholder="sk-ant-..."
                />
                <Button
                  variant="outline"
                  size="icon"
                  onClick={() => toggleKeyVisibility("claude")}
                >
                  {showKeys["claude"] ? (
                    <EyeOff className="h-4 w-4" />
                  ) : (
                    <Eye className="h-4 w-4" />
                  )}
                </Button>
              </div>
            </div>
          )}

          {provider === "gemini" && (
            <div className="space-y-2">
              <Label>Gemini API Key</Label>
              <div className="flex gap-2">
                <Input
                  type={showKeys["gemini"] ? "text" : "password"}
                  value={geminiApiKey}
                  onChange={(e) => setGeminiApiKey(e.target.value)}
                  placeholder="AI..."
                />
                <Button
                  variant="outline"
                  size="icon"
                  onClick={() => toggleKeyVisibility("gemini")}
                >
                  {showKeys["gemini"] ? (
                    <EyeOff className="h-4 w-4" />
                  ) : (
                    <Eye className="h-4 w-4" />
                  )}
                </Button>
              </div>
            </div>
          )}

          {provider === "ollama" && (
            <div className="space-y-2">
              <Label>Ollama URL</Label>
              <Input
                value={ollamaUrl}
                onChange={(e) => setOllamaUrl(e.target.value)}
                placeholder="http://localhost:11434"
              />
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Model</CardTitle>
          <CardDescription>
            Choose the default model for grammar checking.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label>Default Model</Label>
            <Select value={model} onValueChange={setModel}>
              <SelectTrigger>
                {loadingModels ? (
                  <div className="flex items-center gap-2">
                    <Loader2 className="h-4 w-4 animate-spin" />
                    Loading models...
                  </div>
                ) : (
                  <SelectValue placeholder="Select a model" />
                )}
              </SelectTrigger>
              <SelectContent>
                {models.map((m) => (
                  <SelectItem key={m.id} value={m.id}>
                    {m.name}
                  </SelectItem>
                ))}
                {models.length === 0 && !loadingModels && (
                  <SelectItem value={DEFAULT_MODELS[provider]} disabled={false}>
                    {DEFAULT_MODELS[provider]} (default)
                  </SelectItem>
                )}
              </SelectContent>
            </Select>
          </div>
        </CardContent>
      </Card>

      <Button onClick={handleSave} disabled={saving} className="gap-2">
        {saving ? (
          <Loader2 className="h-4 w-4 animate-spin" />
        ) : (
          <Save className="h-4 w-4" />
        )}
        Save Settings
      </Button>
    </div>
  );
}
