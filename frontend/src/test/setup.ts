import "@testing-library/jest-dom/vitest";

// Node 25 and up have a localStorage of their own, which does nothing without
// --localstorage-file and hides jsdom's. Code under test gets a working one.
if (typeof window !== "undefined" && typeof globalThis.localStorage?.setItem !== "function") {
  const items = new Map<string, string>();
  const storage: Storage = {
    get length() {
      return items.size;
    },
    clear: () => items.clear(),
    getItem: (key) => items.get(key) ?? null,
    key: (index) => [...items.keys()][index] ?? null,
    removeItem: (key) => void items.delete(key),
    setItem: (key, value) => void items.set(key, String(value)),
  };
  Object.defineProperty(globalThis, "localStorage", { value: storage, configurable: true });
  Object.defineProperty(window, "localStorage", { value: storage, configurable: true });
}
