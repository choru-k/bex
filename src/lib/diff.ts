export type DiffType = "unchanged" | "added" | "removed";

export interface DiffWord {
  text: string;
  type: DiffType;
}

export function computeWordDiff(
  original: string,
  corrected: string,
): DiffWord[] {
  const origWords = original.split(/(\s+)/).filter(Boolean);
  const corrWords = corrected.split(/(\s+)/).filter(Boolean);

  // LCS-based diff
  const m = origWords.length;
  const n = corrWords.length;
  const dp: number[][] = Array.from({ length: m + 1 }, () =>
    Array(n + 1).fill(0),
  );

  for (let i = 1; i <= m; i++) {
    for (let j = 1; j <= n; j++) {
      dp[i][j] =
        origWords[i - 1] === corrWords[j - 1]
          ? dp[i - 1][j - 1] + 1
          : Math.max(dp[i - 1][j], dp[i][j - 1]);
    }
  }

  const stack: DiffWord[] = [];
  let i = m;
  let j = n;

  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && origWords[i - 1] === corrWords[j - 1]) {
      stack.push({ text: origWords[i - 1], type: "unchanged" });
      i--;
      j--;
    } else if (j > 0 && (i === 0 || dp[i][j - 1] >= dp[i - 1][j])) {
      stack.push({ text: corrWords[j - 1], type: "added" });
      j--;
    } else {
      stack.push({ text: origWords[i - 1], type: "removed" });
      i--;
    }
  }

  const result: DiffWord[] = [];
  while (stack.length) result.push(stack.pop()!);
  return result;
}

export function diffToMarkdown(diff: DiffWord[]): string {
  // Group consecutive tokens of the same type to avoid broken markers (e.g. ~~~~)
  const groups: { type: string; text: string }[] = [];
  for (const w of diff) {
    const last = groups[groups.length - 1];
    if (last && last.type === w.type) {
      last.text += w.text;
    } else {
      groups.push({ type: w.type, text: w.text });
    }
  }

  return groups
    .map((g) => {
      if (g.type === "added") return `**${g.text}**`;
      if (g.type === "removed") return `~~${g.text}~~`;
      return g.text;
    })
    .join("");
}
