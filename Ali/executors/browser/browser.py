"""
Layer 4B — Browser Executor
Uses Playwright with a persistent Chrome context pointed at the user's
real Chrome profile — all their cookies, sessions, and logins, pre-loaded.
headless=False so the demo shows the browser working live.
"""

from datetime import datetime
from pathlib import Path

from playwright.async_api import BrowserContext, Page, async_playwright

from config.settings import CHROME_PROFILE_PATH, VISION_ARTIFACT_DIR
from executors.browser.adapters.yc_apply import YCApplyAdapter


class BrowserExecutor:
    def __init__(self):
        self._playwright = None
        self._context: BrowserContext | None = None
        self._page: Page | None = None

    async def _ensure_browser(self):
        if self._context is None:
            self._playwright = await async_playwright().start()
            self._context = await self._playwright.chromium.launch_persistent_context(
                user_data_dir=CHROME_PROFILE_PATH,
                headless=False,
                args=["--no-first-run", "--no-default-browser-check"],
                viewport={"width": 1280, "height": 800},
            )
        if self._page is None or self._page.is_closed():
            pages = self._context.pages
            self._page = pages[0] if pages else await self._context.new_page()

    async def navigate(self, url: str):
        await self._ensure_browser()
        await self._page.goto(url, wait_until="domcontentloaded")

    async def yc_apply_fill(self, resume_path: str, slots: dict):
        await self._ensure_browser()
        adapter = YCApplyAdapter(self._page)
        await adapter.fill(resume_path=resume_path, slots=slots)

    async def yc_apply_submit(self):
        await self._ensure_browser()
        adapter = YCApplyAdapter(self._page)
        await adapter.submit()

    async def get_page_text(self) -> str:
        await self._ensure_browser()
        return await self._page.inner_text("body")

    async def capture_observation(self, label: str = "browser") -> dict:
        await self._ensure_browser()
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        artifacts_dir = Path(VISION_ARTIFACT_DIR).expanduser().resolve()
        artifacts_dir.mkdir(parents=True, exist_ok=True)
        screenshot_path = artifacts_dir / f"{label}_{timestamp}.png"
        await self._page.screenshot(path=str(screenshot_path), full_page=True)

        title = await self._page.title()
        url = self._page.url
        body_text = await self._page.inner_text("body")
        return {
            "scope": "browser",
            "label": label,
            "timestamp": timestamp,
            "screenshot_path": str(screenshot_path),
            "url": url,
            "title": title,
            "body_preview": body_text[:1200],
        }

    async def close(self):
        if self._context:
            await self._context.close()
        if self._playwright:
            await self._playwright.stop()
        self._context = None
        self._page = None
        self._playwright = None
