import {
  List,
  ActionPanel,
  Action,
  Form,
  Icon,
  showToast,
  Toast,
  confirmAlert,
  Alert,
  useNavigation,
  getPreferenceValues,
} from "@raycast/api";
import { randomUUID } from "crypto";
import { useState, useEffect } from "react";
import {
  Profile,
  Preferences,
  loadProfiles,
  saveProfiles,
  generateText,
  PROFILE_GENERATION_PROMPT,
} from "@bex/core";
import { storage } from "./lib/raycast-storage";

function truncate(text: string, maxLen: number): string {
  return text.length > maxLen ? text.slice(0, maxLen) + "..." : text;
}

function ProfileForm({
  profile,
  onSave,
}: {
  profile?: Profile;
  onSave: (profile: Profile) => void;
}) {
  const { pop } = useNavigation();

  async function handleSubmit(values: {
    name: string;
    prompt: string;
    isDefault: boolean;
  }) {
    const name = values.name.trim();
    if (!name) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Profile name is required.",
      });
      return;
    }
    const prompt = values.prompt.trim();
    if (!prompt) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Profile prompt is required.",
      });
      return;
    }

    onSave({
      id: profile?.id || randomUUID(),
      name,
      prompt,
      isDefault: values.isDefault,
    });
    pop();
  }

  return (
    <Form
      navigationTitle={profile ? "Edit Profile" : "Create Profile"}
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title={profile ? "Save Profile" : "Create Profile"}
            onSubmit={handleSubmit}
            icon={Icon.Check}
          />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="name"
        title="Name"
        placeholder="e.g. Work, Academic, Casual"
        defaultValue={profile?.name || ""}
      />
      <Form.TextArea
        id="prompt"
        title="Prompt"
        placeholder="I'm a software engineer writing to colleagues. Keep the tone professional but not overly formal."
        defaultValue={profile?.prompt || ""}
      />
      <Form.Checkbox
        id="isDefault"
        label="Set as Default"
        defaultValue={profile?.isDefault || false}
      />
    </Form>
  );
}

function AIProfileWizard({ onSave }: { onSave: (profile: Profile) => void }) {
  const { push } = useNavigation();

  async function handleSubmit(values: {
    name: string;
    role: string;
    audience: string;
    tone: string;
    formality: string;
    domain: string;
    notes: string;
  }) {
    const name = values.name.trim();
    if (!name) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Profile name is required.",
      });
      return;
    }

    const parts = [
      `Role: ${values.role || "not specified"}`,
      `Audience: ${values.audience || "not specified"}`,
      `Tone: ${values.tone}`,
      `Formality: ${values.formality}`,
      `Domain: ${values.domain}`,
    ];
    if (values.notes?.trim()) {
      parts.push(`Additional notes: ${values.notes.trim()}`);
    }
    const userMessage = parts.join("\n");

    const prefs = getPreferenceValues<Preferences>();
    const lastModel = await storage.getItem<string>(`lastModel:${prefs.provider}`);
    if (lastModel) {
      prefs.model = lastModel;
    }
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 30000);

    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Generating profile prompt...",
    });

    try {
      const generatedPrompt = await generateText(
        PROFILE_GENERATION_PROMPT,
        userMessage,
        prefs,
        controller.signal,
      );
      clearTimeout(timeout);
      toast.hide();

      const id = randomUUID();
      push(
        <ProfileForm
          profile={{ id, name, prompt: generatedPrompt, isDefault: false }}
          onSave={onSave}
        />,
      );
    } catch (err) {
      clearTimeout(timeout);
      toast.style = Toast.Style.Failure;
      toast.title = "Failed to generate prompt";
      toast.message = err instanceof Error ? err.message : String(err);
    }
  }

  return (
    <Form
      navigationTitle="Create with AI"
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Generate Prompt"
            onSubmit={handleSubmit}
            icon={Icon.Stars}
          />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="name"
        title="Profile Name"
        placeholder="e.g. Work, Academic, Casual"
      />
      <Form.Separator />
      <Form.Description text="Describe your writing context and the AI will generate a tailored prompt for you." />
      <Form.TextField
        id="role"
        title="Your Role"
        placeholder="e.g. software engineer, student, manager"
      />
      <Form.TextField
        id="audience"
        title="Your Audience"
        placeholder="e.g. colleagues, clients, professors"
      />
      <Form.Dropdown id="tone" title="Tone" defaultValue="professional">
        <Form.Dropdown.Item value="casual" title="Casual" />
        <Form.Dropdown.Item value="friendly" title="Friendly" />
        <Form.Dropdown.Item value="professional" title="Professional" />
        <Form.Dropdown.Item value="academic" title="Academic" />
        <Form.Dropdown.Item value="authoritative" title="Authoritative" />
      </Form.Dropdown>
      <Form.Dropdown id="formality" title="Formality" defaultValue="neutral">
        <Form.Dropdown.Item value="informal" title="Informal" />
        <Form.Dropdown.Item value="neutral" title="Neutral" />
        <Form.Dropdown.Item value="formal" title="Formal" />
        <Form.Dropdown.Item value="very formal" title="Very Formal" />
      </Form.Dropdown>
      <Form.Dropdown id="domain" title="Domain" defaultValue="general">
        <Form.Dropdown.Item value="general" title="General" />
        <Form.Dropdown.Item value="technology" title="Technology" />
        <Form.Dropdown.Item value="business" title="Business" />
        <Form.Dropdown.Item value="academic" title="Academic" />
        <Form.Dropdown.Item value="medical" title="Medical" />
        <Form.Dropdown.Item value="legal" title="Legal" />
        <Form.Dropdown.Item value="creative" title="Creative" />
      </Form.Dropdown>
      <Form.TextArea
        id="notes"
        title="Additional Notes"
        placeholder="Any other details about your writing style or needs (optional)"
      />
    </Form>
  );
}

