<script lang="ts">
	import { page } from '$app/state';
	import { ChatScreen } from '$lib/components/app';
	import AgentsSidebar from '$lib/components/app/chat/AgentsSidebar.svelte';

	let { children } = $props();

	let showCenteredEmpty = $derived(!page.params.id);
</script>

<ChatScreen {showCenteredEmpty} />

<AgentsSidebar />

{@render children?.()}
