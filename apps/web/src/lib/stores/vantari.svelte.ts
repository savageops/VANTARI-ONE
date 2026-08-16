import {
	configureAgent,
	detectCredentials,
	getHealth,
	importCredentials,
	listAgents,
	listModels,
	listProviders,
	listSessions,
	setConfigKey,
	setProviderModel,
	type VantariAgent,
	type VantariDetectedCredential,
	type VantariHealthState,
	type VantariProvider,
	type VantariSessionSummary
} from '$lib/services/vantari.service';
/**
 * Reactive projection of the kernel's management surfaces: health, provider
 * ledger, agent registry, and the session index used to resolve an agent's
 * latest chat. All mutations go through the bridge RPC owners and refresh
 * the affected slice on success.
 */

interface VantariStore {
	agents: VantariAgent[];
	agentsLoading: boolean;
	detected: VantariDetectedCredential[];
	error: string | null;
	health: VantariHealthState | null;
	modelCatalogs: Record<string, string[]>;
	providers: VantariProvider[];
	activeProvider: string | null;
	sessions: VantariSessionSummary[];
	configureAgent: (
		agentId: string,
		patch: { provider_id?: string; model?: string }
	) => Promise<boolean>;
	importSource: (source: string) => Promise<boolean>;
	modelCatalog: (providerId: string) => Promise<string[]>;
	refresh: () => Promise<void>;
	refreshSessions: () => Promise<void>;
	setConfigKey: (key: string, value: string | number | boolean) => Promise<boolean>;
	setProviderModel: (providerId: string, model: string) => Promise<boolean>;
}

export const vantariStore = $state<VantariStore>({
	activeProvider: null,
	agents: [],
	agentsLoading: false,
	detected: [],
	error: null,
	health: null,
	modelCatalogs: {},
	providers: [],
	sessions: [],

	async refresh(): Promise<void> {
		vantariStore.error = null;
		try {
			const [healthState, providersResult, agentsResult, detection] = await Promise.all([
				getHealth(),
				listProviders(),
				listAgents(),
				detectCredentials()
			]);
			vantariStore.health = healthState;
			vantariStore.providers = providersResult.providers;
			vantariStore.activeProvider = providersResult.active_provider;
			vantariStore.agents = agentsResult.agents;
			vantariStore.detected = detection.detected.filter(
				(entry) => entry.live && entry.source !== 'env'
			);
		} catch (error) {
			vantariStore.error = error instanceof Error ? error.message : 'bridge refresh failed';
		}
	},

	async refreshSessions(): Promise<void> {
		try {
			const result = await listSessions();
			vantariStore.sessions = result.sessions ?? [];
		} catch {
			vantariStore.sessions = [];
		}
	},

	async modelCatalog(providerId: string): Promise<string[]> {
		const cached = vantariStore.modelCatalogs[providerId];
		if (cached) return cached;
		const result = await listModels(providerId);
		const ids = (result.models ?? []).map((model) => model.id);
		vantariStore.modelCatalogs = { ...vantariStore.modelCatalogs, [providerId]: ids };
		return ids;
	},

	async setProviderModel(providerId: string, model: string): Promise<boolean> {
		try {
			await setProviderModel(providerId, model);
			const provider = vantariStore.providers.find((entry) => entry.provider_id === providerId);
			if (provider) provider.model = model;
			if (vantariStore.health) vantariStore.health.model = model;
			return true;
		} catch (error) {
			vantariStore.error = error instanceof Error ? error.message : 'set-model failed';
			return false;
		}
	},

	async configureAgent(
		agentId: string,
		patch: { provider_id?: string; model?: string }
	): Promise<boolean> {
		try {
			await configureAgent(agentId, patch);
			const agent = vantariStore.agents.find((entry) => entry.id === agentId);
			if (agent) {
				if (patch.provider_id !== undefined) agent.provider_id = patch.provider_id;
				if (patch.model !== undefined) agent.model = patch.model;
			}
			return true;
		} catch (error) {
			vantariStore.error = error instanceof Error ? error.message : 'agents/configure failed';
			return false;
		}
	},

	async setConfigKey(key: string, value: string | number | boolean): Promise<boolean> {
		try {
			await setConfigKey('runtime', key, value);
			if (vantariStore.health) {
				if (key === 'log_level') vantariStore.health.log_level = String(value);
				if (key === 'effort') vantariStore.health.effort = String(value);
				if (key === 'full_access_mode') vantariStore.health.full_access_mode = Boolean(value);
			}
			return true;
		} catch (error) {
			vantariStore.error = error instanceof Error ? error.message : 'config/set failed';
			return false;
		}
	},

	async importSource(source: string): Promise<boolean> {
		try {
			const result = await importCredentials([source]);
			if ((result.imported ?? []).length === 0) {
				vantariStore.error = `Import skipped: ${source} provider is owned by another credential source`;
				return false;
			}
			await vantariStore.refresh();
			return true;
		} catch (error) {
			vantariStore.error = error instanceof Error ? error.message : 'auth/import failed';
			return false;
		}
	}
});
