<script lang="ts">
	import { onMount } from 'svelte';
	import { RefreshCw, X } from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import * as Card from '$lib/components/ui/card';
	import { Label } from '$lib/components/ui/label';
	import * as Select from '$lib/components/ui/select';
	import { Switch } from '$lib/components/ui/switch';
	import { vantariStore } from '$lib/stores/vantari.svelte';

	let { open = $bindable(false) } = $props();

	let logLevel = $state('silent');
	let effort = $state('medium');
	let fullAccess = $state(false);
	let loaded = $state(false);
	let busy = $state<string | null>(null);
	let notice = $state<string | null>(null);

	const efforts = ['low', 'medium', 'high', 'max'] as const;

	const providerCatalogs = $state<Record<string, string[]>>({});
	const agentCatalogs = $state<Record<string, string[]>>({});

	async function load(): Promise<void> {
		busy = 'refresh';
		await vantariStore.refresh();
		logLevel = vantariStore.health?.log_level ?? 'silent';
		effort = vantariStore.health?.effort || 'medium';
		fullAccess = vantariStore.health?.full_access_mode ?? false;
		loaded = true;
		busy = null;
	}

	async function changeLogLevel(value: string): Promise<void> {
		logLevel = value;
		if (await vantariStore.setConfigKey('log_level', value)) {
			notice = `log_level set to ${value}`;
		}
	}

	async function changeEffort(value: string): Promise<void> {
		effort = value;
		if (await vantariStore.setConfigKey('effort', value)) {
			notice = `effort set to ${value}`;
		}
	}

	async function changeFullAccess(checked: boolean): Promise<void> {
		fullAccess = checked;
		if (await vantariStore.setConfigKey('full_access_mode', checked)) {
			notice = `full_access_mode set to ${String(checked)}`;
		}
	}

	async function changeProviderModel(providerId: string, current: string): Promise<void> {
		const catalog = providerCatalogs[providerId] ?? (await vantariStore.modelCatalog(providerId));
		providerCatalogs[providerId] = catalog;
		const index = catalog.indexOf(current);
		if (index === -1) return;
		const next = catalog[(index + 1) % catalog.length];
		busy = `provider:${providerId}`;
		if (await vantariStore.setProviderModel(providerId, next)) {
			notice = `${providerId} model set to ${next}`;
		}
		busy = null;
	}

	async function cycleAgentModel(agentId: string, current: string): Promise<void> {
		const agent = vantariStore.agents.find((entry) => entry.id === agentId);
		const providerId = agent?.provider_id || vantariStore.activeProvider || '';
		if (!providerId) return;
		const key = `${agentId}:${providerId}`;
		const catalog = agentCatalogs[key] ?? (await vantariStore.modelCatalog(providerId));
		agentCatalogs[key] = catalog;
		const index = catalog.indexOf(current);
		if (index === -1 || catalog.length === 0) return;
		const next = catalog[(index + 1) % catalog.length];
		busy = `agent:${agentId}`;
		if (await vantariStore.configureAgent(agentId, { model: next })) {
			notice = `${agentId} model set to ${next}`;
		}
		busy = null;
	}

	async function importSource(source: string): Promise<void> {
		busy = `import:${source}`;
		if (await vantariStore.importSource(source)) {
			notice = `Imported ${source} credentials`;
		}
		busy = null;
	}

	onMount(() => {
		if (open) void load();
	});
</script>

