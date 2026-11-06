import { execFileSync } from "node:child_process";
import { expect, test } from "./support/harness";

// The Playback page (frontend/src/pages/PlaybackDecisions.tsx) over the
// seed's failed play and optimized versions in every state (e2e:seed ›
// seed_playback_page). Optimizing stays paused for the run, so nothing
// these specs queue is ever encoded under the playback suite's feet.

test("a health card opens the plays it counted, and a play says why it failed", async ({ page }) => {
  await page.goto("/playback");
  await page.getByRole("link", { name: /Plays that ended on an error/ }).click();
  await expect(page).toHaveURL(/tab=sessions/);
  await expect(page).toHaveURL(/outcomes=failed/);
  await expect(page.getByRole("button", { name: "Conversion failed", exact: true })).toHaveAttribute("aria-pressed", "true");

  const row = page.getByRole("row", { name: /Case MPEG2 TS/ });
  await expect(row).toContainText("Conversion failed");
  await row.getByRole("button", { name: "Details" }).click();
  await expect(page.getByText("MEDIA_ERR_SRC_NOT_SUPPORTED")).toBeVisible();
  await expect(page.getByText("ffmpeg exited 1: Conversion failed!")).toBeVisible();

  await page.getByRole("button", { name: /Clear filters/ }).click();
  await expect(page).not.toHaveURL(/outcomes=/);
});

test("a table sorts on the server, and the sort lives in the URL", async ({ page }) => {
  await page.goto("/playback?tab=sessions");
  await page.getByRole("columnheader", { name: /Start-up/ }).getByRole("button").click();
  await expect(page).toHaveURL(/sort=startup_ms&dir=asc/);
  await page.getByRole("columnheader", { name: /Start-up/ }).getByRole("button").click();
  await expect(page).toHaveURL(/dir=desc/);
});

test("Do next puts a file at the front of the queue", async ({ page }) => {
  await page.goto("/playback?tab=queue");
  // Paused for the run (the seed): the panel offers to resume.
  await expect(page.getByRole("region", { name: "Optimizer" }).getByRole("button", { name: "Resume optimizing" })).toBeVisible();
  await expect(page.getByRole("row", { name: /Case DTS/ })).toContainText("3");

  await page.getByRole("checkbox", { name: "Select Case DTS 2000" }).check();
  await page.getByRole("region", { name: "Selected rows" }).getByRole("button", { name: "Do next" }).click();
  await expect(page.getByText("Moved to the front 1")).toBeVisible();
  // First in line now, ahead of the one asked for and the one airing.
  await expect(page.getByRole("row").nth(2)).toContainText("Case DTS");
  await expect(page.getByRole("row", { name: /Case DTS/ })).toContainText("next");
});

test("optimizing many at once says what it did, and Don't optimize takes a file off the list", async ({ page }) => {
  await page.goto("/playback?tab=converting&statuses=none");
  await page.getByRole("checkbox", { name: "Select Moving Picture 2001" }).check();
  await page.getByRole("checkbox", { name: "Select Slow Clock 2012" }).check();
  const bar = page.getByRole("region", { name: "Selected rows" });
  await expect(bar).toContainText("2 files selected");
  await bar.getByRole("button", { name: "Optimize tonight" }).click();
  await expect(page.getByText("Queued 2")).toBeVisible();
  // No longer "not optimized": the filter lets them go.
  await expect(page.getByRole("row", { name: /Moving Picture/ })).toHaveCount(0);

  await page.getByRole("checkbox", { name: "Select Case HEVC HDR10 2000" }).check();
  await bar.getByRole("button", { name: "Don't optimize" }).click();
  await bar.getByRole("button", { name: "Yes" }).click();
  await expect(page.getByText("Won't optimize 1")).toBeVisible();
  await expect(page.getByRole("row", { name: /Case HEVC HDR10/ })).toHaveCount(0);

  await page.getByRole("button", { name: "Not optimizing", exact: true }).click();
  await page.getByRole("button", { name: "Not optimized", exact: true }).click();
  await expect(page.getByRole("row", { name: /Case HEVC HDR10/ })).toContainText("Not optimizing");
});

test("the optimizer looks for files when asked", async ({ page }) => {
  await page.goto("/playback?tab=queue");
  await page.getByRole("button", { name: "Find files to optimize now" }).click();
  await expect(page.getByText("Looking for files to optimize…")).toBeVisible();
});

// What plays taught, and forgetting it.
test("the Learned tab shows a way that failed for a file, and Forget lets it be tried again", async ({ page }) => {
  const runner = (code: string) =>
    execFileSync("bin/rails", ["runner", code], { cwd: "..", env: { ...process.env, DATABASE_PORT: process.env.DATABASE_PORT ?? "5437" } }).toString();
  runner(`
    file = MediaFile.unscoped.joins(:household).where(households: { name: "E2E Harness" }).find_by!("path LIKE ?", "%Case H264 AAC MP4%")
    Playability.unscoped.where(client_class: "E2E Browser 1").delete_all
    Playability.create!(household_id: file.household_id, media_file: file, format_signature: "e2e", client_class: "E2E Browser 1",
      rung: "direct", failures: 2, last_failed_at: 1.hour.ago, last_failure_class: "decode", last_failure_cause: "MediaError 3")
  `);
  await page.goto("/playback?tab=learned");
  const row = page.getByRole("row", { name: /E2E Browser 1/ });
  await expect(row).toContainText("Playing as-is");
  await expect(row).toContainText("Couldn't decode it · 2 times");
  await expect(row).toContainText("Skipped until");
  await row.getByRole("button", { name: "Forget" }).click();
  await row.getByRole("button", { name: "Yes" }).click();
  await expect(page.getByRole("row", { name: /E2E Browser 1/ })).toHaveCount(0);
});
