import type { ApiVantariServerProps } from '$lib/types/api';

/**
 * VANTARI bridge client.
 *
 * The Vantari web UI speaks the Vantari bridge REST surface (`/props`,
 * `/v1/models`, `/v1/chat/completions` SSE). VANTARI's browser lane speaks
 * JSON-RPC over `/rpc` plus an SSE event lane over `/events`, both gated by
 * the bridge token that `/api/health` hands out in its handshake. This
 * module is the single translation owner: bridge token lifecycle, RPC
 * calls, event long-polling, and the mapping of VANTARI responses into the
 * shapes the UI's services already consume.
 */

const BRIDGE_ORIGIN: string =
	(import.meta.env.VITE_VANTARI_BRIDGE as string | undefined) ?? 'http://127.0.0.1:18833';
const BRIDGE_TOKEN_HEADER = 'x-var1-bridge-token';

let bridgeToken: string | null = null;
let tokenPromise: Promise<string> | null = null;
let rpcId = 0;
/** Resolve (and cache) the bridge token via the unauthenticated health handshake. */
export function ensureBridgeToken(): Promise<string> {
	if (bridgeToken) return Promise.resolve(bridgeToken);
	if (tokenPromise) return tokenPromise;
	tokenPromise = fetch(`${BRIDGE_ORIGIN}/api/health`)
		.then(async (response) => {
			if (!response.ok) throw new Error(`bridge handshake failed: ${response.status}`);
			const payload = (await response.json()) as { bridge_token?: string };
			if (!payload.bridge_token) throw new Error('bridge handshake returned no token');
			bridgeToken = payload.bridge_token;
			return bridgeToken;
		})
		.catch((error) => {
			tokenPromise = null;
			throw error;
		});
	return tokenPromise;
}

/** One JSON-RPC call through the browser lane. Throws on JSON-RPC errors. */
export async function rpc<T = unknown>(method: string, params: unknown = {}): Promise<T> {
	const token = await ensureBridgeToken();
	const response = await fetch(`${BRIDGE_ORIGIN}/rpc`, {
		body: JSON.stringify({ jsonrpc: '2.0', id: `web-${++rpcId}`, method, params }),
		headers: {
			'content-type': 'application/json',
			[BRIDGE_TOKEN_HEADER]: token
		},
		method: 'POST'
	});
	if (!response.ok) {
		throw new Error(`bridge rpc ${method} failed: ${response.status}`);
	}
	const payload = (await response.json()) as { result?: T; error?: { message?: string } };
	if (payload.error) {
		throw new Error(payload.error.message ?? `bridge rpc ${method} rejected`);
	}
	return payload.result as T;
}

export interface BridgeEvent {
	seq: number;
	event: string;
	data: Record<string, unknown>;
}

/**
 * Long-poll one event after `afterSeq`. Returns null on keepalive (nothing
 * new within the wait window). The bridge emits one SSE frame per poll:
 * `id: <seq>\nevent: <method>\ndata: <params>\n\n`.
 */
export async function pollEvent(afterSeq: number, waitMs = 1000): Promise<BridgeEvent | null> {
	const token = await ensureBridgeToken();
	const response = await fetch(`${BRIDGE_ORIGIN}/events?since=${afterSeq}&wait_ms=${waitMs}`, {
		headers: { [BRIDGE_TOKEN_HEADER]: token },
		method: 'GET'
	});
	if (!response.ok) throw new Error(`bridge events failed: ${response.status}`);
	const frame = await response.text();
	const idMatch = frame.match(/^id: (\d+)\n/m);
	const eventMatch = frame.match(/^event: (.+)$/m);
	const dataMatch = frame.match(/^data: (.*)$/m);
	if (!idMatch || !eventMatch) return null;
	let data: Record<string, unknown> = {};
	if (dataMatch) {
		try {
			data = JSON.parse(dataMatch[1]) as Record<string, unknown>;
		} catch {
			data = {};
		}
	}
	return { seq: Number(idMatch[1]), event: eventMatch[1], data };
}

interface VantariHealth {
	ok?: boolean;
	model?: string;
	workspace_root?: string;
	base_url?: string;
	context_window_tokens?: number;
}

