"""
Human-readable descriptions of each supported goal.
Used in prompts and UI copy.
"""

from intent.schema import KnownGoal

INTENT_DESCRIPTIONS = {
    KnownGoal.APPLY_TO_JOB:          "Apply to a job or program using your resume",
    KnownGoal.SEND_MESSAGE:          "Send an iMessage to a contact",
    KnownGoal.SEND_EMAIL:            "Compose and send an email via Mail",
    KnownGoal.ADD_CALENDAR_EVENT:    "Add an event to your Calendar",
    KnownGoal.OPEN_URL:              "Open a URL in the browser",
    KnownGoal.FIND_FILE:             "Find a file on disk by name or alias",
    KnownGoal.UNKNOWN:               "Unknown intent — ask user to rephrase",
}
