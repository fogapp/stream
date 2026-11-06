import { deviceKey } from "@/lib/capabilities";
const TOKEN_KEY = "stream_api_token";

export class ApiError extends Error {
  status: number;
  errors: string[];
  /** Seconds the server asked to wait before trying again (Retry-After), when it did. */
  retryAfter: number | null;

  constructor(status: number, errors: string[], retryAfter: number | null = null) {
    super(errors[0] ?? `HTTP ${status}`);
    this.name = "ApiError";
    this.status = status;
    this.errors = errors;
    this.retryAfter = retryAfter;
  }
}

/**
 * Storage can be missing or throw on access: a private window, blocked site
 * data, or a test runtime whose global `localStorage` is a stub. A token that
 * can't be read is simply absent — the request goes out unauthenticated and
 * the server answers 401, which the console already knows how to handle.
 */
function storage(): Storage | null {
  try {
    return typeof localStorage === "undefined" || localStorage === null ? null : localStorage;
  } catch {
    return null;
  }
}

const PROFILE_KEY = "stream_profile_token";

/** The signed token for the profile this browser chose. */
export const profileTokenStore = {
  get: (): string | null => {
    try {
      return storage()?.getItem(PROFILE_KEY) ?? null;
    } catch {
      return null;
    }
  },
  set: (token: string) => {
    try {
      storage()?.setItem(PROFILE_KEY, token);
    } catch {
      // Without storage the choice lasts until the page reloads.
    }
  },
  clear: () => {
    try {
      storage()?.removeItem(PROFILE_KEY);
    } catch {
      // Nothing to clear.
    }
  },
};

export const tokenStore = {
  get: (): string | null => {
    try {
      return storage()?.getItem(TOKEN_KEY) ?? null;
    } catch {
      return null;
    }
  },
  set: (token: string) => {
    try {
      storage()?.setItem(TOKEN_KEY, token);
    } catch {
      // Nowhere to keep it; this session stays signed in until reload.
    }
  },
  clear: () => {
    try {
      storage()?.removeItem(TOKEN_KEY);
    } catch {
      // Nothing stored means nothing to clear.
    }
  },
};

/**
 * How long to wait before deciding the server is never going to answer.
 * Generous — resolving a source or testing an integration makes the request
 * wait on somebody else's server — but finite, because a fetch with no timeout
 * has no failure state at all: the query stays pending forever, ErrorState
 * never renders, and the console just sits there looking like it's thinking.
 */
const TIMEOUT_MS = 45_000;

/**
 * What the server said about a failed request, for showing beside the form
 * that sent it — or `fallback` when the failure wasn't the server's answer.
 */
export function apiErrorMessage(error: unknown, fallback: string): string {
  return error instanceof ApiError ? error.errors.join(", ") : fallback;
}

/**
 * A request that never produced a readable response, in the console's words.
 * 0 rather than a real status, because there wasn't one: nothing came back.
 * A timeout is told apart from a network failure so the console can say
 * which it was — "still working on it" and "can't reach it" call for
 * different things from the person reading.
 */
function translateFetchError(error: unknown): never {
  if (error instanceof DOMException && error.name === "TimeoutError") {
    throw new ApiError(0, ["The server didn't answer in time"]);
  }
  // A cancellation is TanStack's own doing — rethrow untranslated so it is
  // recognized as one, never surfaced as a network failure.
  if (error instanceof DOMException && error.name === "AbortError") throw error;
  throw new ApiError(0, ["Couldn't reach the server"]);
}

/**
 * `api.get<T>` trusts T — there is no runtime validation by design (hub
 * convention), so src/types must move in lockstep with the serializers.
 */
type RequestOptions = { signal?: AbortSignal };

async function request<T>(
  method: string,
  path: string,
  body?: unknown,
  options?: RequestOptions,
): Promise<T> {
  const token = tokenStore.get();
  const headers: Record<string, string> = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  // Who's watching (PROPOSAL §7.4): the profile this browser chose, and
  // which device it is, for its default profile.
  const profile = profileTokenStore.get();
  if (profile) headers["X-Stream-Profile"] = profile;
  const device = deviceKey();
  if (device) headers["X-Stream-Device"] = device;
  // FormData sets its own multipart boundary — a manual Content-Type here
  // would break the upload.
  const isForm = body instanceof FormData;
  if (body !== undefined && !isForm) headers["Content-Type"] = "application/json";

  // The caller's signal (TanStack passes one per query) composed with the
  // timeout: a superseded request — a slider dragged past its debounce rest
  // point firing another full server-side ranking pass — should be aborted,
  // not left running to completion while holding a connection slot.
  const timeout = AbortSignal.timeout(TIMEOUT_MS);
  const signal = options?.signal ? AbortSignal.any([options.signal, timeout]) : timeout;

  let response: Response;
  try {
    response = await fetch(`/api/v1${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : isForm ? body : JSON.stringify(body),
      signal,
    });
  } catch (error) {
    translateFetchError(error);
  }

  if (response.status === 204) return undefined as T;

  // The body read sits under the same signal as the headers: a server that
  // answers and then stalls streaming raises the same TimeoutError here, and
  // it must get the same translation — otherwise the raw DOMException walks
  // past every `instanceof ApiError` check and the UI shows the generic
  // fallback instead of the message written for this case.
  let text: string;
  try {
    text = await response.text();
  } catch (error) {
    translateFetchError(error);
  }
  // A gateway that gave up on the app answers with its own HTML page, not
  // our JSON envelope — that must surface as the status it is, not as a
  // parse exception before the status is ever looked at.
  let payload: unknown;
  try {
    payload = text ? JSON.parse(text) : undefined;
  } catch {
    throw new ApiError(response.status, [
      response.ok ? "The server returned something that wasn't JSON" : `HTTP ${response.status}`,
    ]);
  }

  if (!response.ok) {
    const retryAfter = Number(response.headers.get("Retry-After"));
    throw new ApiError(response.status, extractErrors(payload, response.status), Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : null);
  }
  return payload as T;
}

function extractErrors(payload: unknown, status: number): string[] {
  if (payload && typeof payload === "object" && "errors" in payload) {
    const errors = (payload as { errors: unknown }).errors;
    if (Array.isArray(errors)) return errors.map(String);
  }
  return [`HTTP ${status}`];
}

export const api = {
  get: <T>(path: string, options?: RequestOptions) => request<T>("GET", path, undefined, options),
  post: <T>(path: string, body?: unknown, options?: RequestOptions) =>
    request<T>("POST", path, body ?? {}, options),
  /** Multipart upload (backup artifacts) — body is FormData, not JSON. */
  postForm: <T>(path: string, form: FormData, options?: RequestOptions) =>
    request<T>("POST", path, form, options),
  put: <T>(path: string, body?: unknown, options?: RequestOptions) =>
    request<T>("PUT", path, body ?? {}, options),
  patch: <T>(path: string, body?: unknown, options?: RequestOptions) =>
    request<T>("PATCH", path, body ?? {}, options),
  delete: <T>(path: string, options?: RequestOptions) =>
    request<T>("DELETE", path, undefined, options),
};