/** Map VANTARI health into the Vantari bridge props shape the UI boots on. */
export function mapHealthToProps(health: VantariHealth): ApiVantariServerProps {
	return {
		default_generation_settings: {
			id: 0,
			id_task: 0,
			n_ctx: health.context_window_tokens ?? 128000,
			speculative: false,
			is_processing: false,
			params: {
				n_predict: -1,
				seed: -1,
				temperature: 0.8,
				dynatemp_range: 0,
				dynatemp_exponent: 1,
				top_k: 40,
				top_p: 0.95,
				min_p: 0.05,
				top_n_sigma: 0,
				xtc_probability: 0,
				xtc_threshold: 0.1,
				typ_p: 1,
				repeat_last_n: 64,
				repeat_penalty: 1,
				presence_penalty: 0,
				frequency_penalty: 0,
				dry_multiplier: 0,
				dry_base: 1.75,
				dry_allowed_length: 2,
				dry_penalty_last_n: -1,
				dry_sequence_breakers: ['\n', ':', '"', '*'],
				mirostat: 0,
				mirostat_tau: 5,
				mirostat_eta: 0.1,
				stop: [],
				max_tokens: -1,
				n_keep: 0,
				n_discard: 0,
				ignore_eos: false,
				stream: true,
				logit_bias: [],
				n_probs: 0,
				min_keep: 0,
				grammar: '',
				grammar_lazy: false,
				grammar_triggers: [],
				preserved_tokens: [],
				chat_format: 'chatml',
				reasoning_format: 'none',
				reasoning_in_content: false,
				generation_prompt: '',
				samplers: ['top_k', 'typ_p', 'top_p', 'min_p', 'temperature'],
				backend_sampling: false,
				'speculative.n_max': 0,
				'speculative.n_min': 0,
				'speculative.p_min': 0,
				timings_per_token: false,
				post_sampling_probs: false,
				lora: []
			},
			prompt: '',
			next_token: {
				has_next_token: false,
				has_new_line: false,
				n_remain: 0,
				n_decoded: 0,
				stopping_word: ''
			}
		},
		total_slots: 1,
		model_path: health.model ?? 'vantari',
		role: 'MODEL',
		modalities: { vision: false, audio: false, video: false },
		chat_template: 'chatml',
		bos_token: '',
		eos_token: '',
		build_info: 'vantari bridge',
		ui_settings: {}
	} as unknown as ApiVantariServerProps;
}

interface VantariModelsList {
	provider?: string;
	models?: Array<{ id: string; owned_by?: string | null; context_length?: number | null }>;
	status?: string;
	error_message?: string | null;
}

/** Map a VANTARI models/list result into the OpenAI /v1/models shape. */
export function mapModelsToList(list: VantariModelsList): {
	object: 'list';
	data: Array<{ id: string; object: 'model'; created: number; owned_by: string }>;
} {
	const models = list.models ?? [];
	return {
		object: 'list',
		data: models.map((model) => ({
			id: model.id,
			object: 'model' as const,
			created: 0,
			owned_by: model.owned_by ?? list.provider ?? 'vantari'
		}))
	};
}

/**
 * Session state for the chat lane. The UI resends the full message history
 * on every turn; VANTARI owns its own transcript, so only the latest user
 * message crosses the bridge and one bridge session serves the page.
 */
let chatSessionId: string | null = null;
let eventCursor = 0;

export async function ensureChatSession(): Promise<string> {
	if (chatSessionId) return chatSessionId;
	const result = await rpc<{ session_id?: string; session?: { session_id?: string } }>(
		'session/create',
		{ prompt: 'web session' }
	);
	chatSessionId = result?.session_id ?? result?.session?.session_id ?? null;
	if (!chatSessionId) throw new Error('session/create returned no session id');
	return chatSessionId;
}

function sseFrame(payload: unknown, id?: string | number): string {
	return `data: ${JSON.stringify(payload)}${id !== undefined ? `\nid: ${id}` : ''}\n\n`;
}

interface ChatRequestBody {
	messages?: Array<{ role: string; content: unknown }>;
	model?: string;
	stream?: boolean;
	[k: string]: unknown;
}

