import { useState, useEffect, useCallback } from "react";
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
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
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
import { Trash2, ChevronDown, ChevronRight, Clock } from "lucide-react";

export default function History() {
  const [entries, setEntries] = useState<HistoryEntry[]>([]);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [diffs, setDiffs] = useState<Record<string, DiffWord[]>>({});

  const refresh = useCallback(async () => {
    const list = await loadHistory(storage);
    setEntries(list);
  }, []);

  useEffect(() => {
    refresh();
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
    refresh();
  };

  const handleClearAll = async () => {
    await clearHistory(storage);
    setEntries([]);
    setExpandedId(null);
    setDiffs({});
    toast.success("History cleared");
  };

  const formatDate = (timestamp: string) => {
    return new Date(timestamp).toLocaleString();
  };

  return (
    <div className="flex h-full flex-col gap-4">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-bold">History</h2>
          <p className="text-muted-foreground">
            {entries.length} grammar check{entries.length !== 1 ? "s" : ""}
          </p>
        </div>
        {entries.length > 0 && (
          <AlertDialog>
            <AlertDialogTrigger asChild>
              <Button variant="destructive" size="sm">
                Clear All
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

      {entries.length === 0 ? (
        <div className="flex flex-1 items-center justify-center rounded-md border border-dashed">
          <p className="text-sm text-muted-foreground">
            No history entries yet. Check some grammar to get started.
          </p>
        </div>
      ) : (
        <ScrollArea className="flex-1">
          <div className="space-y-2 pr-4">
            {entries.map((entry) => (
              <Card key={entry.id}>
                <CardHeader
                  className="cursor-pointer py-3"
                  onClick={() => handleExpand(entry)}
                >
                  <div className="flex items-center justify-between">
                    <div className="flex items-center gap-2 min-w-0 flex-1">
                      {expandedId === entry.id ? (
                        <ChevronDown className="h-4 w-4 shrink-0" />
                      ) : (
                        <ChevronRight className="h-4 w-4 shrink-0" />
                      )}
                      <CardTitle className="text-sm truncate">
                        {entry.original.slice(0, 80)}
                        {entry.original.length > 80 ? "..." : ""}
                      </CardTitle>
                    </div>
                    <div className="flex items-center gap-3 shrink-0 ml-2">
                      <span className="text-xs text-muted-foreground flex items-center gap-1">
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
                          handleDelete(entry.id);
                        }}
                      >
                        <Trash2 className="h-3 w-3" />
                      </Button>
                    </div>
                  </div>
                </CardHeader>

                {expandedId === entry.id && (
                  <CardContent className="space-y-4 pt-0">
                    <div>
                      <p className="text-xs font-medium text-muted-foreground mb-1">
                        Original
                      </p>
                      <p className="text-sm whitespace-pre-wrap">
                        {entry.original}
                      </p>
                    </div>

                    <div>
                      <p className="text-xs font-medium text-muted-foreground mb-1">
                        Diff
                      </p>
                      {diffs[entry.id] && (
                        <DiffView diff={diffs[entry.id]} className="text-sm" />
                      )}
                    </div>

                    <div>
                      <p className="text-xs font-medium text-muted-foreground mb-1">
                        Corrected
                      </p>
                      <p className="text-sm whitespace-pre-wrap">
                        {entry.corrected}
                      </p>
                    </div>

                    <div>
                      <p className="text-xs font-medium text-muted-foreground mb-1">
                        Explanation
                      </p>
                      <p className="text-sm text-muted-foreground">
                        {entry.explanation}
                      </p>
                    </div>

                    {entry.profileName && (
                      <p className="text-xs text-muted-foreground">
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
