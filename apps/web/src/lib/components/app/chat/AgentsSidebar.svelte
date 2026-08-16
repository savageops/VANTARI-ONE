<script lang="ts">
	import { onMount } from 'svelte';
	import { Bot, ChevronRight, RefreshCw, X } from '@lucide/svelte';
	import { Badge } from '$lib/components/ui/badge';
	import { Button } from '$lib/components/ui/button';
	import { ScrollArea } from '$lib/components/ui/scroll-area';
	import { getSession, type VantariSessionMessage } from '$lib/services/vantari.service';
	import { vantariStore } from '$lib/stores/vantari.svelte';
	import { goto } from '$app/navigation';
	/**
	 * Agents panel: the kernel's specialist registry on the right edge of the
	 * chat. Clicking an agent resolves its latest session (sessions carry
	 * `agent_profile`) and streams its durable transcript into the drawer —
	 * the operator sees exactly what that agent said, from the same event
	 * truth the TUI reads.
	 */

	let open = $state(false);
		let selectedAgent = $state<string | null>(null);
	let transcript = $state<VantariSessionMessage[]>([]);
	let transcriptStatus = $state<string | null>(null);
	let loadingTranscript = $state(false);

	const agentSessions = $derived.by(() => {
		const byAgent = new Map<string, { status: string; session_id: string; updated: number }>();
		for (const session of vantariStore.sessions) {
			const profile = session.agent_profile;
			if (!profile) continue;
			const existing = byAgent.get(profile);
			if (!existing || session.updated_at_ms > existing.updated) {
				byAgent.set(profile, {
					session_id: session.session_id,
					status: session.status,
					updated: session.updated_at_ms
				});
			}
		}
		return byAgent;
	});

	async function loadAgent(agentId: string): Promise<void> {
		selectedAgent = agentId;
		transcript = [];
		transcriptStatus = null;
		const latest = agentSessions.get(agentId);
		if (!latest) {
			transcriptStatus = 'No sessions yet for this agent.';
			return;
		}
		loadingTranscript = true;
		try {
			const result = await getSession(latest.session_id);
			transcript = (result.messages ?? []).filter((message) => message.role !== 'tool');
			transcriptStatus = latest.status;
		} catch (error) {
			transcriptStatus = error instanceof Error ? error.message : 'session/get failed';
		}
		loadingTranscript = false;
	}

	async function refresh(): Promise<void> {
		await Promise.all([vantariStore.refresh(), vantariStore.refreshSessions()]);
		if (selectedAgent) await loadAgent(selectedAgent);
	}

	function roleClass(role: string): string {
		if (role === 'user') return 'text-foreground';
		if (role === 'assistant') return 'text-foreground';
		return 'text-muted-foreground';
	}

	onMount(() => {
		void vantariStore.refresh();
		void vantariStore.refreshSessions();
	});
</script>

{#if !open}
	<button
		class="fixed right-0 top-1/2 z-40 -translate-y-1/2 rounded-l-md border border-r-0 bg-background px-1.5 py-3 text-muted-foreground shadow-sm hover:text-foreground"
		onclick={() => (open = true)}
		aria-label="Open agents panel"
	>
		<ChevronRight class="size-4 rotate-180" />
		<Bot class="mt-2 size-4" />
		<span class="mt-1 block text-[10px] leading-none">{vantariStore.agents.length}</span>
	</button>
{:else}
	<aside
		class="fixed right-0 top-0 z-40 flex h-full w-80 flex-col border-l bg-background shadow-xl"
	>
		<header class="flex items-center justify-between border-b px-3 py-2">
			<div class="flex items-center gap-2">
				<Bot class="size-4 text-muted-foreground" />
				<span class="text-sm font-medium">Agents</span>
				{#if selectedAgent}
					<span class="text-xs text-muted-foreground">· {selectedAgent}</span>
				{/if}
			</div>
			<div class="flex items-center gap-1">
				<Button
					variant="ghost"
					size="sm"
					class="text-xs"
					onclick={() => goto('/vantari')}
					aria-label="Manage providers and agents"
				>
					Manage
				</Button>
				<Button variant="ghost" size="icon-sm" onclick={refresh} aria-label="Refresh agents">
					<RefreshCw class="size-4" />
				</Button>
				<Button variant="ghost" size="icon-sm" onclick={() => (open = false)} aria-label="Close">
					<X class="size-4" />
				</Button>
			</div>
		</header>

		<div class="flex min-h-0 flex-1 flex-col">
			<ScrollArea class="h-44 border-b">
				<div class="flex flex-col p-2">
					{#each vantariStore.agents as agent (agent.id)}
						<button
							class="flex items-center justify-between rounded-md px-2 py-1.5 text-left hover:bg-accent
								{selectedAgent === agent.id ? 'bg-accent' : ''}"
							onclick={() => loadAgent(agent.id)}
						>
							<span class="flex flex-col">
								<span class="text-sm">{agent.id}</span>
								<span class="text-[11px] text-muted-foreground">
									{agent.description || agent.route_role || 'specialist'}
								</span>
							</span>
							{#if agentSessions.get(agent.id)}
								<Badge variant="secondary" class="text-[10px]">
									{agentSessions.get(agent.id)?.status}
								</Badge>
							{/if}
						</button>
					{/each}
					{#if vantariStore.agents.length === 0}
						<p class="p-2 text-xs text-muted-foreground">
							{#if vantariStore.error}
								{vantariStore.error}
							{:else}
								Loading registry…
							{/if}
						</p>
					{/if}
				</div>
			</ScrollArea>

			<ScrollArea class="min-h-0 flex-1">
				<div class="flex flex-col gap-3 p-3">
					{#if !selectedAgent}
						<p class="text-xs text-muted-foreground">
							Select an agent to read its latest session transcript.
						</p>
					{:else if loadingTranscript}
						<p class="text-xs text-muted-foreground">Loading transcript…</p>
					{:else if transcript.length === 0}
						<p class="text-xs text-muted-foreground">{transcriptStatus}</p>
					{:else}
						<p class="text-[11px] uppercase tracking-wide text-muted-foreground">
							{transcriptStatus}
						</p>
						{#each transcript as message (message.id ?? `${message.seq}`)}
							<div class="rounded-md border p-2">
								<span class="text-[10px] uppercase text-muted-foreground">{message.role}</span>
								<p class="mt-1 whitespace-pre-wrap text-xs {roleClass(message.role)}">
									{message.content}
								</p>
							</div>
						{/each}
					{/if}
				</div>
			</ScrollArea>
		</div>
	</aside>
{/if}