function lastUserText(body: ChatRequestBody): string {
	const messages = body.messages ?? [];
	for (let i = messages.length - 1; i >= 0; i -= 1) {
		const message = messages[i];
		if (message.role !== 'user') continue;
		if (typeof message.content === 'string') return message.content;
		if (Array.isArray(message.content)) {
			const text = message.content
				.map((part) =>
					part && typeof part === 'object' && 'text' in part ? String(part.text) : ''
				)
				.join('');
			if (text.trim()) return text;
		}
	}
	return '';
}

/**
 * The chat seam: runs one VANTARI provider turn and exposes it as an
 * OpenAI-compatible SSE Response so the UI's existing stream consumer
 * (ChatService.handleStreamResponse) reads it unchanged.
 *
 * Event mapping (VANTARI event -> OpenAI chunk):
 *   assistant_delta          -> choices[0].delta.content
 *   reasoning/reasoning_*    -> choices[0].delta.reasoning_content
 *   assistant_response       -> final full content (fallback when a provider
 *                               does not stream deltas)
 *   turn_terminal            -> finish_reason "stop" + [DONE]
 */
export async function vantariChatFetch(requestBody: ChatRequestBody): Promise<Response> {
	const sessionId = await ensureChatSession();
	const completionId = `vantari-${sessionId.slice(-8)}-${Date.now()}`;
	const prompt = lastUserText(requestBody);
	if (!prompt.trim()) {
		throw new Error('no user message to send');
	}

	// Fire the turn without awaiting: the deltas arrive on the event lane
	// while session/send blocks until the terminal state.
	const sendParams: Record<string, unknown> = { session_id: sessionId, prompt };
	if (typeof requestBody.model === 'string' && requestBody.model.trim()) {
		sendParams.model_override = requestBody.model;
	}
	const sendPromise = rpc('session/send', sendParams).catch((error: unknown) => error as Error);

	const encoder = new TextEncoder();
	const stream = new ReadableStream<Uint8Array>({
		async start(controller) {
			const enqueue = (payload: unknown) =>
				controller.enqueue(
					encoder.encode(`data: ${JSON.stringify(payload)}\nid: ${completionId}\n\n`)
				);
			let finished = false;
			let streamed_any = false;

			try {
				while (!finished) {
					let event: BridgeEvent | null = null;
					try {
						event = await pollEvent(eventCursor, 1000);
					} catch {
						// transient poll failure: keep the loop alive while the
						// turn is still running
						event = null;
					}
					if (!event) {
						if (await Promise.race([sendPromise.then(() => true), Promise.resolve(false)])) {
							const settled = await sendPromise;
							if (settled instanceof Error) throw settled;
						}
						continue;
					}
					eventCursor = event.seq;
					const data = event.data ?? {};
					if (data.session_id && data.session_id !== sessionId) continue;

					const eventType = String(data.event_type ?? event.event);
					const message = typeof data.message === 'string' ? data.message : '';

					if (eventType === 'assistant_delta' && message) {
						streamed_any = true;
						enqueue({
							id: completionId,
							object: 'chat.completion.chunk',
							choices: [{ index: 0, delta: { content: message }, finish_reason: null }]
						});
					} else if (eventType.includes('reasoning') && message) {
						enqueue({
							id: completionId,
							object: 'chat.completion.chunk',
							choices: [{ index: 0, delta: { reasoning_content: message }, finish_reason: null }]
						});
					} else if (eventType === 'assistant_response' && message && !streamed_any) {
						// Providers that do not stream deltas deliver one full
						// assistant_response; when deltas already streamed, the
						// response repeats them and must not be re-emitted.
						enqueue({
							id: completionId,
							object: 'chat.completion.chunk',
							choices: [{ index: 0, delta: { content: message }, finish_reason: null }]
						});
					} else if (eventType === 'turn_terminal') {
						enqueue({
							id: completionId,
							object: 'chat.completion.chunk',
							choices: [{ index: 0, delta: {}, finish_reason: 'stop' }]
						});
						finished = true;
					}
				}

				controller.enqueue(encoder.encode('data: [DONE]\n\n'));
				controller.close();
			} catch (error) {
				enqueue({
					error: {
						message: error instanceof Error ? error.message : 'bridge chat turn failed',
						type: 'bridge_error'
					}
				});
				controller.close();
			}
		}
	});

	return new Response(stream, {
		status: 200,
		headers: { 'content-type': 'text/event-stream' }
	});
}
