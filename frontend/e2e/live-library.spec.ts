import type { APIRequestContext } from "@playwright/test";
import { expect, test } from "./support/harness";
import { LiveSource } from "./support/liveSource";

// PROPOSAL §7.8: a live library's page is where an admin manages its
// streams — added by address once the address is read, edited, checked
// and removed in place.

const source = new LiveSource();
let api: APIRequestContext;
let libraryId = "";

test.beforeAll(async ({ playwright, session }, testInfo) => {
  await source.open();
  api = await playwright.request.newContext({
    baseURL: testInfo.project.use.baseURL,
    extraHTTPHeaders: { Authorization: `Bearer ${session.token}` },
  });
  const library = await api.post("/api/v1/libraries", { data: { library: { name: "Managed streams", kind: "live" } } });
  expect(library.ok(), await library.text()).toBe(true);
  libraryId = ((await library.json()) as { id: string }).id;
});

test.afterAll(async () => {
  if (libraryId) await api.delete(`/api/v1/libraries/${libraryId}`);
  await api.dispose();
  await source.close();
});

test("an admin adds, edits and removes a stream on its library's page", async ({ page }) => {
  test.setTimeout(90_000);
  await page.goto(`/library/${libraryId}`);
  await expect(page.getByText("No streams yet")).toBeVisible();

  await page.getByRole("button", { name: "Add stream" }).first().click();
  await page.getByLabel("Name", { exact: true }).fill("Test pattern");
  await page.getByLabel("Kind").selectOption("web");
  await page.getByLabel("Address", { exact: true }).fill(source.url);
  await page.getByRole("button", { name: "Test address" }).click();
  await expect(page.getByText(/video/i).first()).toBeVisible({ timeout: 30_000 });
  await page.getByRole("button", { name: "Add stream", exact: true }).last().click();
  // Saving probes the address again; the form closes once it's kept.
  await expect(page.getByText("Add a live stream")).toBeHidden({ timeout: 30_000 });

  const tile = page.getByRole("listitem").filter({ hasText: "Test pattern" });
  await expect(tile).toBeVisible({ timeout: 30_000 });
  await expect(tile.getByRole("link", { name: /Test pattern/ })).toHaveAttribute("href", /\/stream\//);
  await expect(tile.getByRole("button", { name: "Check now" })).toBeVisible();

  await tile.getByRole("button", { name: "Edit Test pattern" }).click();
  await page.getByLabel("Name", { exact: true }).fill("Pattern, renamed");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  const renamed = page.getByRole("listitem").filter({ hasText: "Pattern, renamed" });
  await expect(renamed).toBeVisible();

  await renamed.getByRole("button", { name: "Remove" }).click();
  await renamed.getByRole("button", { name: "Yes" }).click();
  await expect(page.getByText("No streams yet")).toBeVisible();
});
