import { useState, useEffect, useCallback } from "react";
import { toast } from "sonner";
import type {
  LlmProvider,
  Preferences,
  ModelOption,
  OpenAICodexAuthFlow,
} from "@bex/core";
import {
  fetchModels,
  DEFAULT_MODELS,
  beginOpenAICodexOAuth,
  completeOpenAICodexOAuth,
  applyOpenAICodexSessionToPreferences,
} from "@bex/core";
import { storage } from "@/lib/tauri-storage";
import { invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";
import {
  applyAppTheme,
  normalizeAppTheme,
  normalizeAppColorMode,
  parsePreferences,
  syncAppColorMode,
  type AppTheme,
  type AppColorMode,
  DEFAULT_APP_THEME,
  DEFAULT_APP_COLOR_MODE,
} from "@/lib/app-theme";
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
import {
  Loader2,
  Eye,
  EyeOff,
  Save,
  RotateCcw,
  Link2,
  LogOut,
} from "lucide-react";

const PREFS_KEY = "preferences";
const PROVIDERS: { value: LlmProvider; label: string }[] = [
  { value: "openai", label: "OpenAI (API Key)" },
  { value: "openai-codex", label: "OpenAI Codex (ChatGPT OAuth)" },
  { value: "claude", label: "Claude (Anthropic)" },
  { value: "gemini", label: "Gemini (Google)" },
  { value: "ollama", label: "Ollama (Local)" },
];

const APP_THEMES: { value: AppTheme; label: string; description: string }[] = [
  {
    value: "hig-glass",
    label: "HIG Glass",
    description: "Transparent surfaces with blur and depth.",
  },
  {
    value: "hig-solid",
    label: "HIG Solid",
    description: "Opaque surfaces with maximum clarity.",
  },
];

const APP_COLOR_MODES: {
  value: AppColorMode;
  label: string;
  description: string;
}[] = [
  {
    value: "light",
    label: "Light",
    description: "Bright interface with neutral backgrounds.",
  },
  {
    value: "black",
    label: "Black",
    description: "Dark interface with near-black surfaces.",
  },
  {
    value: "system",
    label: "System",
    description: "Automatically follows your macOS appearance.",
  },
];

export default function Settings() {
  const [provider, setProvider] = useState<LlmProvider>("openai");
  const [openaiApiKey, setOpenaiApiKey] = useState("");
  const [openaiCodexAccessToken, setOpenaiCodexAccessToken] = useState("");
  const [openaiCodexRefreshToken, setOpenaiCodexRefreshToken] = useState("");
  const [openaiCodexAccountId, setOpenaiCodexAccountId] = useState("");
  const [openaiCodexExpiresAt, setOpenaiCodexExpiresAt] = useState<number>(0);
  const [claudeApiKey, setClaudeApiKey] = useState("");
  const [geminiApiKey, setGeminiApiKey] = useState("");
  const [ollamaUrl, setOllamaUrl] = useState("http://localhost:11434");
  const [model, setModel] = useState("");
  const [models, setModels] = useState<ModelOption[]>([]);
  const [loadingModels, setLoadingModels] = useState(false);
  const [modelError, setModelError] = useState<string | null>(null);
  const [appTheme, setAppTheme] = useState<AppTheme>(DEFAULT_APP_THEME);
  const [appColorMode, setAppColorMode] =
    useState<AppColorMode>(DEFAULT_APP_COLOR_MODE);
  const [saving, setSaving] = useState(false);
  const [showKeys, setShowKeys] = useState<Record<string, boolean>>({});
  const [loaded, setLoaded] = useState(false);
  const [codexAuthFlow, setCodexAuthFlow] =
    useState<OpenAICodexAuthFlow | null>(null);
  const [connectingCodex, setConnectingCodex] = useState(false);
  const [disconnectingCodex, setDisconnectingCodex] = useState(false);

  // Load preferences on mount
  useEffect(() => {
    (async () => {
      const raw = await storage.getItem<unknown>(PREFS_KEY);
      const prefs = parsePreferences(raw);

      if (prefs) {
        setProvider(prefs.provider || "openai");
        setOpenaiApiKey(prefs.openaiApiKey || "");
        setOpenaiCodexAccessToken(prefs.openaiCodexAccessToken || "");
        setOpenaiCodexRefreshToken(prefs.openaiCodexRefreshToken || "");
        setOpenaiCodexAccountId(prefs.openaiCodexAccountId || "");
        setOpenaiCodexExpiresAt(prefs.openaiCodexExpiresAt || 0);
        setClaudeApiKey(prefs.claudeApiKey || "");
        setGeminiApiKey(prefs.geminiApiKey || "");
        setOllamaUrl(prefs.ollamaUrl || "http://localhost:11434");
        setModel(prefs.model || "");
        setAppTheme(normalizeAppTheme(prefs.appTheme));
        setAppColorMode(normalizeAppColorMode(prefs.appColorMode));
      }
      setLoaded(true);
    })();
  }, []);

  // Live preview theme changes for quick compare
  useEffect(() => {
    applyAppTheme(appTheme);
  }, [appTheme]);

  useEffect(() => {
    return syncAppColorMode(appColorMode);
  }, [appColorMode]);

  const buildPrefs = useCallback((): Preferences => {
    return {
      provider,
      openaiApiKey: openaiApiKey || undefined,
      openaiCodexAccessToken: openaiCodexAccessToken || undefined,
      openaiCodexRefreshToken: openaiCodexRefreshToken || undefined,
      openaiCodexExpiresAt: openaiCodexExpiresAt || undefined,
      openaiCodexAccountId: openaiCodexAccountId || undefined,
      claudeApiKey: claudeApiKey || undefined,
      geminiApiKey: geminiApiKey || undefined,
      ollamaUrl: ollamaUrl || undefined,
      model: model || undefined,
      appTheme,
      appColorMode,
    };
  }, [
    provider,
    openaiApiKey,
    openaiCodexAccessToken,
    openaiCodexRefreshToken,
    openaiCodexExpiresAt,
    openaiCodexAccountId,
    claudeApiKey,
    geminiApiKey,
    ollamaUrl,
    model,
    appTheme,
    appColorMode,
  ]);

  const refreshModels = useCallback(async () => {
    if (!loaded) return;

    const prefs: Preferences = {
      provider,
      openaiApiKey: openaiApiKey || undefined,
      openaiCodexAccessToken: openaiCodexAccessToken || undefined,
      openaiCodexRefreshToken: openaiCodexRefreshToken || undefined,
      openaiCodexExpiresAt: openaiCodexExpiresAt || undefined,
      openaiCodexAccountId: openaiCodexAccountId || undefined,
      claudeApiKey: claudeApiKey || undefined,
      geminiApiKey: geminiApiKey || undefined,
      ollamaUrl: ollamaUrl || undefined,
    };

    setLoadingModels(true);
    try {
      const result = await fetchModels(provider, prefs);
      setModels(result);

      const hasCredentials =
        provider === "ollama" ||
        (provider === "openai" && !!openaiApiKey) ||
        (provider === "openai-codex" && !!openaiCodexRefreshToken) ||
        (provider === "claude" && !!claudeApiKey) ||
        (provider === "gemini" && !!geminiApiKey);

      if (result.length === 0 && hasCredentials) {
        setModelError("Could not fetch models. Using provider default.");
      } else {
        setModelError(null);
      }

      if (!model || !result.some((m) => m.id === model)) {
        setModel(DEFAULT_MODELS[provider]);
      }
    } catch {
      setModels([]);
      setModelError("Could not fetch models. Check network/API access.");
      if (!model) {
        setModel(DEFAULT_MODELS[provider]);
      }
    } finally {
      setLoadingModels(false);
    }
  }, [
    provider,
    openaiApiKey,
    openaiCodexAccessToken,
    openaiCodexRefreshToken,
    openaiCodexExpiresAt,
    openaiCodexAccountId,
    claudeApiKey,
    geminiApiKey,
    ollamaUrl,
    loaded,
    model,
  ]);

  // Fetch models when provider or keys change
  useEffect(() => {
    void refreshModels();
  }, [refreshModels]);

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

  const codexConnected =
    !!openaiCodexRefreshToken && !!openaiCodexAccountId;
  const codexExpiryLabel = openaiCodexExpiresAt
    ? new Date(openaiCodexExpiresAt).toLocaleString()
    : null;

  const handleConnectCodex = async () => {
    setConnectingCodex(true);
    try {
      const flow = codexAuthFlow || (await beginOpenAICodexOAuth("bex"));
      setCodexAuthFlow(flow);

      const callbackPromise = invoke<string>("openai_codex_wait_for_callback", {
        payload: {
          state: flow.state,
          timeoutMs: 180_000,
        },
      });

      await openUrl(flow.url);
      toast.message("Waiting for ChatGPT login...", {
        description: "Complete the browser sign-in. Bex will finish automatically.",
      });

      let callbackUrl: string;
      try {
        callbackUrl = await callbackPromise;
      } catch {
        const pasted = window.prompt(
          "Automatic callback capture failed. Paste the full callback URL from your browser.",
        );
        if (!pasted) {
          toast.message("Login not completed", {
            description: "You can run Connect again anytime.",
          });
          return;
        }
        callbackUrl = pasted;
      }

      const session = await completeOpenAICodexOAuth(flow, callbackUrl);
      const nextPrefs = applyOpenAICodexSessionToPreferences(buildPrefs(), session);

      setOpenaiCodexAccessToken(session.accessToken);
      setOpenaiCodexRefreshToken(session.refreshToken);
      setOpenaiCodexAccountId(session.accountId);
      setOpenaiCodexExpiresAt(session.expiresAt);
      setCodexAuthFlow(null);

      await storage.setItem(PREFS_KEY, JSON.stringify(nextPrefs));

      setModel((current) => current || DEFAULT_MODELS["openai-codex"]);
      void refreshModels();

      toast.success("Connected to OpenAI Codex");
    } catch (err) {
      toast.error(
        `Codex login failed: ${err instanceof Error ? err.message : "Unknown error"}`,
      );
    } finally {
      setConnectingCodex(false);
    }
  };

  const handleDisconnectCodex = async () => {
    setDisconnectingCodex(true);
    try {
      setOpenaiCodexAccessToken("");
      setOpenaiCodexRefreshToken("");
      setOpenaiCodexAccountId("");
      setOpenaiCodexExpiresAt(0);
      setCodexAuthFlow(null);

      const nextPrefs: Preferences = {
        ...buildPrefs(),
        openaiCodexAccessToken: undefined,
        openaiCodexRefreshToken: undefined,
        openaiCodexExpiresAt: undefined,
        openaiCodexAccountId: undefined,
      };

      await storage.setItem(PREFS_KEY, JSON.stringify(nextPrefs));
      toast.success("Disconnected from OpenAI Codex");
    } catch (err) {
      toast.error(
        `Failed to disconnect Codex: ${err instanceof Error ? err.message : "Unknown error"}`,
      );
    } finally {
      setDisconnectingCodex(false);
    }
  };

  return (
    <div className="max-w-2xl space-y-6">
      <div>
        <h2 className="text-2xl font-bold">Settings</h2>
        <p className="text-muted-foreground leading-relaxed">
          Configure appearance, provider, credentials, and default model.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Appearance</CardTitle>
          <CardDescription>
            Choose surface style and color mode. Changes preview immediately.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label>Surface style</Label>
            <Select value={appTheme} onValueChange={(v) => setAppTheme(v as AppTheme)}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {APP_THEMES.map((theme) => (
                  <SelectItem key={theme.value} value={theme.value}>
                    {theme.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <p className="text-xs leading-relaxed text-muted-foreground">
              {APP_THEMES.find((theme) => theme.value === appTheme)?.description}
            </p>
          </div>

          <div className="space-y-2">
            <Label>Color mode</Label>
            <Select
              value={appColorMode}
              onValueChange={(value) => setAppColorMode(value as AppColorMode)}
            >
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {APP_COLOR_MODES.map((mode) => (
                  <SelectItem key={mode.value} value={mode.value}>
                    {mode.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <p className="text-xs leading-relaxed text-muted-foreground">
              {APP_COLOR_MODES.find((mode) => mode.value === appColorMode)?.description}
            </p>
          </div>
        </CardContent>
      </Card>

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

          {provider === "openai-codex" && (
            <div className="space-y-3 rounded-md border p-3">
              <div className="space-y-1">
                <Label>ChatGPT OAuth</Label>
                <p className="text-xs leading-relaxed text-muted-foreground">
                  Use your ChatGPT Plus/Pro account. No OpenAI API key required.
                </p>
                <p className="text-xs text-muted-foreground">
                  Status: {codexConnected ? "Connected" : "Not connected"}
                  {codexConnected && codexExpiryLabel ? ` · Expires: ${codexExpiryLabel}` : ""}
                </p>
              </div>

              <div className="flex flex-wrap gap-2">
                <Button
                  type="button"
                  size="sm"
                  className="gap-2"
                  onClick={() => void handleConnectCodex()}
                  disabled={connectingCodex || disconnectingCodex}
                >
                  {connectingCodex ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    <Link2 className="h-4 w-4" />
                  )}
                  {codexConnected ? "Reconnect ChatGPT" : "Connect ChatGPT"}
                </Button>

                {codexConnected && (
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    className="gap-2"
                    onClick={() => void handleDisconnectCodex()}
                    disabled={connectingCodex || disconnectingCodex}
                  >
                    {disconnectingCodex ? (
                      <Loader2 className="h-4 w-4 animate-spin" />
                    ) : (
                      <LogOut className="h-4 w-4" />
                    )}
                    Disconnect
                  </Button>
                )}
              </div>

              <p className="text-xs leading-relaxed text-muted-foreground">
                Login completes automatically after browser sign-in.
              </p>
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
            {modelError && (
              <div className="flex items-center gap-2">
                <p className="text-xs leading-relaxed text-muted-foreground">{modelError}</p>
                <Button
                  variant="ghost"
                  size="sm"
                  className="h-6 px-2 text-xs"
                  onClick={() => void refreshModels()}
                >
                  <RotateCcw className="h-3 w-3" />
                  Retry
                </Button>
              </div>
            )}
          </div>
        </CardContent>
      </Card>

      <Button onClick={handleSave} disabled={saving} className="gap-2">
        {saving ? (
          <Loader2 className="h-4 w-4 animate-spin" />
        ) : (
          <Save className="h-4 w-4" />
        )}
        Save settings
      </Button>
    </div>
  );
}
