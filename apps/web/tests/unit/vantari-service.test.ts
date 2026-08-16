import { describe, expect, it, vi, beforeEach } from 'vitest';
import {
	ensureBridgeToken,
	invalidateBridgeTokenForTests,
	mapHealthToProps,
	mapModelsToList,
	rpc
} from '$lib/services/vantari.service';

/**
 * Translation-layer tests for the VANTARI bridge service: props mapping
 * honesty, model-list mapping, and the unauthorized re-handshake contract
 * (owner restart invalidates the cached token and retries exactly once).
 */

const healthResponse = () =>
	new Response(JSON.stringify({ ok: true, bridge_token: 'token-one' }), { status: 200 });

const rpcResponse = (payload: unknown, status = 200) =>
	new Response(JSON.stringify(payload), { status });

describe('mapHealthToProps', () => {
	it('projects only health-derived facts with the vantari build stamp', () => {
		const props = mapHealthToProps({
			ok: true,
			model: 'glm-5-turbo',
			context_window_tokens: 131072
		});
		expect(props.model_path).toBe('glm-5-turbo');
		expect(props.default_generation_settings.n_ctx).toBe(131072);
		expect(props.build_info).toBe('vantari bridge');
		expect(props.role).toBe('MODEL');
		expect(props.modalities).toEqual({ vision: false, audio: false, video: false });
	});

	it('falls back to a sane context window when health omits it', () => {
		const props = mapHealthToProps({ ok: true });
		expect(props.default_generation_settings.n_ctx).toBeGreaterThan(0);
	});
});

describe('mapModelsToList', () => {
	it('maps a provider catalog into the OpenAI list shape', () => {
		const list = mapModelsToList({
			provider: 'zai',
			models: [
				{ id: 'glm-5.2', owned_by: 'z-ai', context_length: 128000 },
				{ id: 'glm-5.3', owned_by: null, context_length: null }
			]
		});
		expect(list.object).toBe('list');
		expect(list.data).toHaveLength(2);
		expect(list.data[0]).toMatchObject({ id: 'glm-5.2', object: 'model', owned_by: 'z-ai' });
		expect(list.data[1].owned_by).toBe('zai');
	});

	it('returns an empty catalog for an error envelope', () => {
		const list = mapModelsToList({ provider: 'x', models: [], status: 'unreachable' });
		expect(list.data).toEqual([]);
	});
});

describe('bridge rpc re-handshake', () => {
	beforeEach(() => {
		vi.restoreAllMocks();
		invalidateBridgeTokenForTests();
	});

	it('retries once with a fresh token after an owner restart', async () => {
		const fetchMock = vi.fn()
			// handshake (token-one)
			.mockResolvedValueOnce(healthResponse())
			// first rpc attempt with the stale token -> unauthorized
			.mockResolvedValueOnce(rpcResponse({ ok: false, error: 'BridgeTokenRequired' }, 401))
			// re-handshake (token-two)
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ ok: true, bridge_token: 'token-two' }), { status: 200 })
			)
			// retried rpc succeeds
			.mockResolvedValueOnce(rpcResponse({ result: { agents: [] } }));
		vi.stubGlobal('fetch', fetchMock);

		const result = await rpc('agents/list', {});
		expect(result).toEqual({ agents: [] });

		const rpcCalls = fetchMock.mock.calls.filter(([url]) => String(url).endsWith('/rpc'));
		expect(rpcCalls).toHaveLength(2);
		expect(rpcCalls[0][1].headers['x-var1-bridge-token']).toBe('token-one');
		expect(rpcCalls[1][1].headers['x-var1-bridge-token']).toBe('token-two');
	});

	it('fails after one retry when the second attempt is still unauthorized', async () => {
		const fetchMock = vi.fn()
			.mockResolvedValueOnce(healthResponse())
			.mockResolvedValue(rpcResponse({ error: 'BridgeTokenRequired' }, 401));
		vi.stubGlobal('fetch', fetchMock);

		await expect(rpc('health/get', {})).rejects.toThrow('failed: 401');
		expect(fetchMock).toHaveBeenCalledTimes(3);
	});

	it('resolves the handshake token once for concurrent callers', async () => {
		const fetchMock = vi.fn()
			.mockResolvedValueOnce(healthResponse())
			.mockResolvedValue(rpcResponse({ result: {} }));
		vi.stubGlobal('fetch', fetchMock);

		await Promise.all([ensureBridgeToken(), ensureBridgeToken(), ensureBridgeToken()]);
		const handshakeCalls = fetchMock.mock.calls.filter(([url]) =>
			String(url).endsWith('/api/health')
		);
		expect(handshakeCalls).toHaveLength(1);
	});
});
