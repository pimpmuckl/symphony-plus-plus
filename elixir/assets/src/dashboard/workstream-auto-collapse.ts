import { useEffect, useRef } from "react";

export function useAutoCollapseWhenDone(
  done: boolean,
  expanded: boolean,
  onCollapse: () => void,
  doneAlreadyHandled = false,
) {
  const autoCollapsedDoneRef = useRef(doneAlreadyHandled);

  useEffect(() => {
    if (!done) {
      autoCollapsedDoneRef.current = false;
      return;
    }

    if (!expanded) {
      autoCollapsedDoneRef.current = true;
      return;
    }

    if (!autoCollapsedDoneRef.current) {
      autoCollapsedDoneRef.current = true;
      onCollapse();
    }
  }, [done, expanded, onCollapse]);
}
