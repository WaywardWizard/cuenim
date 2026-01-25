package workflows

import "cue.dev/x/githubactions@v0"

// GitHub Actions workflow to generate and publish documentation to GitHub Pages
workflows: {
	[string]: githubactions.#Workflow
	"generate-publish": {
		name: "Generate and Publish Documentation"
		on: {
			release: types: ["published"]
			workflow_dispatch: {}
		}
		concurrency: {
			group:                "generate-publish"
			"cancel-in-progress": false
		}
		permissions: {
			contents: "write"
			pages: "write"
			"id-token": "write"
		}

		// Environment variables for the workflow
		env: {
			FORCE_COLOR: "1"
			//NIMBLE_DIR:  "/root/.nimble"
		}

		// Single job that generates docs and prepares for Pages
		jobs: {
			builddeploy: {
				"runs-on": "ubuntu-latest"

				// Set up Pages deployment
				environment: {
					name: "github-pages"
					url:  "${{ steps.deployment.outputs.page_url }}"
				}

				steps: [
					{
						name: "Checkout"
						uses: "actions/checkout@v6"
					}, // Checkout the repository
					{
						name: "Setup Nim"
						uses: "jiro4989/setup-nim-action@v2"
						with: {
							"nim-version": "2.2.x"
							"repo-token":  "${{ secrets.GITHUB_TOKEN }}"
						}
					}, // Set up Nim compiler
					{
						name: "Enumerate dependencies"
						run:  "nimble --silent deps > deps.txt"
					}, {
						name: "Cache Nimble packages"
						uses: "actions/cache@v5"
						with: {
							path: "~/.nimble"
							key:  "${{ runner.os }}-nimble-${{ hashFiles('deps.txt') }}"
						}
					}, // Cache Nimble dependencies
					{
						name: "Generate Documentation"
						run:  "nimble docgen"
					}, // Generate documentation using nimble docgen

					// Setup Pages
					{
						name: "Setup Pages"
						uses: "actions/configure-pages@v5"
					},
					// Upload artifact for GitHub Pages
					{
						name: "Upload artifact"
						uses: "actions/upload-pages-artifact@v4"
						with: {
							path: "./docs"
						}
					},
					// Deploy to GitHub Pages
					{
						name: "Deploy to GitHub Pages"
						id:   "deployment"
						uses: "actions/deploy-pages@v4"
					},
				]
			}
		}
	}
}
