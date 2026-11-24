export async function confirmPhase(page) {
  await page.locator('#phase-count-dialog button[value=continue]').click();
  await page.locator('#phase-final-dialog button[value=continue]').click();
}
