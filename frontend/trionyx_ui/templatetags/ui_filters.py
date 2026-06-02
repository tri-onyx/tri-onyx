from datetime import datetime

from django import template

register = template.Library()


@register.filter
def risk_class(value):
    if not value:
        return "low"
    normalized = value.lower().replace(" ", "").split("/")[0]
    if normalized in ("low", "medium", "moderate", "high", "critical"):
        return normalized
    return "low"


@register.filter
def iso_short(value):
    if not value:
        return ""
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return dt.strftime("%b %d, %H:%M")
    except (ValueError, AttributeError):
        return value
