import { useLayoutEffect, useRef, type RefObject } from "react";

/**
 * A ref that always holds the latest `value`, written after each commit
 * rather than during render. For a callback prop read from a stable
 * callback — a media event, a timer, a user's seek — where an Effect Event
 * can't go (those may only be called from Effects): the callback keeps its
 * identity, and still calls what the parent passed last.
 */
export function useLatest<T>(value: T): RefObject<T> {
  const ref = useRef(value);
  useLayoutEffect(() => {
    ref.current = value;
  });
  return ref;
}
