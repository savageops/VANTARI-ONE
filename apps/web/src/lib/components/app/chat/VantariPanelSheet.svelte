<script lang="ts">
	import * as Sheet from '$lib/components/ui/sheet';
	import VantariPanel from './VantariPanel.svelte';

	let { open = $bindable(false) } = $props();
</script>

<Sheet.Root bind:open>
	<Sheet.Content side="right" class="w-[42rem] overflow-y-auto p-6 sm:max-w-[42rem]">
		<Sheet.Header class="sr-only">
			<Sheet.Title>Vantari management</Sheet.Title>
			<Sheet.Description>
				Runtime settings, provider models, and agent assignments.
			</Sheet.Description>
		</Sheet.Header>
		<VantariPanel bind:open />
	</Sheet.Content>
</Sheet.Root>
