import { useState, useEffect, useCallback } from "react";
import { useNavigate } from "react-router-dom";
import { toast } from "sonner";
import type { HistoryEntry, DiffWord } from "@bex/core";
import {
  loadHistory,
  deleteHistoryEntry,
  clearHistory,
  computeWordDiff,
} from "@bex/core";
import { storage } from "@/lib/tauri-storage";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
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
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import { ScrollArea } from "@/components/ui/scroll-area";
import { DiffView } from "@/components/DiffView";
import {
  Trash2,
  ChevronDown,
  ChevronRight,
  Clock,
  Search,
  RotateCcw,
} from "lucide-react";

const ALL_PROVIDERS = "__all__";

export default function History() {
  const navigate = useNavigate();

  const [entries, setEntries] = useState<HistoryEntry[]>([]);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [diffs, setDiffs] = useState<Record<string, DiffWord[]>>({});
  const [searchQuery, setSearchQuery] = useState("");
  const [providerFilter, setProviderFilter] = useState<string>(ALL_PROVIDERS);
  const [showOnlyChanges, setShowOnlyChanges] = useState(false);

  const refresh = useCallback(async () => {
    const list = await loadHistory(storage);
    setEntries(list);
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const handleExpand = (entry: HistoryEntry) => {
    if (expandedId === entry.id) {
      setExpandedId(null);
      return;
    }
    setExpandedId(entry.id);
    if (!diffs[entry.id]) {
      const diff = computeWordDiff(entry.original, entry.corrected);
      setDiffs((prev) => ({ ...prev, [entry.id]: diff }));
    }
  };

  const handleDelete = async (id: string) => {
    await deleteHistoryEntry(storage, id);
    if (expandedId === id) setExpandedId(null);
    toast.success("Entry deleted");
    void refresh();
  };

  const handleClearAll = async () => {
    await clearHistory(storage);
    setEntries([]);
    setExpandedId(null);
    setDiffs({});
    toast.success("History cleared");
  };

  const handleUseAsInput = (entry: HistoryEntry) => {
    navigate("/check", { state: { draftText: entry.corrected } });
    toast.success("Loaded entry in Check Grammar");
  };

  const formatDate = (timestamp: string) => {
    return new Date(timestamp).toLocaleString();
  };

  const providers = Array.from(new Set(entries.map((e) => e.provider))).sort();
  const loweredQuery = searchQuery.trim().toLowerCase();

  const filteredEntries = entries.filter((entry) => {
    if (providerFilter !== ALL_PROVIDERS && entry.provider !== providerFilter) {
      return false;
    }

    if (!loweredQuery) return true;

    const haystack = [
      entry.original,
      entry.corrected,
      entry.explanation,
      entry.provider,
      entry.model,
      entry.profileName || "",
    ]
      .join("\n")
      .toLowerCase();

    return haystack.includes(loweredQuery);
  });

  return (
    <div className="flex h-full flex-col gap-4">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-bold">History</h2>
          <p className="text-muted-foreground leading-relaxed">
            {entries.length} grammar check{entries.length !== 1 ? "s" : ""}
          </p>
        </div>
        {entries.length > 0 && (
          <AlertDialog>
            <AlertDialogTrigger asChild>
              <Button variant="destructive" size="sm">
                Clear all
              </Button>
            </AlertDialogTrigger>
            <AlertDialogContent>
              <AlertDialogHeader>
                <AlertDialogTitle>Clear all history?</AlertDialogTitle>
                <AlertDialogDescription>
                  This will permanently delete all {entries.length} history
                  entries. This action cannot be undone.
                </AlertDialogDescription>
              </AlertDialogHeader>
              <AlertDialogFooter>
                <AlertDialogCancel>Cancel</AlertDialogCancel>
                <AlertDialogAction onClick={handleClearAll}>
                  Clear All
                </AlertDialogAction>
              </AlertDialogFooter>
            </AlertDialogContent>
          </AlertDialog>
        )}
      </div>

      {entries.length > 0 && (
        <div className="flex flex-wrap gap-3">
          <div className="min-w-[16rem] flex-1">
            <div className="relative">
              <Search className="pointer-events-none absolute left-2 top-2.5 h-4 w-4 text-muted-foreground" />
              <Input
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                placeholder="Search original/corrected text..."
                className="pl-8"
              />
            </div>
          </div>

          <div className="w-48">
            <Select value={providerFilter} onValueChange={setProviderFilter}>
              <SelectTrigger>
                <SelectValue placeholder="Filter provider" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL_PROVIDERS}>All providers</SelectItem>
                {providers.map((provider) => (
                  <SelectItem key={provider} value={provider}>
                    {provider}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        </div>
      )}

      {entries.length === 0 ? (
        <div className="flex flex-1 items-center justify-center rounded-md border border-dashed">
          <p className="text-sm leading-relaxed text-muted-foreground">
            No history entries yet. Check some grammar to get started.
          </p>
        </div>
      ) : filteredEntries.length === 0 ? (
        <div className="flex flex-1 items-center justify-center rounded-md border border-dashed">
          <p className="text-sm leading-relaxed text-muted-foreground">
            No entries match your filters.
          </p>
        </div>
      ) : (
        <ScrollArea className="flex-1">
          <div className="space-y-2 pr-4">
            {filteredEntries.map((entry) => (
              <Card key={entry.id}>
                <CardHeader
                  className="cursor-pointer py-3"
                  onClick={() => handleExpand(entry)}
                >
                  <div className="flex items-center justify-between">
                    <div className="min-w-0 flex-1 flex items-center gap-2">
                      {expandedId === entry.id ? (
                        <ChevronDown className="h-4 w-4 shrink-0" />
                      ) : (
                        <ChevronRight className="h-4 w-4 shrink-0" />
                      )}
                      <CardTitle className="truncate text-sm">
                        {entry.original.slice(0, 80)}
                        {entry.original.length > 80 ? "..." : ""}
                      </CardTitle>
                    </div>
                    <div className="ml-2 flex shrink-0 items-center gap-3">
                      <span className="flex items-center gap-1 text-xs text-muted-foreground">
                        <Clock className="h-3 w-3" />
                        {formatDate(entry.timestamp)}
                      </span>
                      <span className="text-xs text-muted-foreground">
                        {entry.provider}/{entry.model}
                      </span>
                      <Button
                        variant="ghost"
                        size="icon"
                        className="h-6 w-6"
                        onClick={(e) => {
                          e.stopPropagation();
                          void handleDelete(entry.id);
                        }}
                      >
                        <Trash2 className="h-3 w-3" />
                      </Button>
                    </div>
                  </div>
                </CardHeader>

                {expandedId === entry.id && (
                  <CardContent className="space-y-4 pt-0">
                    <div className="flex flex-wrap gap-2">
                      <Button
                        size="sm"
                        className="h-7 gap-1 px-2 text-xs"
                        onClick={() => handleUseAsInput(entry)}
                      >
                        Use as new input
                      </Button>
                      <Button
                        variant="outline"
                        size="sm"
                        className="h-7 gap-1 px-2 text-xs"
                        onClick={() => setShowOnlyChanges((v) => !v)}
                      >
                        <RotateCcw className="h-3 w-3" />
                        {showOnlyChanges ? "Show full text" : "Show only changes"}
                      </Button>
                    </div>

                    <div>
                      <p className="mb-1 text-xs font-medium text-muted-foreground">
                        Original
                      </p>
                      <p className="whitespace-pre-wrap text-sm leading-relaxed">{entry.original}</p>
                    </div>

                    <div>
                      <p className="mb-1 text-xs font-medium text-muted-foreground">
                        Diff
                      </p>
                      {diffs[entry.id] && (
                        <DiffView
                          diff={diffs[entry.id]}
                          className="text-sm"
                          showOnlyChanges={showOnlyChanges}
                        />
                      )}
                    </div>

                    <div>
                      <p className="mb-1 text-xs font-medium text-muted-foreground">
                        Corrected
                      </p>
                      <p className="whitespace-pre-wrap text-sm leading-relaxed">{entry.corrected}</p>
                    </div>

                    <div>
                      <p className="mb-1 text-xs font-medium text-muted-foreground">
                        Explanation
                      </p>
                      <p className="text-sm leading-relaxed text-muted-foreground">
                        {entry.explanation}
                      </p>
                    </div>

                    {entry.profileName && (
                      <p className="text-xs leading-relaxed text-muted-foreground">
                        Profile: {entry.profileName}
                      </p>
                    )}
                  </CardContent>
                )}
              </Card>
            ))}
          </div>
        </ScrollArea>
      )}
    </div>
  );
}
