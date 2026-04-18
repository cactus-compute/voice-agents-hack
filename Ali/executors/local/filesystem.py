"""
Layer 4A — Local Executor: Filesystem
Named alias lookup so the agent can reference "resume" instead of full paths.
"""

import os

from config.resources import FILE_ALIASES


class FilesystemExecutor:
    def find_by_alias(self, alias: str) -> str:
        """
        Return the absolute path for a named file alias.
        Raises FileNotFoundError if the alias is not configured or the file is missing.
        """
        path = FILE_ALIASES.get(alias)
        if not path:
            raise FileNotFoundError(
                f"No file alias '{alias}' configured. Add it to config/resources.py."
            )
        expanded = os.path.expanduser(path)
        if not os.path.exists(expanded):
            raise FileNotFoundError(
                f"File alias '{alias}' points to '{expanded}' but the file does not exist."
            )
        return expanded

    def read_text(self, alias: str) -> str:
        path = self.find_by_alias(alias)
        with open(path, "r", encoding="utf-8") as f:
            return f.read()

    def list_aliases(self) -> dict[str, str]:
        return dict(FILE_ALIASES)