export default function ManageProfiles() {
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    (async () => {
      const loaded = await loadProfiles(storage);
      setProfiles(loaded);
      setIsLoading(false);
    })();
  }, []);

  async function persistProfiles(updated: Profile[]) {
    setProfiles(updated);
    await saveProfiles(storage, updated);
  }

  async function handleSave(saved: Profile) {
    let updated: Profile[];
    const existing = profiles.find((p) => p.id === saved.id);
    if (existing) {
      updated = profiles.map((p) => (p.id === saved.id ? saved : p));
    } else {
      updated = [...profiles, saved];
    }

    if (saved.isDefault) {
      updated = updated.map((p) =>
        p.id === saved.id ? p : { ...p, isDefault: false },
      );
    }

    await persistProfiles(updated);
    await showToast({
      style: Toast.Style.Success,
      title: `Profile "${saved.name}" saved.`,
    });
  }

  async function handleSetDefault(profile: Profile) {
    const updated = profiles.map((p) => ({
      ...p,
      isDefault: p.id === profile.id,
    }));
    await persistProfiles(updated);
    await showToast({
      style: Toast.Style.Success,
      title: `"${profile.name}" set as default.`,
    });
  }

  async function handleDelete(profile: Profile) {
    if (
      await confirmAlert({
        title: `Delete "${profile.name}"?`,
        message: "This cannot be undone.",
        primaryAction: {
          title: "Delete",
          style: Alert.ActionStyle.Destructive,
        },
      })
    ) {
      const updated = profiles.filter((p) => p.id !== profile.id);
      await persistProfiles(updated);
      await showToast({
        style: Toast.Style.Success,
        title: `Profile "${profile.name}" deleted.`,
      });
    }
  }

  if (!isLoading && profiles.length === 0) {
    return (
      <List>
        <List.EmptyView
          title="No Profiles Yet"
          description="Create a profile to customize how Bex corrects your text. Press Enter to create one with AI assistance."
          actions={
            <ActionPanel>
              <Action.Push
                title="Create with AI"
                icon={Icon.Stars}
                target={<AIProfileWizard onSave={handleSave} />}
              />
              <Action.Push
                title="Create Manually"
                icon={Icon.Plus}
                target={<ProfileForm onSave={handleSave} />}
              />
            </ActionPanel>
          }
        />
      </List>
    );
  }

  return (
    <List isLoading={isLoading}>
      {profiles.map((profile) => (
        <List.Item
          key={profile.id}
          title={profile.name}
          subtitle={truncate(profile.prompt, 50)}
          accessories={profile.isDefault ? [{ tag: "Default" }] : []}
          actions={
            <ActionPanel>
              <Action.Push
                title="Edit Profile"
                icon={Icon.Pencil}
                target={<ProfileForm profile={profile} onSave={handleSave} />}
              />
              <Action
                title="Set as Default"
                icon={Icon.Star}
                onAction={() => handleSetDefault(profile)}
              />
              <Action.Push
                title="Create with AI"
                icon={Icon.Stars}
                shortcut={{ modifiers: ["cmd", "shift"], key: "n" }}
                target={<AIProfileWizard onSave={handleSave} />}
              />
              <Action.Push
                title="Create Manually"
                icon={Icon.Plus}
                shortcut={{ modifiers: ["cmd"], key: "n" }}
                target={<ProfileForm onSave={handleSave} />}
              />
              <Action
                title="Delete Profile"
                style={Action.Style.Destructive}
                icon={Icon.Trash}
                shortcut={{ modifiers: ["ctrl"], key: "x" }}
                onAction={() => handleDelete(profile)}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