<div class="flex flex-col gap-5">
	<header class="flex items-center gap-3">
		<div>
			<h1 class="text-lg font-semibold">Vantari</h1>
			<p class="text-xs text-muted-foreground">
				{vantariStore.health?.workspace_root ?? 'workspace'} ·
				{vantariStore.activeProvider ?? 'no provider'}
				{#if vantariStore.health?.agent_pool_max}
					· pool {vantariStore.health.agent_pool_running}/{vantariStore.health.agent_pool_max}
				{/if}
			</p>
		</div>
		<div class="ml-auto flex items-center gap-2">
			{#if notice}
				<span class="text-xs text-muted-foreground">{notice}</span>
			{/if}
			{#if vantariStore.error}
				<span class="text-xs text-destructive">{vantariStore.error}</span>
			{/if}
			<Button
				variant="ghost"
				size="icon-sm"
				onclick={() => (open = false)}
				aria-label="Close panel"
			>
				<X class="size-4" />
			</Button>
			<Button variant="outline" size="sm" onclick={load} disabled={busy === 'refresh'}>
				<RefreshCw class="size-4" />Refresh
			</Button>
		</div>
	</header>

	{#if loaded}
		<Card.Root>
			<Card.Header>
				<Card.Title>Runtime</Card.Title>
				<Card.Description>
					Workspace posture, hot-loaded on the next turn through the audited config owner.
				</Card.Description>
			</Card.Header>
			<Card.Content class="grid gap-4 sm:grid-cols-3">
				<div class="grid gap-2">
					<Label for="log-level">Chat detail posture</Label>
					<Select.Root type="single" value={logLevel} onValueChange={changeLogLevel}>
						<Select.Trigger id="log-level">{logLevel}</Select.Trigger>
						<Select.Content>
							<Select.Item value="silent" label="silent">silent</Select.Item>
							<Select.Item value="normal" label="normal">normal</Select.Item>
							<Select.Item value="full" label="full">full</Select.Item>
						</Select.Content>
					</Select.Root>
				</div>
				<div class="grid gap-2">
					<Label for="effort">Effort</Label>
					<Select.Root type="single" value={effort} onValueChange={changeEffort}>
						<Select.Trigger id="effort">{effort}</Select.Trigger>
						<Select.Content>
							{#each efforts as level (level)}
								<Select.Item value={level} label={level}>{level}</Select.Item>
							{/each}
						</Select.Content>
					</Select.Root>
				</div>
				<div class="flex items-center justify-between rounded-lg border p-3">
					<div class="space-y-0.5">
						<Label>Full access mode</Label>
						<p class="text-xs text-muted-foreground">
							{fullAccess ? 'workspace boundary lifted' : 'paths stay in workspace'}
						</p>
					</div>
					<Switch checked={fullAccess} onCheckedChange={changeFullAccess} />
				</div>
			</Card.Content>
		</Card.Root>

		<Card.Root>
			<Card.Header>
				<Card.Title>Providers &amp; models</Card.Title>
				<Card.Description>
					Connected providers from the auth ledger. Click a model to cycle through the provider's
					catalog; the write applies on the next turn.
				</Card.Description>
			</Card.Header>
			<Card.Content class="flex flex-col gap-2">
				{#each vantariStore.providers as provider (provider.provider_id)}
					<button
						class="flex items-center justify-between rounded-lg border px-3 py-2 text-left hover:bg-accent"
						onclick={() => changeProviderModel(provider.provider_id, provider.model)}
						disabled={busy === `provider:${provider.provider_id}`}
					>
						<span class="flex flex-col">
							<span class="text-sm font-medium">
								{provider.provider_id}
								{#if provider.active}
									<span class="ml-1 text-xs text-muted-foreground">(active)</span>
								{/if}
							</span>
							<span class="text-xs text-muted-foreground">
								{provider.credential_source ?? provider.auth_type ?? 'manual'}
								{provider.base_url ? `· ${provider.base_url}` : ''}
							</span>
						</span>
						<span class="font-mono text-xs">{provider.model}</span>
					</button>
				{/each}

				{#if vantariStore.detected.length > 0}
					<div class="mt-2 border-t pt-3">
						<p class="mb-2 text-xs font-medium text-muted-foreground">
							Detected native credentials — import to connect
						</p>
						{#each vantariStore.detected as credential (credential.source + credential.provider_id)}
							<div class="flex items-center justify-between rounded-lg border px-3 py-2">
								<span class="flex flex-col">
									<span class="text-sm">{credential.provider_id}</span>
									<span class="text-xs text-muted-foreground">
										detected: {credential.source}
										{credential.account_hint ? `· ${credential.account_hint}` : ''}
									</span>
								</span>
								<Button
									size="sm"
									variant="outline"
									onclick={() => importSource(credential.source)}
									disabled={busy === `import:${credential.source}`}
								>
									Import
								</Button>
							</div>
						{/each}
					</div>
				{/if}
			</Card.Content>
		</Card.Root>

		<Card.Root>
			<Card.Header>
				<Card.Title>Agents</Card.Title>
				<Card.Description>
					The kernel's specialist registry. Click a model to cycle its provider catalog; assignments
					hot-load on the next agents snapshot.
				</Card.Description>
			</Card.Header>
			<Card.Content class="flex flex-col gap-2">
				{#each vantariStore.agents as agent (agent.id)}
					<div class="flex items-center justify-between rounded-lg border px-3 py-2">
						<span class="flex flex-col">
							<span class="text-sm font-medium">{agent.id}</span>
							<span class="text-xs text-muted-foreground">
								{agent.description || agent.route_role || 'specialist'}
							</span>
						</span>
						<button
							class="font-mono text-xs hover:text-accent-foreground"
							onclick={() => cycleAgentModel(agent.id, agent.model || '')}
							disabled={busy === `agent:${agent.id}`}
						>
							{agent.provider_id || vantariStore.activeProvider || '—'}
							{#if agent.model}
								<span class="ml-1 text-muted-foreground">{agent.model}</span>
							{/if}
						</button>
					</div>
				{/each}
				{#if vantariStore.agents.length === 0}
					<p class="text-xs text-muted-foreground">No agents in the registry.</p>
				{/if}
			</Card.Content>
		</Card.Root>
	{/if}
</div>
