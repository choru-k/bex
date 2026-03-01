import type { DiffWord } from "@bex/core";
import { cn } from "@/lib/utils";

interface DiffViewProps {
  diff: DiffWord[];
  className?: string;
  showOnlyChanges?: boolean;
}

export function DiffView({ diff, className, showOnlyChanges = false }: DiffViewProps) {
  const visibleDiff = showOnlyChanges
    ? diff.filter((word) => word.type !== "unchanged")
    : diff;

  return (
    <div className={cn("leading-relaxed whitespace-pre-wrap", className)}>
      {visibleDiff.map((word, i) => {
        if (word.type === "added") {
          return (
            <span
              key={i}
              aria-label="Added text"
              className="bg-green-200 text-green-900 underline decoration-green-700 decoration-2 dark:bg-green-800/50 dark:text-green-100 dark:decoration-green-300"
            >
              {word.text}
            </span>
          );
        }
        if (word.type === "removed") {
          return (
            <span
              key={i}
              aria-label="Removed text"
              className="bg-red-200 text-red-900 line-through decoration-2 dark:bg-red-800/50 dark:text-red-100"
            >
              {word.text}
            </span>
          );
        }
        return <span key={i}>{word.text}</span>;
      })}
      {showOnlyChanges && visibleDiff.length === 0 && (
        <span className="text-muted-foreground">No differences</span>
      )}
    </div>
  );
}
