import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { LoadMore } from "./LoadMore";

/** Observers made, newest last, each able to say "in view". */
let observers: { callback: IntersectionObserverCallback; disconnected: boolean }[] = [];

beforeEach(() => {
  observers = [];
  vi.stubGlobal(
    "IntersectionObserver",
    class {
      entry: { callback: IntersectionObserverCallback; disconnected: boolean };
      constructor(callback: IntersectionObserverCallback) {
        this.entry = { callback, disconnected: false };
        observers.push(this.entry);
      }
      observe() {}
      disconnect() {
        this.entry.disconnected = true;
      }
    },
  );
});
afterEach(() => vi.unstubAllGlobals());

const inView = () =>
  act(() => {
    const live = observers.filter((observer) => !observer.disconnected).at(-1);
    live?.callback([{ isIntersecting: true } as IntersectionObserverEntry], {} as IntersectionObserver);
  });

describe("LoadMore", () => {
  it("loads the next page when the end of the list comes into view", () => {
    const onLoad = vi.fn();
    render(<LoadMore hasMore loading={false} onLoad={onLoad} />);
    inView();
    expect(onLoad).toHaveBeenCalledTimes(1);
  });

  it("watches again after each page, and says it's loading meanwhile", () => {
    const onLoad = vi.fn();
    const { rerender } = render(<LoadMore hasMore loading={false} onLoad={onLoad} />);
    rerender(<LoadMore hasMore loading onLoad={onLoad} />);
    expect(screen.getByRole("status")).toHaveTextContent("Loading more…");
    expect(observers.every((observer) => observer.disconnected)).toBe(true);
    rerender(<LoadMore hasMore loading={false} onLoad={onLoad} />);
    inView();
    expect(onLoad).toHaveBeenCalledTimes(1);
  });

  it("doesn't retry a failed page by itself, but offers to", () => {
    const onLoad = vi.fn();
    render(<LoadMore hasMore loading={false} failed onLoad={onLoad} />);
    inView();
    expect(onLoad).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Couldn't load more. Try again" }));
    expect(onLoad).toHaveBeenCalledTimes(1);
  });

  it("is nothing once there's no more", () => {
    const { container } = render(<LoadMore hasMore={false} loading={false} onLoad={vi.fn()} />);
    expect(container).toBeEmptyDOMElement();
  });
});
