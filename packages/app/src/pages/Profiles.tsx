import { useState, useEffect, useCallback } from "react";
import { toast } from "sonner";
import type { Profile, Preferences } from "@bex/core";
import {
  loadProfiles,
  saveProfiles,
  generateText,
  PROFILE_GENERATION_PROMPT,
} from "@bex/core";
import { storage } from "@/lib/tauri-storage";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
  Plus,
  Pencil,
  Trash2,
  Star,
  Wand2,
  Loader2,
} from "lucide-react";

const PREFS_KEY = "preferences";

interface ProfileFormData {
  name: string;
  prompt: string;
  isDefault: boolean;
}

interface WizardData {
  role: string;
  audience: string;
  tone: string;
  formality: string;
  domain: string;
  notes: string;
}

export default function Profiles() {
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [editingProfile, setEditingProfile] = useState<Profile | null>(null);
  const [isCreating, setIsCreating] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<Profile | null>(null);
  const [showWizard, setShowWizard] = useState(false);
  const [wizardLoading, setWizardLoading] = useState(false);

  const [form, setForm] = useState<ProfileFormData>({
    name: "",
    prompt: "",
    isDefault: false,
  });

  const [wizard, setWizard] = useState<WizardData>({
    role: "",
    audience: "",
    tone: "",
    formality: "",
    domain: "",
    notes: "",
  });

  const refresh = useCallback(async () => {
    const list = await loadProfiles(storage);
    setProfiles(list);
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  const resetForm = () => {
    setForm({ name: "", prompt: "", isDefault: false });
    setWizard({
      role: "",
      audience: "",
      tone: "",
      formality: "",
      domain: "",
      notes: "",
    });
  };

  const openCreate = () => {
    resetForm();
    setEditingProfile(null);
    setIsCreating(true);
    setShowWizard(false);
  };

  const openEdit = (profile: Profile) => {
    setForm({
      name: profile.name,
      prompt: profile.prompt,
      isDefault: !!profile.isDefault,
    });
    setEditingProfile(profile);
    setIsCreating(true);
    setShowWizard(false);
  };

  const handleSave = async () => {
    if (!form.name.trim()) {
      toast.error("Profile name is required");
      return;
    }

    let updated: Profile[];
    if (editingProfile) {
      updated = profiles.map((p) =>
        p.id === editingProfile.id
          ? { ...p, name: form.name, prompt: form.prompt, isDefault: form.isDefault }
          : form.isDefault
            ? { ...p, isDefault: false }
            : p,
      );
    } else {
      const newProfile: Profile = {
        id: crypto.randomUUID(),
        name: form.name,
        prompt: form.prompt,
        isDefault: form.isDefault,
      };
      updated = form.isDefault
        ? [...profiles.map((p) => ({ ...p, isDefault: false })), newProfile]
        : [...profiles, newProfile];
    }

    await saveProfiles(storage, updated);
    toast.success(editingProfile ? "Profile updated" : "Profile created");
    setIsCreating(false);
    refresh();
  };

  const handleDelete = async () => {
    if (!deleteTarget) return;
    const updated = profiles.filter((p) => p.id !== deleteTarget.id);
    await saveProfiles(storage, updated);
    toast.success("Profile deleted");
    setDeleteTarget(null);
    refresh();
  };

  const handleSetDefault = async (profile: Profile) => {
    const updated = profiles.map((p) => ({
      ...p,
      isDefault: p.id === profile.id,
    }));
    await saveProfiles(storage, updated);
    toast.success(`${profile.name} set as default`);
    refresh();
  };

  const handleWizardGenerate = async () => {
    const prefsRaw = await storage.getItem<string>(PREFS_KEY);
    if (!prefsRaw) {
      toast.error("Please configure settings first");
      return;
    }
    let prefs: Preferences;
    try {
      prefs = JSON.parse(prefsRaw);
    } catch {
      toast.error("Invalid settings");
      return;
    }

    const userMessage = [
      wizard.role && `Role: ${wizard.role}`,
      wizard.audience && `Audience: ${wizard.audience}`,
      wizard.tone && `Tone: ${wizard.tone}`,
      wizard.formality && `Formality: ${wizard.formality}`,
      wizard.domain && `Domain: ${wizard.domain}`,
      wizard.notes && `Additional notes: ${wizard.notes}`,
    ]
      .filter(Boolean)
      .join("\n");

    if (!userMessage) {
      toast.error("Please fill in at least one field");
      return;
    }

    setWizardLoading(true);
    try {
      const generatedPrompt = await generateText(
        PROFILE_GENERATION_PROMPT,
        userMessage,
        prefs,
      );
      setForm((prev) => ({ ...prev, prompt: generatedPrompt }));
      setShowWizard(false);
      toast.success("Profile prompt generated");
    } catch (err) {
      toast.error(
        `Generation failed: ${err instanceof Error ? err.message : "Unknown error"}`,
      );
    } finally {
      setWizardLoading(false);
    }
  };

  return (
    <div className="flex h-full flex-col gap-4">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-bold">Profiles</h2>
          <p className="text-muted-foreground">
            Manage writing profiles for grammar checking context.
          </p>
        </div>
        <Button size="sm" onClick={openCreate} className="gap-2">
          <Plus className="h-4 w-4" />
          New Profile
        </Button>
      </div>

      {profiles.length === 0 ? (
        <div className="flex flex-1 items-center justify-center rounded-md border border-dashed">
          <p className="text-sm text-muted-foreground">
            No profiles yet. Create one to add context to grammar checks.
          </p>
        </div>
      ) : (
        <ScrollArea className="flex-1">
          <div className="space-y-2 pr-4">
            {profiles.map((profile) => (
              <Card key={profile.id}>
                <CardHeader className="py-3">
                  <div className="flex items-center justify-between">
                    <div className="flex items-center gap-2">
                      <CardTitle className="text-sm">
                        {profile.name}
                      </CardTitle>
                      {profile.isDefault && (
                        <Star className="h-3 w-3 fill-yellow-400 text-yellow-400" />
                      )}
                    </div>
                    <div className="flex items-center gap-1">
                      {!profile.isDefault && (
                        <Button
                          variant="ghost"
                          size="icon"
                          className="h-7 w-7"
                          onClick={() => handleSetDefault(profile)}
                          title="Set as default"
                        >
                          <Star className="h-3 w-3" />
                        </Button>
                      )}
                      <Button
                        variant="ghost"
                        size="icon"
                        className="h-7 w-7"
                        onClick={() => openEdit(profile)}
                      >
                        <Pencil className="h-3 w-3" />
                      </Button>
                      <Button
                        variant="ghost"
                        size="icon"
                        className="h-7 w-7"
                        onClick={() => setDeleteTarget(profile)}
                      >
                        <Trash2 className="h-3 w-3" />
                      </Button>
                    </div>
                  </div>
                </CardHeader>
                <CardContent className="pt-0">
                  <p className="text-sm text-muted-foreground line-clamp-2">
                    {profile.prompt || "No prompt set"}
                  </p>
                </CardContent>
              </Card>
            ))}
          </div>
        </ScrollArea>
      )}

      {/* Create/Edit Dialog */}
      <Dialog open={isCreating} onOpenChange={setIsCreating}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle>
              {editingProfile ? "Edit Profile" : "Create Profile"}
            </DialogTitle>
          </DialogHeader>

          {!showWizard ? (
            <div className="space-y-4">
              <div className="space-y-2">
                <Label>Name</Label>
                <Input
                  value={form.name}
                  onChange={(e) =>
                    setForm((prev) => ({ ...prev, name: e.target.value }))
                  }
                  placeholder="e.g., Professional Emails"
                />
              </div>

              <div className="space-y-2">
                <div className="flex items-center justify-between">
                  <Label>Prompt</Label>
                  <Button
                    variant="outline"
                    size="sm"
                    className="gap-1 h-7 text-xs"
                    onClick={() => setShowWizard(true)}
                  >
                    <Wand2 className="h-3 w-3" />
                    AI Wizard
                  </Button>
                </div>
                <Textarea
                  value={form.prompt}
                  onChange={(e) =>
                    setForm((prev) => ({ ...prev, prompt: e.target.value }))
                  }
                  placeholder="Instructions for the grammar checker..."
                  rows={4}
                />
              </div>

              <div className="flex items-center gap-2">
                <input
                  type="checkbox"
                  id="isDefault"
                  checked={form.isDefault}
                  onChange={(e) =>
                    setForm((prev) => ({
                      ...prev,
                      isDefault: e.target.checked,
                    }))
                  }
                  className="rounded"
                />
                <Label htmlFor="isDefault">Set as default profile</Label>
              </div>
            </div>
          ) : (
            <div className="space-y-3">
              <p className="text-sm text-muted-foreground">
                Fill in the fields below and AI will generate a profile prompt.
              </p>
              {(
                [
                  ["role", "Role", "e.g., Software Engineer"],
                  ["audience", "Audience", "e.g., Technical team members"],
                  ["tone", "Tone", "e.g., Professional, Friendly"],
                  ["formality", "Formality", "e.g., Formal, Casual"],
                  ["domain", "Domain", "e.g., Technology, Marketing"],
                  ["notes", "Additional Notes", "Any other context..."],
                ] as const
              ).map(([key, label, placeholder]) => (
                <div key={key} className="space-y-1">
                  <Label className="text-xs">{label}</Label>
                  <Input
                    value={wizard[key]}
                    onChange={(e) =>
                      setWizard((prev) => ({
                        ...prev,
                        [key]: e.target.value,
                      }))
                    }
                    placeholder={placeholder}
                    className="h-8 text-sm"
                  />
                </div>
              ))}
            </div>
          )}

          <DialogFooter>
            {showWizard ? (
              <>
                <Button
                  variant="outline"
                  onClick={() => setShowWizard(false)}
                >
                  Back
                </Button>
                <Button
                  onClick={handleWizardGenerate}
                  disabled={wizardLoading}
                  className="gap-2"
                >
                  {wizardLoading ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    <Wand2 className="h-4 w-4" />
                  )}
                  Generate
                </Button>
              </>
            ) : (
              <Button onClick={handleSave}>
                {editingProfile ? "Update" : "Create"}
              </Button>
            )}
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Delete Confirmation */}
      <AlertDialog
        open={!!deleteTarget}
        onOpenChange={(open) => !open && setDeleteTarget(null)}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete profile?</AlertDialogTitle>
            <AlertDialogDescription>
              This will permanently delete the profile &quot;{deleteTarget?.name}
              &quot;. This action cannot be undone.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={handleDelete}>
              Delete
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
