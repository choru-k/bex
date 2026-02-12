import type { DiffWord } from "@bex/core";
import { cn } from "@/lib/utils";

interface DiffViewProps {
  diff: DiffWord[];
  className?: string;
}

export function DiffView({ diff, className }: DiffViewProps) {
  return (
    <div className={cn("leading-relaxed whitespace-pre-wrap", className)}>
      {diff.map((word, i) => {
        if (word.type === "added") {
          return (
            <span
              key={i}
              className="bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300"
            >
              {word.text}
            </span>
          );
        }
        if (word.type === "removed") {
          return (
            <span
              key={i}
              className="bg-red-100 text-red-800 line-through dark:bg-red-900/30 dark:text-red-300"
            >
              {word.text}
            </span>
          );
        }
        return <span key={i}>{word.text}</span>;
      })}
    </div>
  );
}
