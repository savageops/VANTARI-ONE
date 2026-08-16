import { redactValue } from './redact';
import { CORS_PROXY, HEADERS } from '$lib/constants';
import { MimeTypeApplication } from '$lib/enums';
import { settingsStore } from '$lib/stores/settings.svelte';

/**
 * Get authorization headers for EXTERNAL API requests (CORS-proxied remote
 * models): unchanged Vantari behavior. The VANTARI bridge lane does not
 * use these — bridge requests carry `x-var1-bridge-token` and are routed
 * through the vantari service, which resolves the token from the
 * `/api/health` handshake.
 */
export function getAuthHeaders(): Record<string, string> {
	const currentConfig = settingsStore.config;
	const apiKey = currentConfig.apiKey?.toString().trim();

	return apiKey ? { [HEADERS.AUTHORIZATION]: `${HEADERS.BEARER}${apiKey}` } : {};
}

/**
 * Get standard JSON headers with optional authorization
 */
export function getJsonHeaders(): Record<string, string> {
	return {
		[HEADERS.CONTENT_TYPE]: MimeTypeApplication.JSON,
		...getAuthHeaders()
	};
}

/**
 * Sanitize HTTP headers by redacting sensitive values.
 * Known sensitive headers (from HEADERS.REDACTED) and any extra headers
 * specified by the caller are fully redacted. Headers listed in
 * `partialRedactHeaders` are partially redacted, showing only the
 * specified number of trailing characters.
 *
 * @param headers - Headers to sanitize
 * @param extraRedactedHeaders - Additional header names to fully redact
 * @param partialRedactHeaders - Map of header name -> number of trailing chars to keep visible
 * @returns Object with header names as keys and (possibly redacted) values
 */
export function sanitizeHeaders(
	headers?: HeadersInit,
	extraRedactedHeaders?: Iterable<string>,
	partialRedactHeaders?: Map<string, number>
): Record<string, string> {
	if (!headers) {
		return {};
	}

	const normalized = new Headers(headers);
	const sanitized: Record<string, string> = {};
	const redactedHeaders = new Set(
		Array.from(extraRedactedHeaders ?? [], (header) => header.toLowerCase())
	);

	for (const [key, value] of normalized.entries()) {
		const normalizedKey = key.toLowerCase();
		const unproxiedKey = normalizedKey.startsWith(CORS_PROXY.HEADER_PREFIX)
			? normalizedKey.slice(CORS_PROXY.HEADER_PREFIX.length)
			: normalizedKey;
		const partialChars =
			partialRedactHeaders?.get(normalizedKey) ?? partialRedactHeaders?.get(unproxiedKey);

		if (partialChars !== undefined) {
			sanitized[key] = redactValue(value, partialChars);
		} else if (
			HEADERS.REDACTED.has(normalizedKey) ||
			HEADERS.REDACTED.has(unproxiedKey) ||
			redactedHeaders.has(normalizedKey) ||
			redactedHeaders.has(unproxiedKey)
		) {
			sanitized[key] = redactValue(value);
		} else {
			sanitized[key] = value;
		}
	}

	return sanitized;
}
