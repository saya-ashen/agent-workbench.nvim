/**
 * Agent Workbench tree navigation bridge.
 *
 * The RPC protocol exposes `get_tree` but no `navigate_tree` command, so
 * frontends cannot move the session leaf the way the TUI's /tree does.
 * `navigateTree` is only reachable from an ExtensionCommandContext, i.e. from
 * a registered command handler — and extension commands are invocable over RPC
 * via the `prompt` command (`/tree <args>`). The handler is awaited before the
 * prompt response is sent, so callers observe completion (including branch
 * summarization) synchronously.
 *
 * Protocol: /tree <entryId> [none|summary|custom] [custom instructions...]
 *   none    - navigate without summarizing the abandoned branch (default)
 *   summary - navigate and summarize the abandoned branch
 *   custom  - navigate and summarize with the given custom instructions
 *
 * Loaded by Agent Workbench via `--extension <plugin>/extensions/tree.ts`; disable
 * with `require("agent-workbench").setup({ tree = { enabled = false } })`.
 */

type TreeContext = {
	navigateTree?: (
		entryId: string,
		options: { summarize: boolean; customInstructions?: string },
	) => Promise<{ cancelled: boolean }>;
	ui: { notify: (message: string, level: "info" | "warning" | "error") => void };
};

type ExtensionAPI = {
	registerCommand: (
		name: string,
		command: {
			description: string;
			handler: (args: string, ctx: TreeContext) => Promise<void>;
		},
	) => void;
};

export default function treeBridge(pi: ExtensionAPI) {
	pi.registerCommand("tree", {
		description:
			"Navigate to a point in the session tree (backend for Agent Workbench :AgentWorkbenchTree)",
		handler: async (args, ctx) => {
			if (typeof ctx.navigateTree !== "function") {
				throw new Error(
					"ctx.navigateTree is unavailable: this pi version does not support tree navigation. " +
						"Upgrade pi or disable the feature: require('agent-workbench').setup({ tree = { enabled = false } })",
				);
			}

			const trimmed = args.trim();
			if (trimmed === "") {
				throw new Error(
					"usage: /tree <entryId> [none|summary|custom] [custom instructions...]",
				);
			}

			const firstSpace = trimmed.indexOf(" ");
			const entryId = firstSpace === -1 ? trimmed : trimmed.slice(0, firstSpace);
			const rest = firstSpace === -1 ? "" : trimmed.slice(firstSpace + 1).trim();

			let summarize = false;
			let customInstructions: string | undefined;
			if (rest === "" || rest === "none") {
				summarize = false;
			} else if (rest === "summary") {
				summarize = true;
			} else if (rest === "custom" || rest.startsWith("custom ")) {
				summarize = true;
				customInstructions = rest === "custom" ? "" : rest.slice("custom ".length);
			} else {
				throw new Error(
					`unknown tree mode "${rest}" (expected none|summary|custom)`,
				);
			}

			const result = await ctx.navigateTree(entryId, {
				summarize,
				customInstructions,
			});
			if (result.cancelled) {
				ctx.ui.notify("Tree navigation was cancelled by an extension", "info");
			}
		},
	});
}
