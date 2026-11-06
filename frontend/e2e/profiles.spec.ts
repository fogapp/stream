import type { Page } from "@playwright/test";
import { expect, test } from "./support/harness";

// However a spec here ends, the household goes back to one profile: a
// second one left behind would put every later spec in front of the picker.
test.afterEach(async ({ page, session }) => {
  const headers = { Authorization: `Bearer ${session.token}` };
  const profiles = (await (await page.request.get("/api/v1/profiles", { headers })).json()) as { id: string; name: string }[];
  for (const profile of profiles.slice(1)) await page.request.delete(`/api/v1/profiles/${profile.id}`, { headers });
  // And nothing stays hidden from the one that's left.
  const first = profiles[0];
  if (!first) return;
  const content = (await (await page.request.get(`/api/v1/profiles/${first.id}/content`, { headers })).json()) as { hidden: { kind: string; id: string }[] };
  for (const item of content.hidden) {
    await page.request.put(`/api/v1/profiles/${first.id}/content/hidden`, { headers, data: { kind: item.kind, id: item.id, hidden: false } });
  }
});

/** Settings › Profiles › the profile's page › Delete. */
async function deleteProfile(page: Page, name: string) {
  await page.goto("/settings?tab=profiles");
  await page.getByRole("listitem").filter({ hasText: name }).getByRole("button").click();
  await expect(page.getByRole("heading", { name, level: 2 })).toBeVisible();
  await page.getByRole("button", { name: "Delete" }).click();
  await page.getByRole("button", { name: "Yes" }).click();
  await expect(page.getByRole("listitem").filter({ hasText: name })).toHaveCount(0);
}

// Profiles share the seed with every other spec: this one makes a second
// profile and deletes it again, or every later spec would meet the picker.

test("a PIN'd profile is chosen on the picker with its PIN, and switching changes whose Home it is", async ({ page }) => {
  await page.goto("/settings?tab=profiles");
  await page.getByRole("button", { name: "New profile" }).click();
  await page.getByLabel("Name").fill("Kids");
  await page.getByRole("button", { name: "🦊" }).click();
  await page.getByLabel("PIN").fill("2468");
  await page.getByRole("button", { name: "Create profile" }).click();
  await expect(page.getByText("Kids", { exact: true })).toBeVisible();

  await page.getByRole("button", { name: /Switch profile/ }).click();
  await expect(page.getByRole("heading", { name: "Who’s watching?" })).toBeVisible();
  await page.getByRole("button", { name: /Kids/ }).click();
  await page.keyboard.type("1111");
  await page.getByRole("button", { name: "OK" }).click();
  await expect(page.getByRole("alert")).toHaveText("That PIN isn't right");
  await page.keyboard.type("2468");
  await page.getByRole("button", { name: "OK" }).click();

  await expect(page.getByRole("button", { name: /Kids.*Switch profile/ })).toBeVisible();
  await page.goto("/");
  // Kids has watched nothing: no Continue watching.
  await expect(page.getByRole("heading", { name: "Continue watching" })).toHaveCount(0);

  // Back to the household's profile, and tidy up.
  await page.getByRole("button", { name: /Switch profile/ }).click();
  await page.getByRole("listitem").filter({ hasNot: page.getByText("Kids") }).getByRole("button").first().click();
  await expect(page.getByRole("heading", { name: "Continue watching" })).toBeVisible();
  await deleteProfile(page, "Kids");
});

test("a kid profile sees only what fits its ceiling or is tagged for it, and no settings", async ({ page }) => {
  await page.goto("/settings?tab=profiles");
  await page.getByRole("button", { name: "New profile" }).click();
  await page.getByLabel("Name").fill("Little one");
  await page.getByRole("checkbox", { name: "Kid profile" }).check();
  await page.getByLabel("Rated for up to").selectOption("0");
  await page.getByRole("button", { name: "Create profile" }).click();
  await expect(page.getByRole("listitem").filter({ hasText: "Little one" })).toContainText("Kid");

  const switchTo = async (name: RegExp) => {
    await page.getByRole("button", { name: /Switch profile/ }).click();
    await page.getByRole("button", { name }).click();
    await expect(page.getByRole("button", { name: /Switch profile/ })).toBeVisible();
  };

  // The seed's films have no rating yet: a kid with a ceiling sees none of them.
  await switchTo(/Little one/);
  const nav = page.getByRole("navigation");
  await expect(nav.getByRole("link", { name: "Settings" })).toHaveCount(0);
  await nav.getByRole("link", { name: "Movies" }).click();
  await expect(page.getByText("Nothing here yet")).toBeVisible();
  await page.goto("/settings");
  await expect.poll(() => new URL(page.url()).pathname).toBe("/");

  // Tagged for them, Heat is theirs to watch.
  await switchTo(/E2E Harness/);
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await page.getByRole("link", { name: /Heat/ }).click();
  await page.getByRole("button", { name: "For profiles" }).click();
  await page.getByRole("checkbox", { name: "Little one" }).check();
  await expect(page.getByRole("checkbox", { name: "Little one" })).toBeChecked();

  await switchTo(/Little one/);
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("link", { name: /Heat/ })).toBeVisible();
  await expect(page.getByRole("link", { name: /Alien/ })).toHaveCount(0);

  await switchTo(/E2E Harness/);
  await deleteProfile(page, "Little one");
});

test("a film hidden from a profile leaves its lists, and Settings brings it back", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await page.getByRole("link", { name: /Heat/ }).click();
  await page.getByRole("button", { name: "Hide from me" }).click();
  await page.getByRole("button", { name: "Yes" }).click();
  await expect.poll(() => new URL(page.url()).pathname).toBe("/");

  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await expect(page.getByRole("link", { name: /Alien/ })).toBeVisible();
  await expect(page.getByRole("link", { name: /Heat/ })).toHaveCount(0);

  // The profile's own page in Settings › Profiles lists it, and so does Settings › Viewing.
  await page.goto("/settings?tab=profiles");
  await page.getByRole("listitem").filter({ hasText: "E2E Harness" }).getByRole("button").click();
  await expect(page.getByRole("heading", { name: "Hidden from this profile" })).toBeVisible();
  await expect(page.getByRole("listitem").filter({ hasText: "Heat" })).toBeVisible();

  await page.goto("/settings?tab=viewing");
  const hidden = page.getByRole("listitem").filter({ hasText: "Heat" });
  await hidden.getByRole("button", { name: "Show again" }).click();
  await expect(page.getByText("Nothing hidden")).toBeVisible();

  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await expect(page.getByRole("link", { name: /Heat/ })).toBeVisible();
});
