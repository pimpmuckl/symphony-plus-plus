import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { CheckCircle2, Loader2, MessageSquareText } from "lucide-react";
import { MarkdownBlock } from "@/components/dashboard/markdown-block";
import type { ContextComment } from "@/types/dashboard";
import type * as React from "react";
import { Textarea } from "@/components/ui/textarea";
import { cn } from "@/lib/utils";
import { sortedCopy } from "@/lib/collections";
import { useCallback, useMemo, useState } from "react";
import { COMMENT_BODY_MAX_LENGTH, CommentTarget, ResolveContextComment, SubmitContextComment } from "./runtime";
import { detailDate } from "./detail-utils";

export function CommentsPanel({
  target,
  comments,
  onCommentsChange,
  onSubmitComment,
  onResolveComment,
  canMutate,
  textareaRef,
}: {
  target: CommentTarget;
  comments: ContextComment[];
  onCommentsChange: React.Dispatch<React.SetStateAction<ContextComment[]>>;
  onSubmitComment: SubmitContextComment;
  onResolveComment: ResolveContextComment;
  canMutate: boolean;
  textareaRef?: React.Ref<HTMLTextAreaElement>;
}) {
  const [draft, setDraft] = useState("");
  const [pending, setPending] = useState(false);
  const [resolvingId, setResolvingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const orderedComments = useMemo(() => {
    return sortedCopy(comments, (left, right) => {
      const leftTime = Date.parse(left.inserted_at || "");
      const rightTime = Date.parse(right.inserted_at || "");
      if (Number.isFinite(leftTime) && Number.isFinite(rightTime) && leftTime !== rightTime) return leftTime - rightTime;
      return left.id.localeCompare(right.id);
    });
  }, [comments]);
  const openCount = orderedComments.filter((comment) => comment.status !== "resolved").length;

  async function submit() {
    const body = draft.trim();
    if (!body) return;

    setPending(true);
    setError(null);

    try {
      const comment = await onSubmitComment(target, body);
      onCommentsChange((current) => [...current.filter((item) => item.id !== comment.id), comment]);
      setDraft("");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Comment was not recorded");
    } finally {
      setPending(false);
    }
  }

  async function resolve(comment: ContextComment) {
    setResolvingId(comment.id);
    setError(null);

    try {
      const resolved = await onResolveComment(comment.id);
      onCommentsChange((current) => current.map((item) => (item.id === resolved.id ? resolved : item)));
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Comment was not resolved");
    } finally {
      setResolvingId(null);
    }
  }

  return (
    <div className="grid gap-3">
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant={openCount > 0 ? "warning" : "outline"}>{openCount} open</Badge>
        <span className="text-xs text-muted-foreground">{orderedComments.length} total</span>
      </div>
      {orderedComments.length > 0 ? (
        <div className="grid gap-2">
          {orderedComments.map((comment) => (
            <CommentRow key={comment.id} canMutate={canMutate} comment={comment} onResolve={resolve} resolvingId={resolvingId} />
          ))}
        </div>
      ) : (
        <p>No comments yet.</p>
      )}
      {canMutate ? (
        <div className="grid gap-2">
          <Textarea ref={textareaRef} value={draft} onChange={(event) => setDraft(event.target.value)} placeholder="Add a Markdown note..." disabled={pending} maxLength={COMMENT_BODY_MAX_LENGTH} />
          <div className="flex flex-wrap items-center justify-between gap-2">
            {error ? <p className="text-xs text-destructive">{error}</p> : <span />}
            <Button type="button" size="sm" onClick={() => void submit()} disabled={pending || draft.trim() === ""}>
              {pending ? <Loader2 className="size-4 animate-spin" /> : <MessageSquareText className="size-4" />}
              Add Comment
            </Button>
          </div>
        </div>
      ) : null}
    </div>
  );
}

function CommentRow({
  canMutate,
  comment,
  onResolve,
  resolvingId,
}: {
  canMutate: boolean;
  comment: ContextComment;
  onResolve: (comment: ContextComment) => Promise<void>;
  resolvingId: string | null;
}) {
  const resolved = comment.status === "resolved";
  const resolving = resolvingId === comment.id;

  return (
    <div className={cn("detail-list-item", resolved && "opacity-75")}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="text-xs font-medium text-muted-foreground">
          {comment.author_name || comment.source_type || "comment"} / {detailDate(comment.inserted_at)}
        </span>
        <div className="flex items-center gap-2">
          <Badge variant={resolved ? "secondary" : "info"}>{resolved ? "Resolved" : "Open"}</Badge>
          {canMutate && !resolved ? (
            <Button type="button" size="sm" variant="outline" onClick={() => void onResolve(comment)} disabled={resolving}>
              {resolving ? <Loader2 className="size-4 animate-spin" /> : <CheckCircle2 className="size-4" />}
              Resolve
            </Button>
          ) : null}
        </div>
      </div>
      <MarkdownBlock className="mt-2 text-sm" value={comment.body} empty="No comment body recorded." />
      <ResolutionMetadata comment={comment} resolved={resolved} />
    </div>
  );
}

function ResolutionMetadata({ comment, resolved }: { comment: ContextComment; resolved: boolean }) {
  if (!resolved) return null;

  return (
    <>
      {comment.resolution_note ? <MarkdownBlock className="detail-markdown-compact mt-2 text-xs" value={comment.resolution_note} /> : null}
      {comment.resolved_by ? <p className="mt-2 text-xs text-muted-foreground">Resolved by {comment.resolved_by}</p> : null}
    </>
  );
}

export function useSyncedComments(sourceComments: ContextComment[]) {
  const sourceIdentity = useMemo(() => commentsIdentity(sourceComments), [sourceComments]);
  const [state, setState] = useState<{ sourceIdentity: string; comments: ContextComment[] }>(() => ({
    sourceIdentity,
    comments: sourceComments,
  }));
  const comments = state.sourceIdentity === sourceIdentity ? state.comments : sourceComments;
  const setComments = useCallback<React.Dispatch<React.SetStateAction<ContextComment[]>>>(
    (nextComments) => {
      setState((current) => {
        const base = current.sourceIdentity === sourceIdentity ? current.comments : sourceComments;
        const comments =
          typeof nextComments === "function"
            ? (nextComments as (currentComments: ContextComment[]) => ContextComment[])(base)
            : nextComments;

        return { sourceIdentity, comments };
      });
    },
    [sourceIdentity, sourceComments],
  );

  return [comments, setComments] as const;
}

function commentsIdentity(comments: ContextComment[]) {
  return comments
    .map((comment) =>
      [
        comment.id,
        comment.status || "",
        comment.updated_at || "",
        comment.resolved_at || "",
        comment.resolution_note || "",
        comment.body || "",
      ].join(":"),
    )
    .join("|");
}
