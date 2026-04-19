"""
Named file aliases and known contacts.
Edit KNOWN_CONTACTS with real phone numbers or iMessage emails before the demo.
"""

import os

FILE_ALIASES: dict[str, str] = {
    "resume": "~/Desktop/Omondi, Alspencer 03.03.2026.pdf",
}

# Hardcoded contacts — checked before querying Contacts.app.
# Keys are lowercase name variants Whisper might produce.
# Values are phone numbers (+1XXXXXXXXXX) or iMessage emails.
# --- Alspencer --- a lot of hardcoded shit here.
KNOWN_CONTACTS: dict[str, str] = {
    "hanzi":          "hanzili0217@gmail.com",
    "hanzi li":       "hanzili0217@gmail.com",
    "ethan":          "etsandoval@hmc.edu",
    "ethan sandoval": "etsandoval@hmc.edu",
    "korin":          "korintajima@gmail.com",
    "corin":          "korintajima@gmail.com",   # common Whisper mishearing
    "corinne":        "korintajima@gmail.com",   # another common mishearing
    "korin tajima":   "korintajima@gmail.com",
}
