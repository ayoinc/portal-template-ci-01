# sample-nextjs-app

Customer portal for the sample team's orders: the "self-service" edition

## Overview

| Setting     | Value                                                                        |
| ----------- | ---------------------------------------------------------------------------- |
| Application | `sample-nextjs-app`                                                         |
| Owner       | `group:default/platform-team`                                                        |
| Environment | `development`                                                  |
| Framework   | Next.js 14 (App Router), React 18, TypeScript                                |
| Styling     | Tailwind CSS |
| Node.js     | 22 (see `.nvmrc`)                                                            |
| Repository  | <https://github.com/example-org/sample-nextjs-app> |

```d2
direction: right

browser: Browser {
  shape: oval
}

app: sample-nextjs-app {
  layout: "layout.tsx\nmetadata"
  page: "page.tsx\n/"
  health: "route.ts\n/api/health"
  site: site.json {
    shape: page
  }
  layout -> page
  site -> layout
  site -> page
  site -> health
}

browser -> app.layout: HTTP 3000
browser -> app.health: HTTP 3000
```

## Project structure

```
sample-nextjs-app/
├── .github/workflows/
│   ├── nextjs.yaml           # Lint, unit tests, build, end-to-end tests
│   └── docker.yaml           # Image build, smoke test and publish
├── __tests__/                # Jest unit tests
├── e2e/                      # Playwright end-to-end tests
├── public/                   # Static assets
├── src/
│   ├── app/
│   │   ├── api/health/route.ts   # GET /api/health
│   │   ├── globals.css
│   │   ├── layout.tsx            # Root layout and metadata
│   │   └── page.tsx              # Home page
│   └── site.json             # Name, description and environment
├── tailwind.config.js
├── postcss.config.js
├── Dockerfile
├── k8s/                      # Deployment and Service
├── catalog-info.yaml         # Backstage catalog entry
└── mkdocs.yml                # TechDocs configuration
```

## Local development

Requires Node.js 22 and npm.

```bash
git clone https://github.com/example-org/sample-nextjs-app.git
cd sample-nextjs-app
npm install
npm run dev
```

The application is served at <http://localhost:3000>.

| Command                | Purpose                                          |
| ---------------------- | ------------------------------------------------ |
| `npm run dev`          | Development server with hot reload               |
| `npm run build`        | Production build (also type-checks and lints)    |
| `npm run start`        | Serve the production build                       |
| `npm run lint`         | ESLint with the Next.js rules                    |
| `npm run format`       | Format with Prettier                             |
| `npm run format:check` | Check formatting without changing files          |
| `npm test`             | Jest unit tests                                  |
| `npm run test:e2e`     | Playwright tests against a running application   |

Before the first end-to-end run, install the browser with
`npx playwright install chromium`.

## Health endpoint

`GET /api/health` returns:

```json
{
  "status": "healthy",
  "timestamp": "2025-01-01T00:00:00.000Z",
  "service": "sample-nextjs-app",
  "environment": "development"
}
```

## Testing

- Unit tests live in `__tests__/` and run in Jest with React Testing Library.
  `npm run test:coverage` enforces 70% coverage.
- End-to-end tests live in `e2e/` and run in Playwright with Chromium. In CI
  they run against the production build.

## Continuous integration

`.github/workflows/nextjs.yaml` runs on every push and pull request to `main`:

| Job             | What it does                                                    |
| --------------- | --------------------------------------------------------------- |
| Lint            | ESLint and Prettier                                             |
| Unit tests      | Jest with coverage                                              |
| Build and e2e   | `next build`, then Playwright against the production build      |
| Dependency scan | Trivy report of known vulnerabilities in `package-lock.json`    |

The dependency scan reports and does not fail the build. In a public
repository its results also appear in the repository's Security tab.

`.github/workflows/docker.yaml` runs on the same events:

| Job   | What it does                                                                     |
| ----- | -------------------------------------------------------------------------------- |
| Lint  | Hadolint on the `Dockerfile`, kubeconform on `k8s/`                              |
| Image | Builds the image, starts it, calls `/api/health`, scans it with Trivy            |

On pushes to `main` the image is published to the GitHub Container Registry
with the workflow's own token; no secret has to be configured.

## Docker

```bash
docker build -t sample-nextjs-app .
docker run --rm -p 3000:3000 sample-nextjs-app
```

Published images:

```
ghcr.io/example-org/sample-nextjs-app:latest
ghcr.io/example-org/sample-nextjs-app:sha-<commit>
```

## Kubernetes

`k8s/` contains a Deployment (two replicas, liveness and readiness probes on
`/api/health`) and a ClusterIP Service on port 80.

```bash
kubectl apply -f k8s/
```

The package is private by default. Either make it public in the package
settings or add an image pull secret to the Deployment.

## Environment variables

Variables prefixed with `NEXT_PUBLIC_` are available in the browser; all
others are server-only. Put local values in `.env.local`, which is ignored by
Git.

## References

- [Next.js documentation](https://nextjs.org/docs)
- [Tailwind CSS](https://tailwindcss.com/docs)
- [Jest](https://jestjs.io/docs/getting-started)
- [Playwright](https://playwright.dev/docs/intro)
