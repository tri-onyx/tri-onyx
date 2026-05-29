import logging
import time

from django.conf import settings
from django.http import JsonResponse

logger = logging.getLogger(__name__)

_prompt_timestamps: dict[str, float] = {}


class PromptRateLimitMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response
        self.min_interval = getattr(settings, "PROMPT_RATE_LIMIT_SECONDS", 1.0)

    def __call__(self, request):
        if request.method == "POST" and request.path.endswith("/prompt"):
            ip = self._get_client_ip(request)
            now = time.monotonic()
            last = _prompt_timestamps.get(ip, 0)

            if now - last < self.min_interval:
                logger.warning("Rate limited prompt from %s", ip)
                return JsonResponse(
                    {"error": "Too many requests, please slow down"},
                    status=429,
                )

            _prompt_timestamps[ip] = now
            self._cleanup(now)

        return self.get_response(request)

    def _get_client_ip(self, request):
        forwarded = request.META.get("HTTP_X_FORWARDED_FOR")
        if forwarded:
            return forwarded.split(",")[0].strip()
        return request.META.get("REMOTE_ADDR", "unknown")

    def _cleanup(self, now):
        if len(_prompt_timestamps) > 1000:
            stale = [k for k, v in _prompt_timestamps.items() if now - v > 60]
            for k in stale:
                del _prompt_timestamps[k]


class RequestLoggingMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        response = self.get_response(request)

        if request.path == "/healthz":
            return response

        logger.info(
            '%s %s %d [%s]',
            request.method,
            request.path,
            response.status_code,
            self._get_client_ip(request),
        )
        return response

    def _get_client_ip(self, request):
        forwarded = request.META.get("HTTP_X_FORWARDED_FOR")
        if forwarded:
            return forwarded.split(",")[0].strip()
        return request.META.get("REMOTE_ADDR", "unknown")
