"""
Layer 4B — Site Adapter: YC Apply
Hand-written Playwright flow for apply.ycombinator.com.
Rock-solid for the demo. Update selectors Saturday afternoon by
actually loading the page and inspecting the form fields.
"""

from playwright.async_api import Page


class YCApplyAdapter:
    BASE_URL = "https://apply.ycombinator.com"

    def __init__(self, page: Page):
        self.page = page

    async def fill(self, resume_path: str, slots: dict):
        """
        Fill the YC application form using resume + extracted slot values.
        Stops before final submission — the orchestrator calls submit() separately
        after the user confirms.
        """
        # Wait for the form to be ready
        await self.page.wait_for_load_state("networkidle")

        # --- Company / Project name ---
        company = slots.get("company", "")
        if company:
            await self._fill_first_visible(
                company,
                [
                    'input[name*="company" i]',
                    'input[id*="company" i]',
                    'input[placeholder*="company" i]',
                    'input[name*="project" i]',
                    'input[placeholder*="project" i]',
                ],
                "company/project",
            )

        # --- Upload resume ---
        # Locate a file input and set the file path
        file_inputs = self.page.locator('input[type="file"]')
        count = await file_inputs.count()
        if count > 0:
            await file_inputs.first.set_input_files(resume_path)

        # --- Founder name ---
        name = slots.get("founder_name", "")
        if name:
            await self._fill_first_visible(
                name,
                [
                    'input[name*="founder" i]',
                    'input[name*="name" i]',
                    'input[id*="name" i]',
                    'input[placeholder*="name" i]',
                ],
                "founder name",
            )

        # --- Email ---
        email = slots.get("email", "")
        if email:
            await self._fill_first_visible(
                email,
                [
                    'input[type="email"]',
                    'input[name*="email" i]',
                    'input[id*="email" i]',
                    'input[placeholder*="email" i]',
                ],
                "email",
            )

        # --- Idea / problem / description ---
        idea = slots.get("idea") or slots.get("description") or slots.get("product_description", "")
        if idea:
            await self._fill_first_visible(
                idea,
                [
                    'textarea[name*="idea" i]',
                    'textarea[name*="description" i]',
                    'textarea[id*="idea" i]',
                    'textarea[id*="description" i]',
                    'textarea[placeholder*="idea" i]',
                    'textarea[placeholder*="describe" i]',
                ],
                "idea description",
            )

        # --- Stage / progress ---
        stage = slots.get("stage", "")
        if stage:
            await self._fill_first_visible(
                stage,
                [
                    'input[name*="stage" i]',
                    'input[id*="stage" i]',
                    'textarea[name*="stage" i]',
                    'textarea[id*="stage" i]',
                    'textarea[placeholder*="stage" i]',
                ],
                "stage",
            )

        # --- Revenue ---
        revenue = slots.get("revenue", "")
        if revenue:
            await self._fill_first_visible(
                str(revenue),
                [
                    'input[name*="revenue" i]',
                    'input[id*="revenue" i]',
                    'input[placeholder*="revenue" i]',
                    'textarea[name*="revenue" i]',
                ],
                "revenue",
            )

        # --- Team size ---
        team_size = slots.get("team_size", "")
        if team_size:
            await self._fill_first_visible(
                str(team_size),
                [
                    'input[name*="team" i]',
                    'input[id*="team" i]',
                    'input[placeholder*="team" i]',
                    'input[name*="founder_count" i]',
                ],
                "team size",
            )

    async def submit(self):
        """
        Click the final submit button. Only called after user confirmation.
        """
        submit_btn = self.page.locator(
            'button[type="submit"], input[type="submit"], button:has-text("Submit")'
        ).last
        await submit_btn.wait_for(state="visible", timeout=5000)
        await submit_btn.click()
        # Wait for confirmation page
        await self.page.wait_for_load_state("networkidle")
        print("[yc_apply] Submission complete.")

    async def _fill_first_visible(self, value: str, selectors: list[str], field_name: str) -> bool:
        for selector in selectors:
            locator = self.page.locator(selector).first
            try:
                if await locator.count() > 0 and await locator.is_visible():
                    await locator.fill(value)
                    print(f"[yc_apply] Filled {field_name} via selector: {selector}")
                    return True
            except Exception:
                continue
        print(f"[yc_apply] Skipped {field_name}: no matching visible selector")
        return False
